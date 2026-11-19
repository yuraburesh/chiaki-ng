#include "anyplayupdater.h"
#include "anyplaycloud.h"
#include "qmlbackend.h"

#include <QCoreApplication>
#include <QCryptographicHash>
#include <QDateTime>
#include <QDesktopServices>
#include <QDir>
#include <QFileInfo>
#include <QJsonDocument>
#include <QNetworkReply>
#include <QProcess>
#include <QRegularExpression>
#include <QSettings>
#include <QStandardPaths>
#include <QUrl>
#include <QUrlQuery>
#include <QtConcurrent/QtConcurrentRun>

static const int CHECK_EVERY_MS = 6 * 60 * 60 * 1000;   // перевірка раз на 6 годин
static const int FIRST_CHECK_MS = 4000;                  // і невдовзі після запуску
static const char *ATTEMPT_KEY = "anyplay/update_attempt";
static const char *MOVE_KEY = "anyplay/update_move";

const char *anyplayPlatform()
{
#if defined(Q_OS_WIN)
	return "windows";
#elif defined(Q_OS_MACOS) && defined(Q_PROCESSOR_ARM_64)
	return "mac";
#elif defined(Q_OS_MACOS)
	return "mac_intel";
#else
	return "linux";
#endif
}

static QString textNetwork() { return AnyPlayUpdater::tr("Не вдалося завантажити оновлення. Перевір інтернет."); }
static QString textCorrupt() { return AnyPlayUpdater::tr("Файл пошкоджений, спробуй ще раз."); }

AnyPlayUpdater::AnyPlayUpdater(AnyPlayCloud *cloud, QmlBackend *backend, QObject *parent)
	: QObject(parent), cloud(cloud), backend(backend)
{
#if defined(Q_OS_MACOS)
	{
		// з образу диска чи з «Завантажень» (macOS запускає таку програму з тимчасової копії лише для читання)
		// замінити програму на місці не вийде — спершу переносимо її в «Програми»
		const QString bundle = macBundlePath();
		needs_move_ = !bundle.isEmpty()
			&& (bundle.contains(QStringLiteral("/AppTranslocation/")) || bundle.startsWith(QStringLiteral("/Volumes/"))
			    || !QFileInfo(QFileInfo(bundle).absolutePath()).isWritable());
	}
#endif

	check_timer.setInterval(CHECK_EVERY_MS);
	connect(&check_timer, &QTimer::timeout, this, [this]() {
		dismissed_ = false;   // «Пізніше» діє до наступної перевірки
		check();
	});
	speed_timer.setInterval(500);
	connect(&speed_timer, &QTimer::timeout, this, [this]() {
		const qint64 ms = speed_clock.restart();
		if(ms > 0)
		{
			const double now = double(received_ - speed_bytes_) * 1000.0 / double(ms);
			speed_ = speed_ <= 0 ? now : speed_ * 0.7 + now * 0.3;
		}
		speed_bytes_ = received_;
		emit progressChanged();
	});
	connect(&hash_watcher, &QFutureWatcher<QByteArray>::finished, this, [this]() {
		const QString file = targetFile();
		if(hash_watcher.result() != sha256_.toLatin1())
		{
			QFile::remove(file);
			setPhase(QStringLiteral("error"), textCorrupt());
			return;
		}
		install(file);
	});

	// сервер сказав «онови програму» — одразу дізнаємось, що саме ставити
	connect(cloud, &AnyPlayCloud::changed, this, [this]() {
		if(this->cloud->state() == QLatin1String("update") && !check_reply
		   && QDateTime::currentMSecsSinceEpoch() - last_check_ms_ > 60 * 1000)
			check();
		// сервер дозволяє грати (бронь іде, наприклад, після обриву гри): обов'язкове оновлення не блокує екран,
		// інакше людина не змогла б підключитись знову до кінця броні
		const bool play = this->cloud->state() == QLatin1String("play");
		if(play != may_play_)
		{
			may_play_ = play;
			emit changed();
		}
		updatePrompt();
	});
	// почалась гра: завантаження ставимо на паузу (докачаємо потім), вікно ховаємо до кінця гри
	connect(backend, &QmlBackend::sessionChanged, this, [this]() {
		if(streaming() && dl_reply)
		{
			canceled_ = true;
			dl_reply->abort();
		}
		updatePrompt();
	});

	if(!supported())
		return;
	readLastAttempt();
	QTimer::singleShot(FIRST_CHECK_MS, this, &AnyPlayUpdater::check);
	check_timer.start();
}

bool AnyPlayUpdater::supported() const
{
#if defined(Q_OS_WIN)
	return true;
#elif defined(Q_OS_MACOS)
	return !macBundlePath().isEmpty();
#else
	return false;
#endif
}

bool AnyPlayUpdater::streaming() const
{
	return backend && backend->qmlSession() != nullptr;
}

void AnyPlayUpdater::setPhase(const QString &phase, const QString &error)
{
	phase_ = phase;
	error_ = error;
	if(phase != QLatin1String("installing"))
		moving_ = false;
	updatePrompt();
	emit changed();
}

void AnyPlayUpdater::updatePrompt()
{
	const bool busy = phase_ == QLatin1String("downloading") || phase_ == QLatin1String("verifying")
		|| phase_ == QLatin1String("installing");
	bool p = false;
	if(!streaming())
	{
		// помилку показуємо, доки людина сама не закриє вікно
		if(busy || phase_ == QLatin1String("error"))
			p = true;
		// під час оплаченої броні вікно саме не вискакує (лише кнопкою на головному екрані), щоб не заважати грі
		else if(available_ && (forced_ || (!dismissed_ && !may_play_) || (mandatory_ && !may_play_)))
			p = true;
	}
	if(p != prompt_)
	{
		prompt_ = p;
		emit changed();
	}
}

QString AnyPlayUpdater::updatesDir() const
{
	return QStandardPaths::writableLocation(QStandardPaths::CacheLocation) + QStringLiteral("/updates");
}

QString AnyPlayUpdater::targetFile() const
{
	// окрема папка на кожен файл (за SHA-256): недокачаний шматок іншої збірки не змішається з новою
	QString name = QUrl(url_).fileName();
	static const QRegularExpression ok(QStringLiteral("^AnyPlay-(Windows|Mac|Mac-Intel)-\\d+\\.(exe|zip)$"));
	if(!ok.match(name).hasMatch())
	{
#if defined(Q_OS_WIN)
		name = QStringLiteral("AnyPlay-update-%1.exe").arg(build_);
#else
		name = QStringLiteral("AnyPlay-update-%1.zip").arg(build_);
#endif
	}
	return updatesDir() + QLatin1Char('/') + sha256_.left(16) + QLatin1Char('/') + name;
}

void AnyPlayUpdater::check()
{
	if(!supported())
		return;
	if(phase_ == QLatin1String("downloading") || phase_ == QLatin1String("verifying") || phase_ == QLatin1String("installing"))
		return;
	requestManifest();
}

void AnyPlayUpdater::requestManifest()
{
	if(check_reply)
		return;   // відповідь уже в дорозі
	last_check_ms_ = QDateTime::currentMSecsSinceEpoch();
	QUrl url(cloud->server() + QStringLiteral("/api/app/update"));
	QUrlQuery q;
	q.addQueryItem(QStringLiteral("platform"), QString::fromLatin1(anyplayPlatform()));
	q.addQueryItem(QStringLiteral("build"), QString::number(AnyPlayBuildNumber));
	url.setQuery(q);
	QNetworkRequest req(url);
	req.setTransferTimeout(15000);
	req.setRawHeader("X-AnyPlay-Build", QByteArray::number(AnyPlayBuildNumber));
	req.setRawHeader("X-AnyPlay-Platform", anyplayPlatform());
	QNetworkReply *reply = nam.get(req);
	check_reply = reply;
	connect(reply, &QNetworkReply::finished, this, [this, reply]() {
		reply->deleteLater();
		check_reply = nullptr;
		const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
		const QJsonObject o = QJsonDocument::fromJson(reply->readAll()).object();
		const bool ok = reply->error() == QNetworkReply::NoError && status == 200 && o.value(QStringLiteral("ok")).toBool();
		if(ok)
			applyManifest(o);
		if(start_after_check_)
		{
			start_after_check_ = false;
			if(ok && available_)
				beginDownload();
			else if(ok)
				setPhase(QStringLiteral("idle"));   // оновлення вже немає (його відкликали)
			else
				setPhase(QStringLiteral("error"), textNetwork());
		}
	});
}

void AnyPlayUpdater::applyManifest(const QJsonObject &o)
{
	min_build_ = o.value(QStringLiteral("minBuild")).toInt();
	const QJsonObject u = o.value(QStringLiteral("update")).toObject();
	static const QRegularExpression hex(QStringLiteral("^[0-9a-f]{64}$"));
	const int build = u.value(QStringLiteral("build")).toInt();
	const QString url = u.value(QStringLiteral("url")).toString();
	const QString sha = u.value(QStringLiteral("sha256")).toString().toLower();
	const qint64 size = u.value(QStringLiteral("size")).toVariant().toLongLong();
	const bool valid = !u.isEmpty()
		&& u.value(QStringLiteral("platform")).toString() == QLatin1String(anyplayPlatform())
		&& build > AnyPlayBuildNumber
		&& url.startsWith(QStringLiteral("https://"))
		&& hex.match(sha).hasMatch()
		&& size > 0;
	const bool busy = phase_ == QLatin1String("downloading") || phase_ == QLatin1String("verifying")
		|| phase_ == QLatin1String("installing");
	if(busy && !start_after_check_)
		return;   // не підміняємо файл посеред завантаження
	if(!valid)
	{
		if(available_)
		{
			available_ = false;
			mandatory_ = false;
			if(phase_ == QLatin1String("error") && reveal_path_.isEmpty())
				setPhase(QStringLiteral("idle"));
		}
		updatePrompt();
		emit changed();
		return;
	}
	if(build != build_ || sha != sha256_)
		dismissed_ = false;   // нова збірка — покажемо знову, навіть якщо попередню відклали
	build_ = build;
	url_ = url;
	sha256_ = sha;
	size_ = size;
	version_ = u.value(QStringLiteral("version")).toString();
	if(version_.isEmpty())
		version_ = QString::number(build);
	notes_ = u.value(QStringLiteral("notes")).toString().trimmed();
	manual_ = u.value(QStringLiteral("manual")).toString();
	mandatory_ = u.value(QStringLiteral("mandatory")).toBool() || AnyPlayBuildNumber < min_build_;
	available_ = true;
	updatePrompt();
	emit changed();
}

void AnyPlayUpdater::start()
{
	if(!supported())
	{
		openManual();
		return;
	}
	if(phase_ == QLatin1String("downloading") || phase_ == QLatin1String("verifying") || phase_ == QLatin1String("installing"))
		return;
	if(needs_move_)
	{
		moveToApplications();
		return;
	}
	reveal_path_.clear();
	if(!available_)
	{
		// даних про оновлення ще немає (наприклад, повтор після невдалої спроби) — спершу питаємо сервер
		start_after_check_ = true;
		received_ = total_ = 0;
		speed_ = 0;
		setPhase(QStringLiteral("downloading"));
		emit progressChanged();
		requestManifest();
		return;
	}
	beginDownload();
}

void AnyPlayUpdater::beginDownload()
{
	canceled_ = false;
	setPhase(QStringLiteral("downloading"));
	download();
}

void AnyPlayUpdater::download()
{
	const QString file = targetFile();
	const QString dir = QFileInfo(file).absolutePath();
	// старі завантаження інших збірок більше не потрібні
	{
		QDir updates(updatesDir());
		const QString keep = QFileInfo(dir).fileName();
		for(const QFileInfo &fi : updates.entryInfoList(QDir::Dirs | QDir::NoDotAndDotDot))
			if(fi.fileName() != keep)
				QDir(fi.absoluteFilePath()).removeRecursively();
	}
	if(!QDir().mkpath(dir))
	{
		setPhase(QStringLiteral("error"), textNetwork());
		return;
	}
	received_ = 0;
	total_ = size_;
	speed_ = 0;
	// уже завантажений повністю (наприклад, минулого разу не встигли встановити) — одразу перевіряємо
	if(QFileInfo(file).size() == size_)
	{
		received_ = size_;
		emit progressChanged();
		verify();
		return;
	}
	QFile::remove(file);
	const QString part = file + QStringLiteral(".part");
	offset_ = QFileInfo::exists(part) ? QFileInfo(part).size() : 0;
	if(offset_ > size_)
	{
		QFile::remove(part);
		offset_ = 0;
	}
	if(offset_ == size_)
	{
		QFile::rename(part, file);
		received_ = size_;
		emit progressChanged();
		verify();
		return;
	}
	part_file.setFileName(part);
	if(!part_file.open(offset_ > 0 ? (QIODevice::WriteOnly | QIODevice::Append) : (QIODevice::WriteOnly | QIODevice::Truncate)))
	{
		setPhase(QStringLiteral("error"), textNetwork());
		return;
	}
	received_ = offset_;

	QNetworkRequest req{QUrl(url_)};
	req.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::NoLessSafeRedirectPolicy);
	req.setTransferTimeout(60000);   // хвилина без жодного байта — вважаємо, що зв'язок обірвався
	req.setRawHeader("X-AnyPlay-Build", QByteArray::number(AnyPlayBuildNumber));
	req.setRawHeader("X-AnyPlay-Platform", anyplayPlatform());
	range_sent_ = offset_ > 0;
	if(range_sent_)   // докачуємо з місця, де зупинились
		req.setRawHeader("Range", "bytes=" + QByteArray::number(offset_) + "-");

	QNetworkReply *reply = nam.get(req);
	dl_reply = reply;
	speed_bytes_ = received_;
	speed_clock.start();
	speed_timer.start();
	emit progressChanged();

	connect(reply, &QNetworkReply::readyRead, this, [this, reply]() {
		const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
		if(status != 200 && status != 206)
			return;   // помилку розбере onDownloadFinished
		if(range_sent_)
		{
			range_sent_ = false;
			bool same = false;
			if(status == 206)
			{
				// «bytes 1000-2000/3000»: сервер має віддати саме з нашого місця
				const QByteArray cr = reply->rawHeader("Content-Range");
				same = cr.startsWith("bytes " + QByteArray::number(offset_) + "-");
			}
			if(!same)
			{
				// сервер віддає файл з початку — пишемо його заново
				part_file.resize(0);
				offset_ = 0;
				received_ = 0;
				if(status == 206)
				{
					reply->abort();
					return;
				}
			}
		}
		const QByteArray data = reply->readAll();
		if(part_file.write(data) != data.size())
		{
			canceled_ = false;
			reply->abort();
			return;
		}
		received_ += data.size();
		if(received_ > size_)
			reply->abort();
	});
	connect(reply, &QNetworkReply::finished, this, &AnyPlayUpdater::onDownloadFinished);
}

void AnyPlayUpdater::onDownloadFinished()
{
	QNetworkReply *reply = dl_reply;
	dl_reply = nullptr;
	speed_timer.stop();
	if(!reply)
		return;
	reply->deleteLater();
	part_file.close();
	emit progressChanged();
	const QString part = part_file.fileName();
	const QString file = targetFile();

	if(canceled_)
	{
		canceled_ = false;
		setPhase(QStringLiteral("idle"));   // недокачаний файл лишається, наступного разу докачаємо
		return;
	}
	const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
	if(status == 416)
	{
		// наш шматок не підходить до файлу на сервері — завантажимо з нуля
		QFile::remove(part);
		setPhase(QStringLiteral("error"), textNetwork());
		return;
	}
	const qint64 have = QFileInfo(part).size();
	if(have > size_)
	{
		QFile::remove(part);
		setPhase(QStringLiteral("error"), textCorrupt());
		return;
	}
	if(reply->error() != QNetworkReply::NoError || (status != 200 && status != 206) || have < size_)
	{
		setPhase(QStringLiteral("error"), textNetwork());
		return;
	}
	QFile::remove(file);
	if(!QFile::rename(part, file))
	{
		setPhase(QStringLiteral("error"), textNetwork());
		return;
	}
	verify();
}

void AnyPlayUpdater::verify()
{
	setPhase(QStringLiteral("verifying"));
	const QString file = targetFile();
	// SHA-256 рахуємо в окремому потоці, щоб вікно не завмирало
	hash_watcher.setFuture(QtConcurrent::run([file]() -> QByteArray {
		QFile f(file);
		if(!f.open(QIODevice::ReadOnly))
			return QByteArray();
		QCryptographicHash h(QCryptographicHash::Sha256);
		if(!h.addData(&f))
			return QByteArray();
		return h.result().toHex();
	}));
}

void AnyPlayUpdater::install(const QString &file)
{
	setPhase(QStringLiteral("installing"));
	QSettings().setValue(QLatin1String(ATTEMPT_KEY), build_);
	// коротка пауза, щоб людина встигла побачити «Встановлюємо…»
	QTimer::singleShot(700, this, [this, file]() {
		if(streaming())
		{
			// гра встигла початися — програму не закриваємо; файл уже перевірений, поставимо після гри
			QSettings().remove(QLatin1String(ATTEMPT_KEY));
			setPhase(QStringLiteral("idle"));
			return;
		}
#if defined(Q_OS_WIN)
		installWindows(file);
#elif defined(Q_OS_MACOS)
		installMac(file);
#else
		Q_UNUSED(file);
#endif
	});
}

void AnyPlayUpdater::installWindows(const QString &file)
{
	// встановлювач Inno Setup: тихо, без запитань; /ANYPLAYUPDATE — після встановлення він сам відкриє AnyPlay
	const QString log = QDir::toNativeSeparators(updatesDir() + QStringLiteral("/install.log"));
	const QStringList args = {
		QStringLiteral("/SILENT"), QStringLiteral("/SUPPRESSMSGBOXES"), QStringLiteral("/NORESTART"),
		QStringLiteral("/SP-"), QStringLiteral("/CLOSEAPPLICATIONS"), QStringLiteral("/FORCECLOSEAPPLICATIONS"),
		QStringLiteral("/ANYPLAYUPDATE"),
		QStringLiteral("/LOG=") + log,
	};
	if(!QProcess::startDetached(QDir::toNativeSeparators(file), args, QFileInfo(file).absolutePath()))
	{
		QSettings().remove(QLatin1String(ATTEMPT_KEY));
		setPhase(QStringLiteral("error"), tr("Не вдалося запустити встановлення. Спробуй ще раз або завантаж вручну."));
		return;
	}
	quitForUpdate();
}

QString AnyPlayUpdater::macBundlePath() const
{
	// …/AnyPlay.app/Contents/MacOS → …/AnyPlay.app
	QDir d(QCoreApplication::applicationDirPath());
	if(d.dirName() != QLatin1String("MacOS") || !d.cdUp() || d.dirName() != QLatin1String("Contents") || !d.cdUp())
		return QString();
	const QString path = d.absolutePath();
	return path.endsWith(QStringLiteral(".app")) ? path : QString();
}

bool AnyPlayUpdater::runMacHelper(const QString &source, const QString &bundle)
{
	// скрипт заміни лежить усередині програми; копіюємо його в тимчасову папку, бо саму програму він замінить
	QFile script(QStringLiteral(":/anyplay/anyplay-mac-update.sh"));
	const QString dir = QDir::tempPath() + QStringLiteral("/anyplay-update-%1").arg(QCoreApplication::applicationPid());
	QDir(dir).removeRecursively();
	if(!QDir().mkpath(dir) || !script.open(QIODevice::ReadOnly))
		return false;
	const QString helper = dir + QStringLiteral("/anyplay-mac-update.sh");
	QFile out(helper);
	if(!out.open(QIODevice::WriteOnly | QIODevice::Truncate) || out.write(script.readAll()) < 0)
		return false;
	out.close();
	out.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner | QFileDevice::ExeOwner);
	QDir().mkpath(updatesDir());
	const QString result = updatesDir() + QStringLiteral("/mac-result.txt");
	QFile::remove(result);
	return QProcess::startDetached(QStringLiteral("/bin/bash"), {
		helper, QString::number(QCoreApplication::applicationPid()), source, bundle, result,
	}, dir);
}

void AnyPlayUpdater::installMac(const QString &file)
{
	const QString bundle = macBundlePath();
	if(bundle.isEmpty() || !runMacHelper(file, bundle))
	{
		QSettings().remove(QLatin1String(ATTEMPT_KEY));
		setPhase(QStringLiteral("error"), tr("Не вдалося запустити встановлення. Спробуй ще раз або завантаж вручну."));
		return;
	}
	quitForUpdate();
}

void AnyPlayUpdater::moveToApplications()
{
#if defined(Q_OS_MACOS)
	const QString bundle = macBundlePath();
	if(bundle.isEmpty() || phase_ == QLatin1String("installing"))
		return;
	// «Програми» для всіх; якщо туди не можна писати — особисті «Програми» в домашній папці
	QString apps = QStringLiteral("/Applications");
	if(!QFileInfo(apps).isWritable())
	{
		apps = QDir::homePath() + QStringLiteral("/Applications");
		QDir().mkpath(apps);
	}
	const QString dest = apps + QLatin1Char('/') + QFileInfo(bundle).fileName();
	QSettings().setValue(QLatin1String(MOVE_KEY), dest);
	setPhase(QStringLiteral("installing"));
	moving_ = true;
	emit changed();
	QTimer::singleShot(700, this, [this, bundle, dest]() {
		if(streaming())
		{
			QSettings().remove(QLatin1String(MOVE_KEY));
			setPhase(QStringLiteral("idle"));
			return;
		}
		// Копію робимо ще до виходу: програму, запущену з образу диска чи «Завантажень», macOS відкриває
		// з тимчасової копії (AppTranslocation), яка може зникнути, щойно програма закриється.
		// Копія лежить поруч із місцем призначення (той самий диск); скрипт поставить її на місце й прибере папку.
		const QString stage = QFileInfo(dest).absolutePath() + QStringLiteral("/.anyplay-move-%1").arg(QCoreApplication::applicationPid());
		const QString copied = stage + QLatin1Char('/') + QFileInfo(dest).fileName();
		const auto fail = [this, stage]() {
			QDir(stage).removeRecursively();
			QSettings().remove(QLatin1String(MOVE_KEY));
			setPhase(QStringLiteral("error"), tr("Не вдалося перенести AnyPlay у «Програми». Перетягни програму туди сам і відкрий її знову."));
		};
		QDir(stage).removeRecursively();
		if(!QDir().mkpath(stage))
		{
			fail();
			return;
		}
		QProcess *copy = new QProcess(this);
		connect(copy, &QProcess::finished, this, [this, copy, stage, copied, dest, fail](int code, QProcess::ExitStatus status) {
			copy->deleteLater();
			if(streaming())
			{
				QDir(stage).removeRecursively();
				QSettings().remove(QLatin1String(MOVE_KEY));
				setPhase(QStringLiteral("idle"));
				return;
			}
			if(status != QProcess::NormalExit || code != 0 || !QFileInfo::exists(copied + QStringLiteral("/Contents/MacOS"))
			   || !runMacHelper(copied, dest))
			{
				fail();
				return;
			}
			quitForUpdate();
		});
		connect(copy, &QProcess::errorOccurred, this, [copy, fail](QProcess::ProcessError e) {
			if(e != QProcess::FailedToStart)
				return;   // решту розбере finished
			copy->deleteLater();
			fail();
		});
		copy->start(QStringLiteral("/usr/bin/ditto"), { bundle, copied });
	});
#endif
}

void AnyPlayUpdater::quitForUpdate()
{
	QTimer::singleShot(0, qApp, []() { QCoreApplication::quit(); });
}

void AnyPlayUpdater::readLastAttempt()
{
	QSettings s;
	const int attempt = s.value(QLatin1String(ATTEMPT_KEY)).toInt();
	const QString moved = s.value(QLatin1String(MOVE_KEY)).toString();
	s.remove(QLatin1String(ATTEMPT_KEY));
	s.remove(QLatin1String(MOVE_KEY));

	// Mac: що сказав скрипт заміни
	bool mac_failed = false;
	QString mac_manual;
	{
		QFile f(updatesDir() + QStringLiteral("/mac-result.txt"));
		if(f.open(QIODevice::ReadOnly))
		{
			const QStringList lines = QString::fromUtf8(f.readAll()).split(QLatin1Char('\n'));
			f.close();
			f.remove();
			mac_failed = lines.value(0).trimmed() == QLatin1String("failed");
			mac_manual = lines.value(1).trimmed();
		}
	}

	if(!moved.isEmpty())
	{
		if(macBundlePath() == moved && !mac_failed)
			QTimer::singleShot(3000, this, [this]() { emit message(tr("AnyPlay тепер у папці «Програми». Відкривай його звідти.")); });
		else
			setPhase(QStringLiteral("error"), tr("Не вдалося перенести AnyPlay у «Програми». Перетягни програму туди сам і відкрий її знову."));
		return;
	}
	if(attempt <= 0)
		return;
	if(AnyPlayBuildNumber >= attempt)
	{
		QDir(updatesDir()).removeRecursively();   // файли оновлення більше не потрібні
		QTimer::singleShot(3000, this, [this]() {
			emit message(tr("Готово! AnyPlay оновлено до версії %1.").arg(AnyPlayBuildNumber));
		});
		return;
	}
	if(!mac_manual.isEmpty() && QFileInfo::exists(mac_manual))
	{
		reveal_path_ = mac_manual;
		setPhase(QStringLiteral("error"), tr("macOS не дала замінити програму автоматично. Ми показали нову версію у Finder: перетягни AnyPlay у папку «Програми» і погодься замінити стару."));
		return;
	}
	setPhase(QStringLiteral("error"), tr("Оновлення не встановилось. Спробуй ще раз або завантаж вручну."));
}

void AnyPlayUpdater::cancel()
{
	if(dl_reply)
	{
		canceled_ = true;
		dl_reply->abort();
	}
	else if(start_after_check_)
	{
		start_after_check_ = false;   // ще чекали відповіді сервера — просто не починаємо
		setPhase(QStringLiteral("idle"));
	}
	else if(phase_ == QLatin1String("error"))
		setPhase(QStringLiteral("idle"));
}

void AnyPlayUpdater::openManual()
{
	QDesktopServices::openUrl(QUrl(manual_.isEmpty() ? QStringLiteral("https://t.me/play_any_bot") : manual_));
}

void AnyPlayUpdater::later()
{
	if(phase_ == QLatin1String("downloading") || phase_ == QLatin1String("verifying") || phase_ == QLatin1String("installing"))
		return;
	forced_ = false;
	reveal_path_.clear();
	if(phase_ == QLatin1String("error"))
	{
		phase_ = QStringLiteral("idle");
		error_.clear();
	}
	if(!mandatory())
		dismissed_ = true;
	updatePrompt();
	emit changed();
}

void AnyPlayUpdater::show()
{
	dismissed_ = false;
	forced_ = true;
	if(!available_)
		check();
	updatePrompt();
	emit changed();
}

void AnyPlayUpdater::revealNew()
{
	if(reveal_path_.isEmpty())
		return;
#if defined(Q_OS_MACOS)
	QProcess::startDetached(QStringLiteral("/usr/bin/open"), { QStringLiteral("-R"), reveal_path_ });
#else
	QDesktopServices::openUrl(QUrl::fromLocalFile(QFileInfo(reveal_path_).absolutePath()));
#endif
}
