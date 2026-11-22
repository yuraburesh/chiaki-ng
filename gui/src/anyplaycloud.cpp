#include "anyplaycloud.h"
#include "anyplayupdater.h"
#include "settings.h"
#include "qmlbackend.h"
#include "qmlsettings.h"
#include "qmlmainwindow.h"
#include "anyplayinput.h"
#include "streamsession.h"
#include "sessionlog.h"

#include <QClipboard>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QHttpMultiPart>
#include <QMimeDatabase>
#include <QSet>
#include <algorithm>
#include <QDateTime>
#include <QDebug>
#include <QGuiApplication>
#include <QDesktopServices>
#include <QJsonArray>
#include <QJsonDocument>
#include <QNetworkReply>
#include <QSettings>
#include <QSysInfo>
#include <QUrl>
#include <QUrlQuery>
#include <QUuid>
#include <QRegularExpression>
#include <memory>

static const char *DEFAULT_SERVER = "https://34-123-25-16.sslip.io";
static const int POLL_MS = 60 * 1000;
static const int BEAT_MS = 20 * 1000;
static const int PAIR_MS = 2000;
static const int PAIR_MAX_TRIES = 300; // ~10 хв

// Номер версії програми (з anyplay-build.txt): сервер порівнює його з мінімальним і просить оновитись, якщо програма застаріла
static const int ANYPLAY_BUILD = AnyPlayBuildNumber;

AnyPlayCloud::AnyPlayCloud(Settings *settings, QmlBackend *backend, QObject *parent)
	: QObject(parent), settings(settings), backend(backend)
{
	QSettings s;
	server_ = s.value("anyplay/server", DEFAULT_SERVER).toString();
	token_ = s.value("anyplay/device_token").toString();

	poll_timer.setInterval(POLL_MS);
	connect(&poll_timer, &QTimer::timeout, this, &AnyPlayCloud::refresh);
	// доступ відкривається рівно в час початку гри: питаємо сервер саме тоді, а потім ще кілька разів по 5 с,
	// поки не прийде «можна грати» (до 30 с), щоб кнопка «Грати» з'явилась одразу
	start_timer.setSingleShot(true);
	start_timer.setTimerType(Qt::PreciseTimer);
	connect(&start_timer, &QTimer::timeout, this, [this]() {
		refresh();
		if(state_ != "play" && start_polls_ < 6)
		{
			start_polls_++;
			start_timer.start(5000);
		}
		else
			start_polls_ = 0;
	});
	beat_timer.setInterval(BEAT_MS);
	connect(&beat_timer, &QTimer::timeout, this, &AnyPlayCloud::heartbeat);
	// трансляція почалась чи закінчилась — одразу кажемо серверу: приставка тримає одне підключення, і другий пристрій
	// клієнта бачить «гра вже йде на іншому пристрої», доки тут стрім (і «Грати» одразу після виходу з гри тут)
	connect(backend, &QmlBackend::sessionChanged, this, [this]() {
		// показники трансляції для телеметрії: з кожною новою трансляцією рахуємо заново
		stat_ = StatWindow();
		stat_connected_ms_ = 0;
		stat_sent_ = false;
		if(this->backend->qmlSession())
			stat_timer.start();
		else
			stat_timer.stop();
		if(playing_)
			QTimer::singleShot(0, this, &AnyPlayCloud::heartbeat);
	});
	stat_timer.setInterval(1000);
	connect(&stat_timer, &QTimer::timeout, this, &AnyPlayCloud::sampleStats);
	other_timer.setSingleShot(true);
	other_timer.setInterval(10000);
	connect(&other_timer, &QTimer::timeout, this, &AnyPlayCloud::refresh);
	psn_wait_timer.setInterval(1000);
	connect(&psn_wait_timer, &QTimer::timeout, this, &AnyPlayCloud::sendMyPsnLogin);
	// адмін: часто питаємо сервер — так програма швидко забирає код прив'язки, написаний у боті
	admin_timer.setInterval(8000);
	connect(&admin_timer, &QTimer::timeout, this, &AnyPlayCloud::refreshAdmin);
	admin_timer.start();
	connect(this, &AnyPlayCloud::linkResult, this, [this](bool ok, const QString &text) {
		if(!link_job_user_)
			return;
		QJsonObject body;
		body["action"] = "link_result";
		body["userId"] = link_job_user_;
		body["ok"] = ok;
		body["text"] = text;
		link_job_user_ = 0;
		request("POST", "/api/app/admin", body, [](int, const QJsonObject &) {});
	});
	pay_timer.setInterval(5000);
	connect(&pay_timer, &QTimer::timeout, this, [this]() {
		if(++pay_polls_ > 40)   // ~3 хв, далі адмін підтвердить вручну
		{
			pay_timer.stop();
			return;
		}
		loadExtend();
	});
	// «Я оплатив» за поповнення: перепитуємо баланс, поки гроші не зарахують (~5 хв, далі адмін підтвердить вручну)
	wallet_timer.setInterval(5000);
	connect(&wallet_timer, &QTimer::timeout, this, [this]() {
		if(++wallet_polls_ > 60)
		{
			wallet_timer.stop();
			return;
		}
		loadWallet();
	});
	book_timer.setInterval(5000);
	connect(&book_timer, &QTimer::timeout, this, [this]() {
		if(++book_polls_ > 60)   // ~5 хв, далі адмін підтвердить вручну
		{
			book_timer.stop();
			return;
		}
		loadBook();
	});
	pair_timer.setInterval(PAIR_MS);
	connect(&pair_timer, &QTimer::timeout, this, [this]() {
		if(++pair_tries_ > PAIR_MAX_TRIES)
		{
			cancelLogin();
			emit message(tr("Час на вхід вийшов. Натисни «Увійти через Telegram» ще раз."));
			return;
		}
		QUrl url(server_ + "/api/app/pair");
		QUrlQuery q; q.addQueryItem("code", pair_code_); url.setQuery(q);
		QNetworkRequest req(url);
		req.setRawHeader("X-AnyPlay-Build", QByteArray::number(ANYPLAY_BUILD));
		req.setRawHeader("X-AnyPlay-Platform", anyplayPlatform());
		QNetworkReply *reply = nam.get(req);
		connect(reply, &QNetworkReply::finished, this, [this, reply]() {
			reply->deleteLater();
			QJsonObject o = QJsonDocument::fromJson(reply->readAll()).object();
			if(o.value("token").isString())
			{
				pair_timer.stop();
				token_ = o.value("token").toString();
				QSettings().setValue("anyplay/device_token", token_);
				admin_ = o.value("admin").toBool();
				emit message(tr("Вхід виконано ✓"));
				refresh();
				poll_timer.start();
			}
			else if(reply->error() == QNetworkReply::ContentNotFoundError)
			{
				cancelLogin();
				emit message(tr("Посилання для входу застаріло — спробуй ще раз."));
			}
		});
	});

	// К12: кадри гри для адміна — лише поки він дивиться (сервер каже preview.want у heartbeat)
	preview_timer.setInterval(1500);
	connect(&preview_timer, &QTimer::timeout, this, &AnyPlayCloud::previewTick);
	// за іменем: вікно дає кадри для перегляду, лише якщо вміє (сигнал previewFrameReady)
	if(backend->qmlWindow() && backend->qmlWindow()->metaObject()->indexOfSignal("previewFrameReady(QByteArray)") >= 0)
		connect(backend->qmlWindow(), SIGNAL(previewFrameReady(QByteArray)), this, SLOT(onPreviewFrame(QByteArray)));
	// К13: після помилки підключення програма сама шле журнал підтримці (не частіше разу на 10 хв)
	connect(backend, &QmlBackend::sessionError, this, [this](const QString &, const QString &) {
		const qint64 now = QDateTime::currentMSecsSinceEpoch();
		if(loggedIn() && now - log_sent_ms_ > 10 * 60 * 1000)
		{
			log_sent_ms_ = now;
			QTimer::singleShot(1500, this, [this]() { uploadLog(QStringLiteral("connect_error")); });
		}
	});

	if(loggedIn())
	{
		setState("wait");
		refresh();
		poll_timer.start();
	}
}

void AnyPlayCloud::setState(const QString &s)
{
	if(state_ == s)
		return;
	state_ = s;
	emit changed();
}

QString AnyPlayCloud::formatTime(qint64 ts) const
{
	if(ts <= 0)
		return QString();
	QDateTime dt = QDateTime::fromSecsSinceEpoch(ts - skew_);
	QDateTime now = QDateTime::currentDateTime();
	if(dt.date() == now.date())
		return dt.toString("HH:mm");
	if(dt.date() == now.date().addDays(1))
		return tr("завтра о %1").arg(dt.toString("HH:mm"));
	return dt.toString("dd.MM, HH:mm");
}

void AnyPlayCloud::request(const QString &method, const QString &path, const QJsonObject &body,
                           std::function<void(int, const QJsonObject &)> done, bool auth)
{
	QNetworkRequest req(QUrl(server_ + path));
	req.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
	req.setTransferTimeout(15000);
	req.setRawHeader("X-AnyPlay-Build", QByteArray::number(ANYPLAY_BUILD));   // сервер знає, чи програма не застаріла
	req.setRawHeader("X-AnyPlay-Platform", anyplayPlatform());                // і для якої системи шукати оновлення
	if(auth && !token_.isEmpty())
		req.setRawHeader("Authorization", "Bearer " + token_.toUtf8());
	QNetworkReply *reply = method == "GET" ? nam.get(req)
		: nam.post(req, QJsonDocument(body).toJson(QJsonDocument::Compact));
	connect(reply, &QNetworkReply::finished, this, [reply, done]() {
		reply->deleteLater();
		int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
		QJsonObject o = QJsonDocument::fromJson(reply->readAll()).object();
		done(status, o);
	});
}

void AnyPlayCloud::login(bool openTelegram)
{
	QJsonObject body;
	body["name"] = QSysInfo::machineHostName();
	body["platform"] = QString::fromLatin1(anyplayPlatform());   // сервер запам'ятовує, з якого пристрою і якої збірки увійшли
	body["build"] = ANYPLAY_BUILD;
	pair_short_.clear(); pair_qr_.clear(); pair_bot_.clear(); pair_link_.clear();
	setState("pairing");
	request("POST", "/api/app/pair", body, [this, openTelegram](int status, const QJsonObject &o) {
		if(status != 200 || !o.value("ok").toBool())
		{
			setState("login");
			emit message(tr("Сервер AnyPlay недоступний. Перевір інтернет і спробуй ще раз."));
			return;
		}
		pair_code_ = o.value("code").toString();
		pair_tries_ = 0;
		pair_link_ = o.value("link").toString();
		pair_short_ = o.value("short").toString();
		pair_bot_ = o.value("bot").toString();
		const QString qr = o.value("qr").toString();
		pair_qr_ = qr.isEmpty() ? QString() : server_ + qr;
		emit changed();
		// старий сервер без коду й QR: як раніше, лише відкриваємо Telegram
		if(openTelegram || pair_short_.isEmpty())
			QDesktopServices::openUrl(QUrl(pair_link_));
		pair_timer.start();
	}, false);
}

void AnyPlayCloud::openPairLink()
{
	if(!pair_link_.isEmpty())
		QDesktopServices::openUrl(QUrl(pair_link_));
}

void AnyPlayCloud::cancelLogin()
{
	pair_timer.stop();
	pair_code_.clear();
	pair_short_.clear(); pair_qr_.clear(); pair_link_.clear();
	setState(loggedIn() ? "wait" : "login");
}

void AnyPlayCloud::logout()
{
	stopPlay(QString());
	token_.clear();
	QSettings().remove("anyplay/device_token");
	poll_timer.stop();
	start_timer.stop();
	start_polls_ = 0;
	continues_ = false;
	guest_ = false;
	own_end_ = 0;
	admin_ = false;
	user_.clear();
	wallet_timer.stop();
	wallet_.clear();
	has_wallet_ = false;
	request_ids_.clear();
	emit walletChanged();
	setState("login");
	emit changed();
}

void AnyPlayCloud::openBot()
{
	QDesktopServices::openUrl(QUrl("https://t.me/play_any_bot"));
}

void AnyPlayCloud::refresh()
{
	if(!loggedIn())
		return;
	request("GET", "/api/app/session", {}, [this](int status, const QJsonObject &o) {
		if(status == 401)
		{
			// доступ пристрою закрив адмін або вхід застарів
			logout();
			emit message(tr("Доступ цього комп'ютера скасовано — увійди через Telegram знову."));
			return;
		}
		if(status != 200 || !o.value("ok").toBool())
		{
			if(!playing_)
				setState("offline");
			return;
		}
		applySession(o);
	});
}

void AnyPlayCloud::applySession(const QJsonObject &o)
{
	skew_ = o.value("now").toVariant().toLongLong() - QDateTime::currentSecsSinceEpoch();
	applyExtras(o);
	const bool wasAdmin = admin_;
	admin_ = o.value("admin").toBool();
	{
		// баланс: старий сервер його не надсилає — тоді вкладку «Баланс» і все про баланс просто не показуємо
		const bool had = has_wallet_;
		bool walletNew = false;
		if(o.value("wallet").isObject())
		{
			has_wallet_ = true;
			walletNew = applyWalletBalances(o.value("wallet"));
		}
		else if(has_wallet_)
		{
			has_wallet_ = false;
			wallet_.clear();
			wallet_timer.stop();
		}
		if(walletNew || had != has_wallet_ || wasAdmin != admin_)
			emit walletChanged();
		// баланс змінився деінде (поповнення, інший пристрій, адмін): ціни «з балансу» на екранах бронювання
		// й продовження рахувались для старого балансу — перепитуємо
		if(walletNew && had && !admin_)
		{
			if(!book_info_.isEmpty())
				loadBook();
			if(extend_info_.value("active").toBool())
				loadExtend();
		}
	}
	user_ = o.value("user").toString();
	my_psn_ = o.value("myPsn").toString();
	my_psn_ready_ = o.value("myPsnReady").toBool();
	closed_ = o.value("closed").toBool();
	{
		QString st = o.value("myPsnStatus").toString();
		bool qr = o.value("myPsnQr").toBool();
		if(qr && (!my_psn_qr_ || st != my_psn_status_))
			qr_rev_++;
		if(st == "ready" && my_psn_status_ != "ready" && !my_psn_status_.isEmpty())
			emit message(tr("✓ Твій акаунт PSN підключено — можна грати на своєму акаунті!"));
		QString code = o.value("myPsnCode").toString(), link = o.value("myPsnLink").toString();
		if(st == "qr_sent" && !qr && (code != my_psn_code_ || link != my_psn_link_) && !(code.isEmpty() && link.isEmpty()))
			qr_rev_++;   // код цифрами теж відкриває вікно «Мій PSN»
		my_psn_code_ = code;
		my_psn_link_ = link;
		my_psn_status_ = st;
		my_psn_qr_ = qr;
		my_psn_linked_ = o.value("myPsnLinked").toBool();
	}
	{
		QJsonObject con = o.value("console").toObject();
		play_psn_ = con.value("psn").toString();
		play_own_ = con.value("own").toBool();
	}
	if(admin_)
		refreshAdmin();
	QJsonObject next = o.value("next").toObject();
	next_start_ = next.value("start").toVariant().toLongLong();
	next_end_ = next.value("end").toVariant().toLongLong();
	QJsonObject booking = o.value("booking").toObject();
	end_ = booking.value("end").toVariant().toLongLong();
	// кінець саме цієї броні й «наступна йде без перерви» (старий сервер цього не надсилає — тоді 0 і false)
	own_end_ = o.value("ownEnd").toVariant().toLongLong();
	if(!own_end_)
		own_end_ = booking.value("ownEnd").toVariant().toLongLong();
	continues_ = o.value("continues").toBool() || booking.value("continues").toBool();
	// гостьовий доступ: грає, поки приставка вільна; end — початок найближчої чужої гри (старий сервер цього не надсилає)
	guest_ = o.value("guest").toBool() || booking.value("guest").toBool();
	// гра в кредит: кінець броні вже минув, а оплату продовження ще перевіряють (endTs — кінець кредиту)
	payment_checking_ = o.value("paymentChecking").toBool() || booking.value("paymentChecking").toBool();
	QString st = o.value("state").toString();
	other_device_ = st == "other_device" ? o.value("otherDevice").toString() : QString();

	if(st == "play")
	{
		QJsonObject console = o.value("console").toObject();
		console_ = console.value("label").toString();
		if(!admin_)
		{
			// прив'язка PS5 і токен PSN живуть лише в пам'яті й лише на час броні
			QJsonObject remote = console.value("remote").toObject();
			QVariantMap psn;
			psn["auth_token"] = remote.value("auth_token").toString();
			psn["refresh_token"] = QStringLiteral("anyplay-managed");
			psn["account_id"] = remote.value("account_id").toString();
			qint64 exp = remote.value("expiry").toVariant().toLongLong();
			psn["expiry"] = QDateTime::fromSecsSinceEpoch(exp - skew_).toString(settings->GetTimeFormat());
			if(!psn_login_active_)   // поки клієнт входить у свій PSN, не підміняємо його вхід
			{
				bool first = !settings->HasAnyPlayEphemeral();
				settings->SetAnyPlayEphemeral(console.value("host").toObject().toVariantMap(), psn);
				if(first)
					backend->refreshPsnToken(); // оновити список PS5 через PSN
			}
		}
		if(!playing_)
		{
			playing_ = true;
			beat_timer.start();
			heartbeat();
		}
		setState("play");
	}
	else if(st == "update" && playing_ && backend->qmlSession())
	{
		// трансляція вже йде — не обриваємо гру через оновлення: стан «update» покажемо, коли гра закінчиться
		qInfo() << "AnyPlay: update requested during a stream, keeping the stream";
	}
	else if(st == "other_device" && backend->qmlSession())
	{
		// трансляція йде саме тут, тож грає цей пристрій: такого стану він отримувати не мав би. Гру не обриваємо
		qInfo() << "AnyPlay: other_device reported during a local stream, keeping the stream";
	}
	else
	{
		if(playing_ || settings->HasAnyPlayEphemeral())
			stopPlay(QString());
		// other_device: гра вже йде на іншому пристрої клієнта, «Грати» тут з'явиться, щойно там вийдуть з гри
		setState(st == "no_console" ? "no_console" : st == "update" ? "update" : st == "other_device" ? "other_device" : "wait");
	}
	if(state_ == "other_device")
		other_timer.start();
	else
		other_timer.stop();
	scheduleStartRefresh();
	emit changed();
}

void AnyPlayCloud::scheduleStartRefresh()
{
	if(state_ == "play" || next_start_ <= 0 || !loggedIn())
	{
		start_timer.stop();
		start_polls_ = 0;
		return;
	}
	if(start_polls_ > 0)
		return;   // гра вже мала початись: опитуємо кожні 5 с, розклад не чіпаємо
	// next_start_ — час сервера, переводимо в годинник комп'ютера; +1 с, щоб сервер точно вже пускав
	const qint64 ms = (next_start_ - skew_) * 1000 - QDateTime::currentMSecsSinceEpoch() + 1000;
	if(ms > 0 && ms < 7LL * 24 * 3600 * 1000)
		start_timer.start(static_cast<int>(ms));
	else
		start_timer.stop();
}

void AnyPlayCloud::heartbeat()
{
	if(!playing_)
		return;
	QJsonObject body;
	body["streaming"] = backend->qmlSession() != nullptr;
	// телеметрія: чим і як грає клієнт, якість і зв'язок за останній проміжок (адмін бачить це в CRM і в панелі)
	const QJsonObject stats = takeStats();
	if(!stats.isEmpty())
		body["stats"] = stats;
	request("POST", "/api/app/heartbeat", body, [this](int status, const QJsonObject &o) {
		if(status == 401)
		{
			stopPlay(tr("Доступ скасовано адміністратором."));
			logout();
			return;
		}
		if(status != 200)
			return; // тимчасові проблеми зі зв'язком не обривають гру
		applyExtras(o);
		if(!o.value("continue").toBool())
		{
			QString reason = o.value("reason").toString() == "kicked"
				? tr("Сеанс завершив адміністратор AnyPlay.")
				: guest_
				? tr("Гостьовий доступ призупинено: на приставці почалась оплачена гра. Щойно приставка звільниться, тут знову з'явиться «Грати».")
				: tr("Час твоєї броні вийшов — дякуємо за гру! Забронювати ще можна тут, кнопкою «Бронювання».");
			stopPlay(reason);
			refresh();
			return;
		}
		qint64 end = o.value("end").toVariant().toLongLong();
		const bool checking = o.value("paymentChecking").toBool();
		if(o.contains("guest"))
			guest_ = o.value("guest").toBool();
		if(guest_)
		{
			// гість нічого не оплачує: кінець його гри — початок найближчої чужої броні, він зсувається, коли хтось бронює чи скасовує
			if(end_ > 0 && end > 0 && end < end_ - 60)
				emit message(tr("Приставку забронювали: гостьовий доступ до %1.").arg(formatTime(end)));
		}
		else if(end_ > 0 && end > end_ && checking)
		{
			// час вийшов, але за продовження вже натиснули «Я оплатив»: граємо далі в кредит, доки адмін перевіряє оплату.
			// Це ще не «оплату отримано»: якщо не підтвердять, гра зупиниться о новому endTs
			if(!payment_checking_)
				emit message(tr("Оплату продовження ще перевіряємо, тому гра не зупинилась: можна грати до %1.").arg(formatTime(end)));
		}
		else if(end_ > 0 && end > end_)
		{
			emit message(tr("✓ Оплату отримано — гру продовжено до %1").arg(formatTime(end)));
			emit extendResult(true, tr("✓ Оплату отримано — гру продовжено до %1").arg(formatTime(end)));
			pay_timer.stop();
			loadExtend();
		}
		payment_checking_ = checking;
		end_ = end;
		emit changed();
	});
}

// адреса приставки в домашній мережі (тоді діють налаштування якості «вдома», а не «через інтернет»): те саме правило, що й у трансляції
static bool lanHost(const QString &host)
{
	if(host.contains(QLatin1Char('.')))
	{
		if(host.startsWith(QLatin1String("10.")) || host.startsWith(QLatin1String("192.168.")))
			return true;
		for(int j = 16; j < 32; j++)
			if(host.startsWith(QStringLiteral("172.%1.").arg(j)))
				return true;
		return false;
	}
	return host.startsWith(QLatin1String("fc"), Qt::CaseInsensitive) || host.startsWith(QLatin1String("fd"), Qt::CaseInsensitive);
}

void AnyPlayCloud::sampleStats()
{
	StreamSession *s = backend->qmlSession();
	QmlMainWindow *w = backend->qmlWindow();
	if(!s || !w || !s->GetConnected())
	{
		stat_connected_ms_ = 0;
		return;
	}
	const qint64 now = QDateTime::currentMSecsSinceEpoch();
	if(!stat_connected_ms_)
		stat_connected_ms_ = now;
	// перші секунди після підключення кадри ще не порахувались; згорнуте вікно кадрів не малює, і це не «погана картинка»
	if(now - stat_connected_ms_ < 4000 || w->visibility() == QWindow::Minimized || w->visibility() == QWindow::Hidden)
		return;
	// поки швидкість ще не виміряно чесно (перші секунди гри), показники не рахуємо: інакше «0,1 Мбіт/с» зіпсувало б середнє
	const QVariant ready = s->property("measuredBitrateReady");
	if(ready.isValid() && !ready.toBool())
		return;
	// кадри за секунду у вікні доступні лише як властивості (для QML)
	const int stream = w->property("streamFps").toInt(), shown = w->property("shownFps").toInt();
	const double loss = s->GetAveragePacketLoss();
	stat_.n++;
	stat_.fps_stream += stream;
	// кадри, що справді дійшли до екрана (якщо їх ще не порахували, ті, що прийшли з приставки): як в індикаторі під час гри
	stat_.fps_shown += shown > 0 ? qMin(shown, stream > 0 ? stream : shown) : stream;
	stat_.bitrate += s->GetMeasuredBitrate();
	stat_.loss += qIsFinite(loss) ? loss * 100.0 : 0.0;
	stat_.dropped += w->droppedFrames();
	// перші показники нової трансляції надсилаємо одразу, а не з черговим сигналом раз на 20 с
	if(!stat_sent_ && stat_.n >= 3 && playing_)
		heartbeat();
}

QJsonObject AnyPlayCloud::takeStats()
{
	StreamSession *s = backend->qmlSession();
	if(!s || stat_.n < 3)
		return QJsonObject();
	const double n = stat_.n;
	const bool pad = s->GetGamepadMode();   // чим натискали востаннє: справжній геймпад чи клавіатура з мишею
	const QString mode = AnyPlayInput::LiveMode();
	const bool local = lanHost(s->GetHost());
	const ChiakiConnectVideoProfile video = local ? settings->GetVideoProfileLocalPS5() : settings->GetVideoProfileRemotePS5();
	QJsonObject o;
	o["platform"] = QString::fromLatin1(anyplayPlatform());
	o["build"] = ANYPLAY_BUILD;
	o["input"] = pad ? QStringLiteral("gamepad") : QStringLiteral("keyboard");
	o["layout"] = AnyPlayInput::Layout();
	// режим клавіш має сенс лише для клавіатури: геймпад іде на приставку як є
	o["mode"] = !pad && (mode == QLatin1String("foot") || mode == QLatin1String("vehicle") || mode == QLatin1String("air")) ? mode : QString();
	o["quality"] = qualityLevel();
	o["auto"] = autoQuality();
	o["width"] = static_cast<int>(video.width);
	o["height"] = static_cast<int>(video.height);
	o["codec"] = chiaki_codec_is_h265(video.codec) ? QStringLiteral("h265") : QStringLiteral("h264");
	o["fpsStream"] = qRound(stat_.fps_stream / n);
	o["fpsShown"] = qRound(stat_.fps_shown / n);
	o["bitrate"] = qRound(stat_.bitrate / n * 10.0) / 10.0;      // Мбіт/с
	o["loss"] = qRound(stat_.loss / n * 100.0) / 100.0;         // відсотки
	o["dropped"] = stat_.dropped;                               // кадрів пропущено за проміжок
	o["local"] = local;
	// К14: наскільки рівно кадри доходять до екрана (лічильники вікна за проміжок між heartbeat)
	if(QmlMainWindow *w = backend->qmlWindow())
	{
		QVariantMap p;
		if(w->metaObject()->indexOfMethod("takePresentStats()") < 0
			|| !QMetaObject::invokeMethod(w, "takePresentStats", Qt::DirectConnection, Q_RETURN_ARG(QVariantMap, p)))
		{
			for(const char *k : { "presentGapMax", "presentGaps", "swapchainResets", "vrr" })
			{
				const QVariant v = w->property(k);
				if(v.isValid())
					p.insert(QString::fromLatin1(k), v);
			}
		}
		for(const char *k : { "presentGapMax", "presentGaps", "swapchainResets" })
			if(p.contains(QString::fromLatin1(k)))
				o[QString::fromLatin1(k)] = p.value(QString::fromLatin1(k)).toInt();
		if(p.contains(QStringLiteral("vrr")) && p.value(QStringLiteral("vrr")).isValid())
			o["vrr"] = p.value(QStringLiteral("vrr")).toBool();
	}
	if(complaint_)
	{
		o["complaint"] = true;
		complaint_ = false;
	}
	stat_ = StatWindow();
	stat_sent_ = true;
	return o;
}

void AnyPlayCloud::stopPlay(const QString &reason)
{
	beat_timer.stop();
	bool was = playing_;
	playing_ = false;
	if(!admin_)
	{
		if(was && backend->qmlSession())
			backend->stopSession(true); // приставку — у режим спокою
		settings->ClearAnyPlayEphemeral();
	}
	if(!reason.isEmpty())
	{
		notice_ = reason;
		emit stopRequested(reason);
		emit message(reason);
	}
	end_ = 0;
	payment_checking_ = false;
	emit changed();
}

void AnyPlayCloud::setMyPsn(const QString &psn)
{
	QString name = psn.trimmed();
	QJsonObject body;
	body["psn"] = name;
	request("POST", "/api/app/psn", body, [this, name](int status, const QJsonObject &o) {
		if(status == 200 && o.value("ok").toBool())
		{
			my_psn_ = o.value("psn").toString();
			my_psn_ready_ = false;
			emit changed();
			emit message(name.isEmpty()
				? tr("Готово — гратимеш на спільному акаунті AnyPlay.")
				: tr("Акаунт %1 передано. Додамо його на PS5 і надішлемо в Telegram код для входу.").arg(name));
			refresh();
		}
		else if(o.value("error").toString() == "psn_format")
			emit message(tr("Схоже, це не схоже на PSN ID: лише літери, цифри, «-» і «_», від 3 до 16 символів."));
		else
			emit message(tr("Не вдалося зберегти акаунт (помилка %1). Спробуй ще раз.").arg(status));
	});
}

void AnyPlayCloud::uploadConsole()
{
	if(!admin_)
		return;
	QJsonObject host;
	for(const RegisteredHost &h : settings->GetRegisteredHosts())
	{
		if(chiaki_target_is_ps5(h.GetTarget()))
		{
			host = QJsonObject::fromVariantMap(h.ToVariantMap());
			break;
		}
	}
	if(host.isEmpty())
	{
		emit message(tr("Спершу прив'яжи PS5 у цій програмі (Налаштування → Консолі)."));
		return;
	}
	if(settings->GetPsnRefreshToken().isEmpty() || settings->GetPsnAccountId().isEmpty())
	{
		emit message(tr("Спершу увійди в PSN акаунтом, під яким гратимуть клієнти (Налаштування → Віддалено)."));
		return;
	}
	// приставка пускає в той профіль, під яким на ній згенеровано код прив'язки — він має збігатися з входом у PSN
	QString regist_account = QSettings().value(QStringLiteral("anyplay/regist_account")).toString();
	if(regist_account != settings->GetPsnAccountId())
	{
		emit message(tr("Приставку прив'язано під іншим профілем PS5, ніж вхід у PSN. Зроби крок 2: на PS5 перемкнись на потрібний профіль і прив'яжи приставку заново."));
		return;
	}
	QJsonObject remote;
	remote["refresh_token"] = settings->GetPsnRefreshToken();
	remote["auth_token"] = settings->GetPsnAuthToken();
	remote["account_id"] = settings->GetPsnAccountId();
	QDateTime exp = QDateTime::fromString(settings->GetPsnAuthTokenExpiry(), settings->GetTimeFormat());
	remote["expiry"] = exp.isValid() ? exp.toSecsSinceEpoch() : 0;
	QJsonObject body;
	body["host"] = host;
	body["remote"] = remote;
	body["label"] = host.value("server_nickname").toString();
	body["psnName"] = QSettings().value(QStringLiteral("anyplay/psn_online_id")).toString();
	body["registAccount"] = regist_account;
	request("POST", "/api/app/console", body, [this](int status, const QJsonObject &o) {
		QString name = o.value("psnName").toString();
		emit message(status == 200 && o.value("ok").toBool()
			? (name.isEmpty() ? tr("✓ PS5 і вхід PSN передано на сервер. Клієнти гратимуть через нього.")
			                  : tr("✓ Спільний акаунт «%1» передано на сервер. Клієнти гратимуть через нього.").arg(name))
			: o.value("error").toString() == "regist_mismatch"
			? tr("Приставку прив'язано під іншим профілем PS5, ніж вхід у PSN. Прив'яжи її заново (крок 2).")
			: tr("Не вдалося передати PS5 на сервер (помилка %1).").arg(status));
		refreshAdmin();
	});
}

void AnyPlayCloud::adminDropShared()
{
	if(!admin_)
		return;
	QJsonObject body;
	body["action"] = "drop_shared";
	request("POST", "/api/app/admin", body, [this](int status, const QJsonObject &o) {
		emit message(status == 200 && o.value("ok").toBool()
			? tr("Спільний акаунт прибрано з сервера. Клієнти не зможуть грати, доки не передаси новий (кроки 1–3).")
			: tr("Не вдалося прибрати акаунт (помилка %1).").arg(status));
		refreshAdmin();
	});
}

QString AnyPlayCloud::localPsnName() const
{
	if(settings->GetPsnRefreshToken().isEmpty() || settings->GetPsnAccountId().isEmpty())
		return QString();
	QString name = QSettings().value(QStringLiteral("anyplay/psn_online_id")).toString();
	return name.isEmpty() ? tr("акаунт PSN") : name;
}

int AnyPlayCloud::localRegistState() const
{
	if(localConsoleName().isEmpty())
		return 0;
	QString acc = QSettings().value(QStringLiteral("anyplay/regist_account")).toString();
	return !acc.isEmpty() && acc == settings->GetPsnAccountId() ? 1 : 2;
}

void AnyPlayCloud::openMyPsnLink()
{
	// посилання приходить із сервера (його розпізнано з QR-коду приставки) — відкриваємо лише сайти Sony
	QUrl url(my_psn_link_);
	QString host = url.host().toLower();
	bool sony = false;
	for(const char *h : {"playstation.com", "sony.com", "playstation.net", "sonyentertainmentnetwork.com"})
		if(host == QLatin1String(h) || host.endsWith(QLatin1Char('.') + QLatin1String(h)))
			sony = true;
	if(url.scheme() != QLatin1String("https") || !sony)
	{
		emit message(tr("Посилання для входу недоступне — відскануй QR-код телефоном."));
		return;
	}
	QDesktopServices::openUrl(url);
}

QString AnyPlayCloud::localConsoleName() const
{
	for(const RegisteredHost &h : settings->GetRegisteredHosts())
		if(chiaki_target_is_ps5(h.GetTarget()))
			return h.GetServerNickname().isEmpty() ? QStringLiteral("PS5") : h.GetServerNickname();
	return QString();
}

void AnyPlayCloud::refreshAdmin()
{
	if(!admin_ || token_.isEmpty())
		return;
	request("GET", "/api/app/admin", QJsonObject(), [this](int status, const QJsonObject &o) {
		if(status != 200 || !o.value("ok").toBool())
			return;
		// оновлюємо екран лише коли щось справді змінилось: інакше поле з кодом очищалося б під час введення
		QJsonObject cmp = o;
		cmp.remove("now");
		cmp.remove("linkJobs");
		if(cmp != admin_cmp_)
		{
			admin_cmp_ = cmp;
			admin_info_ = o.toVariantMap();
			emit adminChanged();
		}
		// код прив'язки з бота: прив'язуємо приставку самі й звітуємо боту
		const QJsonArray jobs = o.value("linkJobs").toArray();
		if(!jobs.isEmpty())
		{
			QJsonObject job = jobs.first().toObject();
			qint64 uid = job.value("userId").toVariant().toLongLong();
			if(busy_)
			{
				QJsonObject body;
				body["action"] = "link_result";
				body["userId"] = uid;
				body["ok"] = false;
				body["text"] = tr("Програма зараз зайнята іншою прив'язкою. Спробуй ще раз за хвилину.");
				request("POST", "/api/app/admin", body, [](int, const QJsonObject &) {});
			}
			else
			{
				link_job_user_ = uid;
				linkClientConsole(uid, job.value("accountId").toString(), job.value("pin").toString());
			}
		}
	});
}

void AnyPlayCloud::adminKick(qint64 bookingId)
{
	if(!admin_)
		return;
	QJsonObject body;
	body["action"] = "kick";
	body["bookingId"] = bookingId;
	request("POST", "/api/app/admin", body, [this](int status, const QJsonObject &o) {
		emit message(status == 200 && o.value("ok").toBool()
			? tr("Гру клієнта завершено. Йому прийшло повідомлення в боті.")
			: adminError(o, status, tr("Не вдалося завершити гру (помилка %1).").arg(status)));
		refreshAdmin();
	});
}

// спільні відповіді сервера на дії адміна: немає права (адмін з неповними правами) або сервер ще не знає цієї дії
QString AnyPlayCloud::adminError(const QJsonObject &o, int status, const QString &fallback) const
{
	const QString e = o.value("error").toString();
	if(e == "forbidden")
		return tr("У тебе немає права на цю дію. Права адмінів налаштовує власник у CRM.");
	if(status == 0)
		return tr("Немає зв'язку з сервером. Перевір інтернет і спробуй ще раз.");
	return fallback;
}

void AnyPlayCloud::adminGrant(qint64 userId, int minutes, const QString &name)
{
	if(!admin_ || userId == 0)
		return;
	minutes = qBound(10, minutes - minutes % 5, 2880);
	QJsonObject body;
	body["action"] = "grant";
	body["userId"] = userId;
	body["minutes"] = minutes;
	request("POST", "/api/app/admin", body, [this, name](int status, const QJsonObject &o) {
		const QString e = o.value("error").toString();
		const QString who = name.isEmpty() ? tr("Клієнт") : name;
		if(status == 200 && o.value("ok").toBool())
		{
			const qint64 end = o.value("end").toVariant().toLongLong();
			emit message(end > 0 ? tr("✓ Гру подаровано: %1 може грати до %2. Йому прийшло повідомлення в боті.").arg(who, formatTime(end))
			                     : tr("✓ Гру подаровано: %1 може грати просто зараз. Йому прийшло повідомлення в боті.").arg(who));
		}
		else if(e == "busy")
			emit message(tr("Приставка зараз зайнята: іде чиясь гра або до наступної броні менше 10 хвилин. Подарувати гру можна, коли вона вільна."));
		else if(e == "action" || (status == 404 && e != "not_found"))
			emit message(tr("Сервер ще не вміє дарувати гру з програми. Подаруй її в CRM: кнопка «CRM» у боті."));
		else if(e == "not_found")
			emit message(tr("Такого клієнта сервер не знайшов. Онови панель і спробуй ще раз."));
		else
			emit message(adminError(o, status, tr("Не вдалося подарувати гру (помилка %1).").arg(status)));
		refreshAdmin();
	});
}

void AnyPlayCloud::adminSetClosed(bool closed)
{
	if(!admin_)
		return;
	QJsonObject body;
	body["action"] = closed ? "close" : "open";
	request("POST", "/api/app/admin", body, [this, closed](int status, const QJsonObject &o) {
		if(status == 200 && o.value("ok").toBool())
			emit message(closed
				? tr("Доступ закрито: клієнти не можуть грати, бот показує «технічні роботи».")
				: tr("Доступ відкрито: клієнти знову грають у свій час."));
		else
			emit message(tr("Не вдалося змінити доступ (помилка %1).").arg(status));
		refreshAdmin();
	});
}

void AnyPlayCloud::loadExtend()
{
	if(token_.isEmpty())
		return;
	request("GET", "/api/app/extend", QJsonObject(), [this](int status, const QJsonObject &o) {
		if(status != 200 || !o.value("ok").toBool())
			return;
		extend_info_ = o.toVariantMap();
		// баланс з тієї ж відповіді, що й «вистачає / не вистачає» у варіантах: на екрані вони не розходяться
		if(applyWalletBalances(o.value("wallet")))
			emit walletChanged();
		emit extendChanged();
	});
}

void AnyPlayCloud::extend(int hours, const QString &method, const QString &pay)
{
	const QString how = pay.isEmpty() ? QStringLiteral("transfer") : pay;
	const QString action = QStringLiteral("extend|%1|%2|%3").arg(hours).arg(method, how);
	QJsonObject body;
	body["hours"] = hours;
	if(!method.isEmpty())
		body["method"] = method;
	body["pay"] = how;                       // старий сервер це поле не читає і бере переказ
	body["requestId"] = requestId(action);   // повтор після збою зв'язку не спише з балансу двічі
	const qint64 oldEnd = extend_info_.value("end").toLongLong();
	const QString cur = (method.isEmpty() ? extend_info_.value("method").toString() : method).toUpper();
	request("POST", "/api/app/extend", body, [this, hours, action, oldEnd, cur](int status, const QJsonObject &o) {
		requestDone(action, status);
		if(status == 200 && o.value("ok").toBool() && o.value("paid").toBool())
		{
			// оплачено з балансу: гру вже продовжено, переказувати нічого не треба
			if(applyWalletBalances(o.value("wallet")))
				emit walletChanged();
			const QJsonObject b = o.value("booking").toObject();
			// end — кінець усієї гри (з бронями впритул), booking.end — кінець саме цього продовження
			qint64 end = o.value("end").toVariant().toLongLong();
			if(end <= 0)
				end = b.value("end").toVariant().toLongLong();
			if(end <= 0 && oldEnd > 0)
				end = oldEnd + hours * 3600;
			const QString c = b.value("currency").toString().isEmpty() ? cur : b.value("currency").toString();
			emit extendResult(true, (end > 0 ? tr("✓ Гру продовжено до %1, оплачено з балансу.").arg(formatTime(end)) : tr("✓ Гру продовжено, оплачено з балансу."))
				+ walletLeftText(c));
			refresh();
			loadWallet();
		}
		else if(status == 200 && o.value("ok").toBool())
		{
			QJsonObject p = o.value("pending").toObject();
			qint64 hold = p.value("holdUntil").toVariant().toLongLong() - (QDateTime::currentSecsSinceEpoch() + skew_);
			const QJsonObject part = o.value("walletPart").toObject();
			if(part.value("amount").toDouble() > 0)
			{
				// «Баланс + картка»: частину з балансу відкладено, переказати треба лише решту
				emit extendResult(true, tr("Час %1–%2 закріплено за тобою на %3 хв. Доплати %4 і натисни «✓ Я оплатив»: ще %5 спишемо з балансу, і гра продовжиться сама, без перезапуску.")
					.arg(formatTime(p.value("start").toVariant().toLongLong())).arg(formatTime(p.value("end").toVariant().toLongLong()))
					.arg(qMax<qint64>(1, hold / 60))
					.arg(walletMoney(p.value("amount").toVariant().toDouble(), p.value("currency").toString(), part.value("symbol").toString()))
					.arg(walletMoney(part.value("amount").toDouble(), part.value("currency").toString(), part.value("symbol").toString())));
				refresh();
				loadWallet();
			}
			else
				emit extendResult(true, tr("Час %1–%2 закріплено за тобою на %3 хв. Оплати за реквізитами нижче й натисни «✓ Я оплатив» — гра продовжиться сама, без перезапуску.")
					.arg(formatTime(p.value("start").toVariant().toLongLong())).arg(formatTime(p.value("end").toVariant().toLongLong()))
					.arg(qMax<qint64>(1, hold / 60)));
		}
		else
		{
			QString e = o.value("error").toString();
			emit extendResult(false, e == "busy" ? tr("На жаль, наступні %1 год уже хтось забронював. Спробуй менше годин.").arg(hours)
				: e == "funds" ? walletError(e, status)
				: e == "no_session" ? tr("Продовжити можна лише під час своєї гри.")
				: e == "pending" ? tr("Твою оплату продовження вже перевіряють — зачекай трохи.")
				: (status == 0 ? tr("Немає зв'язку з сервером. Перевір інтернет і натисни ще раз.")
				               : tr("Не вдалося продовжити (помилка %1). Спробуй ще раз за хвилину.").arg(status)));
			if(e == "funds")
			{
				refresh();
				loadWallet();
			}
		}
		loadExtend();
	});
}

void AnyPlayCloud::payExtend(qint64 bookingId, const QString &sender)
{
	QJsonObject body;
	body["bookingId"] = bookingId;
	body["sender"] = sender.trimmed();
	setBusy(true);
	request("POST", "/api/app/extend/paid", body, [this](int status, const QJsonObject &o) {
		setBusy(false);
		if(status == 200 && o.value("ok").toBool())
		{
			if(o.value("paid").toBool())
				emit extendResult(true, tr("✓ Оплату вже отримано!"));
			else if(o.value("auto").toBool())
				emit extendResult(true, tr("Шукаємо твій платіж у виписці — зазвичай до хвилини. Можна повертатися до гри."));
			else
				emit extendResult(true, tr("Адміністратор перевіряє оплату — зазвичай кілька хвилин. Гра не перерветься, якщо оплата прийде до кінця часу."));
			pay_polls_ = 0;
			pay_timer.start();
		}
		else
			emit extendResult(false, o.value("error").toString() == "busy"
				? tr("На жаль, цей час уже зайняли — обери інший варіант.")
				: tr("Не вдалося надіслати оплату (помилка %1). Спробуй ще раз.").arg(status));
		loadExtend();
	});
}

// ── Бронювання прямо в програмі ──
void AnyPlayCloud::loadBook()
{
	if(token_.isEmpty())
		return;
	request("GET", "/api/app/book", QJsonObject(), [this](int status, const QJsonObject &o) {
		if(status != 200 || !o.value("ok").toBool())
			return;
		book_info_ = o.toVariantMap();
		if(applyWalletBalances(o.value("wallet")))   // баланс з тієї ж відповіді, що й ціни «з балансу»
			emit walletChanged();
		// оплату знайдено / бронь підтверджено — перестаємо опитувати
		bool waiting = false;
		for(const auto &v : o.value("mine").toArray())
			waiting |= v.toObject().value("status").toString() == "pending_review";
		if(!waiting)
			book_timer.stop();
		emit bookChanged();
	});
}

void AnyPlayCloud::loadBookStarts(const QString &day, const QString &code)
{
	if(token_.isEmpty() || day.isEmpty() || code.isEmpty())
		return;
	const QString key = day + "|" + code;
	book_starts_key_ = key;
	book_starts_.clear();
	book_starts_loading_ = true;
	emit bookStartsChanged();
	request("GET", QString("/api/app/book/starts?day=%1&code=%2").arg(day, code), QJsonObject(), [this, key](int status, const QJsonObject &o) {
		if(key != book_starts_key_)
			return;   // уже обрали інший день чи тариф
		book_starts_loading_ = false;
		book_starts_ = (status == 200 && o.value("ok").toBool()) ? o.value("starts").toArray().toVariantList() : QVariantList();
		emit bookStartsChanged();
	});
}

void AnyPlayCloud::book(qint64 start, const QString &code, const QString &method, const QString &pay)
{
	const QString how = pay.isEmpty() ? QStringLiteral("transfer") : pay;
	const QString action = QStringLiteral("book|%1|%2|%3|%4").arg(start).arg(code, method, how);
	QJsonObject body;
	body["start"] = start;
	body["code"] = code;
	body["method"] = method;
	body["pay"] = how;                       // wallet | mix | transfer (старий сервер бере переказ)
	body["requestId"] = requestId(action);   // повтор після збою зв'язку не спише з балансу двічі
	setBusy(true);
	request("POST", "/api/app/book", body, [this, action, method](int status, const QJsonObject &o) {
		setBusy(false);
		requestDone(action, status);
		if(status == 200 && o.value("ok").toBool() && o.value("paid").toBool())
		{
			// оплачено з балансу одразу: екрана оплати немає, бронь уже підтверджена
			if(applyWalletBalances(o.value("wallet")))
				emit walletChanged();
			const QString c = o.value("booking").toObject().value("currency").toString();
			emit bookResult(true, tr("✓ Бронь оплачено з балансу, час твій.") + walletLeftText(c.isEmpty() ? method.toUpper() : c));
			loadWallet();
		}
		else if(status == 200 && o.value("ok").toBool())
		{
			QJsonObject p = o.value("pending").toObject();
			qint64 hold = p.value("holdUntil").toVariant().toLongLong() - (QDateTime::currentSecsSinceEpoch() + skew_);
			const QJsonObject part = o.value("walletPart").toObject();
			if(part.value("amount").toDouble() > 0)
			{
				// «Баланс + картка»: частину з балансу відкладено, переказати треба лише решту
				emit bookResult(true, tr("Час закріплено за тобою на %1 хв. Доплати %2 і натисни «✓ Я оплатив»: ще %3 спишемо з балансу, і бронь підтвердиться.")
					.arg(qMax<qint64>(1, hold / 60))
					.arg(walletMoney(p.value("amount").toVariant().toDouble(), p.value("currency").toString(), part.value("symbol").toString()))
					.arg(walletMoney(part.value("amount").toDouble(), part.value("currency").toString(), part.value("symbol").toString())));
				loadWallet();
			}
			else
				emit bookResult(true, tr("Час закріплено за тобою на %1 хв. Оплати й натисни «✓ Я оплатив».").arg(qMax<qint64>(1, hold / 60)));
		}
		else
		{
			const QString e = o.value("error").toString();
			emit bookResult(false, e == "busy" ? tr("Цей час щойно зайняли — обери інший.")
				: e == "funds" ? walletError(e, status)
				: e == "limit" ? tr("У тебе вже максимум активних броней (%1). Оплати або скасуй одну з них.").arg(o.value("limit").toInt())
				: e == "closed" ? tr("Зараз технічні роботи — бронювання тимчасово недоступне.")
				: (status == 0 ? tr("Немає зв'язку з сервером. Перевір інтернет і натисни ще раз.")
				               : tr("Не вдалося забронювати (помилка %1). Спробуй ще раз.").arg(status)));
			if(e == "funds")
				loadWallet();
		}
		loadBook();
		refresh();
	});
}

void AnyPlayCloud::cancelBooking(qint64 bookingId)
{
	QJsonObject body;
	body["bookingId"] = bookingId;
	request("POST", "/api/app/book/cancel", body, [this](int status, const QJsonObject &o) {
		bool ok = status == 200 && o.value("ok").toBool();
		QString text = o.value("text").toString();   // сервер точно знає: була оплата чи ні, і куди повертати
		// гроші за скасовану бронь повертаються на баланс одразу
		const QJsonObject refund = o.value("refund").toObject();
		if(ok && refund.value("to").toString() == QLatin1String("wallet") && refund.value("amount").toDouble() > 0)
			text = tr("Бронь скасовано. %1 повернули на баланс: їх можна витратити на наступну гру.")
				.arg(walletMoney(refund.value("amount").toDouble(), refund.value("currency").toString(), refund.value("symbol").toString()));
		if(text.isEmpty())
			text = ok ? tr("Бронь скасовано, час звільнено.")
			          : tr("Цю бронь уже не можна скасувати: до початку лишилось надто мало часу.");
		emit bookResult(ok, text);
		if(o.value("refund").toString() == QLatin1String("bot"))
			openBot();   // старий сервер без балансу: бот питає, куди повернути кошти
		loadBook();
		loadExtend();
		refresh();
		if(has_wallet_)
			loadWallet();
	});
}

void AnyPlayCloud::payBooking(qint64 bookingId, const QString &sender)
{
	QJsonObject body;
	body["bookingId"] = bookingId;
	body["sender"] = sender.trimmed();
	setBusy(true);
	request("POST", "/api/app/extend/paid", body, [this](int status, const QJsonObject &o) {
		setBusy(false);
		if(status == 200 && o.value("ok").toBool())
		{
			if(o.value("paid").toBool())
				emit bookResult(true, tr("✓ Оплату вже отримано — бронь підтверджено!"));
			else if(o.value("auto").toBool())
				emit bookResult(true, tr("Шукаємо твій платіж — зазвичай до хвилини. Бронь підтвердиться сама."));
			else
				emit bookResult(true, tr("Адміністратор перевіряє оплату — зазвичай кілька хвилин. Час уже закріплено за тобою."));
			book_polls_ = 0;
			book_timer.start();
		}
		else
			emit bookResult(false, o.value("error").toString() == "busy"
				? tr("На жаль, час на оплату минув і цей слот уже зайняли — обери інший.")
				: tr("Не вдалося надіслати (помилка %1). Спробуй ще раз.").arg(status));
		loadBook();
	});
}

// ── Баланс: передоплата за гру. Поповнення переказом, оплата броней і продовжень одним натиском ──
static QString walletIdOf(const QVariantMap &t) { return t.value("topupId", t.value("id")).toString(); }

// поповнення в одному вигляді: сервер може віддати реквізити поруч з topupId або всередині «pending», як для броні
static QVariantMap walletTopup(const QJsonObject &o)
{
	QVariantMap t = o.value("pending").isObject() ? o.value("pending").toObject().toVariantMap() : o.toVariantMap();
	t.remove("ok");
	if(o.contains("topupId"))
		t["topupId"] = o.value("topupId").toVariant();
	else if(!t.contains("topupId") && t.contains("id"))
		t["topupId"] = t.value("id");
	return t;
}

QString AnyPlayCloud::requestId(const QString &action)
{
	auto it = request_ids_.constFind(action);
	if(it != request_ids_.constEnd())
		return it.value();
	const QString id = QUuid::createUuid().toString(QUuid::WithoutBraces);
	request_ids_.insert(action, id);
	return id;
}

void AnyPlayCloud::requestDone(const QString &action, int status)
{
	// відповідь не дійшла або сервер упав: дія могла виконатись, тож повтор тієї самої дії піде з тим самим requestId
	if(status == 0 || status >= 500)
		return;
	request_ids_.remove(action);
}

bool AnyPlayCloud::applyWalletBalances(const QJsonValue &w)
{
	QVariantList balances;
	QString primary = wallet_.value("primary").toString();
	if(w.isArray())
		balances = w.toArray().toVariantList();
	else if(w.isObject() && w.toObject().value("balances").isArray())
	{
		balances = w.toObject().value("balances").toArray().toVariantList();
		if(w.toObject().contains("primary"))
			primary = w.toObject().value("primary").toString();
	}
	else
		return false;
	if(balances == wallet_.value("balances").toList() && primary == wallet_.value("primary").toString())
		return false;
	wallet_["balances"] = balances;
	wallet_["primary"] = primary;
	return true;
}

double AnyPlayCloud::walletBalance(const QString &currency) const
{
	for(const QVariant &v : wallet_.value("balances").toList())
		if(v.toMap().value("currency").toString() == currency)
			return v.toMap().value("amount").toDouble();
	return 0;
}

QString AnyPlayCloud::walletMoney(double amount, const QString &currency, const QString &symbol) const
{
	QString sym = symbol;
	for(const QVariant &v : wallet_.value("balances").toList())
		if(sym.isEmpty() && v.toMap().value("currency").toString() == currency)
			sym = v.toMap().value("symbol").toString();
	if(sym.isEmpty())
		sym = currency == "UAH" ? QStringLiteral("₴") : currency == "PLN" ? QStringLiteral("zł") : currency;
	// «1 000 ₴», «500,37 ₴»: копійки лише якщо вони є
	const qint64 cents = qRound64(qAbs(amount) * 100);
	QString num = QString::number(cents / 100);
	for(int i = num.size() - 3; i > 0; i -= 3)
		num.insert(i, QChar(0x00A0));
	if(cents % 100)
		num += QLatin1Char(',') + QStringLiteral("%1").arg(cents % 100, 2, 10, QLatin1Char('0'));
	return (amount < 0 ? QStringLiteral("−") : QString()) + num + QChar(0x00A0) + sym;
}

QString AnyPlayCloud::walletLeftText(const QString &currency) const
{
	for(const QVariant &v : wallet_.value("balances").toList())
		if(v.toMap().value("currency").toString() == currency)
			return tr(" На балансі залишилось %1.").arg(walletMoney(v.toMap().value("amount").toDouble(), currency));
	return QString();
}

QString AnyPlayCloud::walletError(const QString &error, int status) const
{
	if(error == "funds")
		return tr("Баланс змінився, і на цю оплату його вже не вистачає. Обери спосіб оплати ще раз.");
	if(error == "closed")
		return tr("Зараз технічні роботи, спробуй трохи згодом.");
	if(error == "expired")
		return tr("Час на оплату цього поповнення минув. Обери суму ще раз.");
	if(status == 0)
		return tr("Немає зв'язку з сервером. Перевір інтернет і натисни ще раз.");
	return tr("Не вдалося (помилка %1). Спробуй ще раз.").arg(status);
}

void AnyPlayCloud::loadWallet()
{
	if(token_.isEmpty() || admin_)
		return;
	request("GET", "/api/app/wallet", QJsonObject(), [this](int status, const QJsonObject &o) {
		if(status != 200 || !o.value("ok").toBool())
			return;
		// що було відкрито й скільки було на балансі до цього: поповнення зникло зі списку, а баланс виріс — гроші зараховано
		QHash<QString, QString> before;
		for(const QVariant &v : wallet_.value("pending").toList())
			before.insert(walletIdOf(v.toMap()), v.toMap().value("currency").toString());
		const QVariantList oldBalances = wallet_.value("seen").toList();
		auto seen = [&oldBalances](const QString &currency) {
			for(const QVariant &v : oldBalances)
				if(v.toMap().value("currency").toString() == currency)
					return v.toMap().value("amount").toDouble();
			return -1.0;
		};

		QVariantMap w = o.toVariantMap();
		w.remove("ok");
		QVariantList pending;
		bool review = false;
		for(const QJsonValue &v : o.value("pending").toArray())
		{
			const QVariantMap t = walletTopup(v.toObject());
			review |= t.value("status").toString() == "pending_review";
			before.remove(walletIdOf(t));
			pending << t;
		}
		w["pending"] = pending;
		w["seen"] = w.value("balances");   // баланс з цього екрана (сесія його не чіпає)
		has_wallet_ = true;
		wallet_ = w;
		if(!review)
			wallet_timer.stop();
		emit walletChanged();
		for(auto it = before.constBegin(); it != before.constEnd(); ++it)
		{
			const double was = seen(it.value()), now = walletBalance(it.value());
			if(was >= 0 && now > was + 0.001)
			{
				const QString text = tr("✓ Баланс поповнено: тепер %1.").arg(walletMoney(now, it.value()));
				emit walletResult(true, text);
				emit message(text);
				break;
			}
		}
	});
}

void AnyPlayCloud::topUp(const QString &method, double amount)
{
	// клієнт обрав іншу суму, а попереднє поповнення ще не оплачене: спершу прибираємо його
	// (сервер обмежує кількість відкритих поповнень), а нове створюємо, коли сервер відповість
	QVariantList pending = wallet_.value("pending").toList();
	for(int i = 0; i < pending.size(); i++)
	{
		const QVariantMap t = pending.at(i).toMap();
		const double base = t.contains("base") ? t.value("base").toDouble() : t.value("amount").toDouble();
		if(t.value("status").toString() == "pending_review" || (t.value("method").toString() == method && qAbs(base - amount) < 1))
			continue;
		pending.removeAt(i);
		wallet_["pending"] = pending;
		emit walletChanged();
		QJsonObject body;
		body["topupId"] = t.value("topupId").toLongLong();
		setBusy(true);
		request("POST", "/api/app/wallet/topup/cancel", body, [this, method, amount](int, const QJsonObject &) {
			setBusy(false);
			topUp(method, amount);
		});
		return;
	}
	const QString action = QStringLiteral("topup|%1|%2").arg(method).arg(amount, 0, 'f', 2);
	QJsonObject body;
	body["method"] = method;
	body["amount"] = amount;
	body["requestId"] = requestId(action);
	setBusy(true);
	request("POST", "/api/app/wallet/topup", body, [this, action, method](int status, const QJsonObject &o) {
		setBusy(false);
		requestDone(action, status);
		if(status == 200 && o.value("ok").toBool())
		{
			// показуємо реквізити одразу, не чекаючи повного списку
			const QVariantMap t = walletTopup(o);
			QVariantList pending { t };
			for(const QVariant &v : wallet_.value("pending").toList())
				if(walletIdOf(v.toMap()) != walletIdOf(t))
					pending << v;
			wallet_["pending"] = pending;
			emit walletChanged();
			emit walletResult(true, QString());
		}
		else
		{
			const QString e = o.value("error").toString();
			const QString cur = method.toUpper();
			const QVariantMap topup = wallet_.value("topup").toMap();
			// межі суми: сервер присилає їх разом з помилкою, інакше беремо з даних балансу
			const double lo = o.contains("min") ? o.value("min").toDouble() : topup.value("min").toMap().value(cur).toDouble();
			const double hi = o.contains("max") ? o.value("max").toDouble() : topup.value("max").toMap().value(cur).toDouble();
			if((e == "amount" || e == "min" || e == "max" || e == "bad") && lo > 0 && hi > 0)
				emit walletResult(false, tr("Поповнити можна на суму від %1 до %2.").arg(walletMoney(lo, cur), walletMoney(hi, cur)));
			else if(e == "limit")
				emit walletResult(false, tr("Уже є відкриті поповнення. Оплати або скасуй їх, тоді можна створити нове."));
			else
				emit walletResult(false, walletError(e, status));
		}
		loadWallet();
	});
}

void AnyPlayCloud::topUpPaid(qint64 topupId, const QString &sender)
{
	QJsonObject body;
	body["topupId"] = topupId;
	body["sender"] = sender.trimmed();
	setBusy(true);
	request("POST", "/api/app/wallet/topup/paid", body, [this](int status, const QJsonObject &o) {
		setBusy(false);
		if(status == 200 && o.value("ok").toBool())
		{
			if(o.value("paid").toBool())
				emit walletResult(true, tr("✓ Оплату вже отримано, баланс поповнено."));
			else if(o.value("auto").toBool())
				emit walletResult(true, tr("Шукаємо твій платіж у виписці, зазвичай до хвилини. Баланс поповниться сам."));
			else
				emit walletResult(true, tr("Адміністратор перевіряє оплату, зазвичай кілька хвилин. Баланс поповниться сам."));
			wallet_polls_ = 0;
			wallet_timer.start();
			if(o.value("paid").toBool())
				refresh();
		}
		else
			emit walletResult(false, walletError(o.value("error").toString(), status));
		loadWallet();
	});
}

void AnyPlayCloud::topUpCancel(qint64 topupId)
{
	QJsonObject body;
	body["topupId"] = topupId;
	// одразу ховаємо це поповнення, сервер підтвердить
	QVariantList pending;
	for(const QVariant &v : wallet_.value("pending").toList())
		if(v.toMap().value("topupId").toLongLong() != topupId)
			pending << v;
	wallet_["pending"] = pending;
	emit walletChanged();
	request("POST", "/api/app/wallet/topup/cancel", body, [this](int status, const QJsonObject &o) {
		if(!(status == 200 && o.value("ok").toBool()) && o.value("error").toString() != "not_found")
			emit walletResult(false, walletError(o.value("error").toString(), status));
		loadWallet();
	});
}

// валюта балансу: клієнт обирає гривні, злоті чи USDT; усе на балансі перераховується за курсом
void AnyPlayCloud::walletCurrency(const QString &currency, bool preview)
{
	QJsonObject body;
	body["currency"] = currency;
	if(preview)
		body["preview"] = true;
	else
		body["requestId"] = QUuid::createUuid().toString(QUuid::WithoutBraces);
	request("POST", "/api/app/wallet/currency", body, [this, preview, currency](int status, const QJsonObject &o) {
		if(status != 200 || !o.value("ok").toBool())
		{
			const QString e = o.value("error").toString();
			emit walletResult(false, status == 404 ? tr("Зміна валюти балансу з'явиться після оновлення сервера.")
				: e == "rates" ? tr("Зараз не вдалося отримати курс. Спробуй за кілька хвилин.")
				: walletError(e, status));
			return;
		}
		if(preview)
		{
			emit walletCurrencyPreview(o.toVariantMap());
			return;
		}
		emit walletResult(true, tr("Готово: баланс тепер у валюті %1.").arg(currency == "UAH" ? tr("гривні") : currency == "PLN" ? tr("злоті") : QStringLiteral("USDT")));
		loadWallet();
		refresh();
	});
}

// ── якість картинки ──
static const char *QUALITY_NAMES[] = { "Економна", "Оптимальна", "Максимальна", "Ультра" };
static const int QUALITY_TOP = 3;
// обробка картинки на ноутбуці для кожного рівня: Fast, Default, HighQuality, HighQualitySpatial (ШІ-чіткість FSRCNNX, лише коли екран більший за 1080p)
static const QmlMainWindow::VideoPreset QUALITY_RENDER[] = { QmlMainWindow::VideoPreset::Fast, QmlMainWindow::VideoPreset::Default,
	QmlMainWindow::VideoPreset::HighQuality, QmlMainWindow::VideoPreset::HighQualitySpatial };

bool AnyPlayCloud::autoQuality() const
{
	return QSettings().value(QStringLiteral("anyplay/auto_quality"), true).toBool();
}

void AnyPlayCloud::setAutoQuality(bool on)
{
	if(on == autoQuality())
		return;
	QSettings().setValue(QStringLiteral("anyplay/auto_quality"), on);
	emit changed();
}

bool AnyPlayCloud::showStats() const
{
	return QSettings().value(QStringLiteral("anyplay/show_stats"), false).toBool();
}

void AnyPlayCloud::setShowStats(bool on)
{
	if(on == showStats())
		return;
	QSettings().setValue(QStringLiteral("anyplay/show_stats"), on);
	emit changed();
}

int AnyPlayCloud::qualityLevel() const
{
	QmlSettings *qs = backend->qmlSettings();
	if(!qs)
		return 1;
	const int res = qs->resolutionRemotePS5(), fps = qs->fpsRemotePS5();
	if(res <= 2)
		return 0;
	if(res >= 4)
	{
		// «Ультра» — ШІ-чіткість; найважчу ШІ з розширених налаштувань теж вважаємо «Ультра»
		const int p = qs->videoPreset();
		return p == static_cast<int>(PlaceboPreset::HighQualitySpatial) || p == static_cast<int>(PlaceboPreset::HighQualityAdvancedSpatial) ? 3 : 2;
	}
	return fps >= 60 ? 1 : 0;
}

void AnyPlayCloud::setQualityLevel(int level)
{
	QmlSettings *qs = backend->qmlSettings();
	if(!qs)
		return;
	level = qBound(0, level, QUALITY_TOP);
	const int res = level == 0 ? 2 : level == 1 ? 3 : 4;
	const int fps = level == 0 ? 30 : 60;
	// через інтернет завеликий бітрейт забиває канал і дає затримку, тому тут стеля нижча, ніж у домашній мережі
	qs->setResolutionRemotePS5(res); qs->setFpsRemotePS5(fps); qs->setBitrateRemotePS5(level >= 2 ? 15000 : 0);
	qs->setResolutionLocalPS5(res);  qs->setFpsLocalPS5(fps);  qs->setBitrateLocalPS5(level >= 2 ? 25000 : 0);
	// H.265: при тій самій швидкості інтернету картинка чистіша, ніж у H.264 (HDR, якщо його обрали, лишаємо: це теж H.265)
	if(!chiaki_codec_is_h265(static_cast<ChiakiCodec>(qs->codecRemotePS5())))
		qs->setCodecRemotePS5(CHIAKI_CODEC_H265);
	if(!chiaki_codec_is_h265(static_cast<ChiakiCodec>(qs->codecLocalPS5())))
		qs->setCodecLocalPS5(CHIAKI_CODEC_H265);
	// рівень обрали вручну: даємо ноутбуку нову спробу без старого обмеження обробки
	if(!autoQuality())
	{
		QSettings s;
		s.remove(QStringLiteral("anyplay/render_cap"));
		s.remove(QStringLiteral("anyplay/render_cap_until"));
	}
	applyRender(level);
	emit changed();
}

void AnyPlayCloud::prepareAutoQuality()
{
	{
		// до 108 вертикальна синхронізація хибно здавалась «ноутбук не встигає» і обробку спрощувало на 3 дні: знімаємо це обмеження один раз
		QSettings s0;
		if(s0.value(QStringLiteral("anyplay/render_cap_reset"), 0).toInt() < 108)
		{
			s0.remove(QStringLiteral("anyplay/render_cap"));
			s0.remove(QStringLiteral("anyplay/render_cap_until"));
			s0.setValue(QStringLiteral("anyplay/render_cap_reset"), 108);
		}
	}
	QmlSettings *qs = backend->qmlSettings();
	if(!qs)
		return;
	if(qs->bitrateRemotePS5() > 15000)   // старе значення «Максимальної»: через інтернет воно давало затримку
		qs->setBitrateRemotePS5(15000);
	applyRender(qualityLevel(), true);   // перед кожною грою: обробка картинки під рівень (з урахуванням слабкого ноутбука)
	if(!autoQuality())
		return;
	QSettings s;
	const qint64 now = QDateTime::currentSecsSinceEpoch();
	if(s.value(QStringLiteral("anyplay/auto_up"), false).toBool())
	{
		s.remove(QStringLiteral("anyplay/auto_up"));
		const int level = qualityLevel();
		// свою обробку (Custom) «Авто» не замінює на ШІ-чіткість, тому вище «Максимальної» тоді не йдемо
		const int top = qs->videoPreset() == static_cast<int>(PlaceboPreset::Custom) ? 2 : QUALITY_TOP;
		if(level < top && now > s.value(QStringLiteral("anyplay/auto_no_up_until"), 0).toLongLong())
		{
			setQualityLevel(level + 1);
			s.setValue(QStringLiteral("anyplay/auto_raised_at"), now);
		}
	}
}

void AnyPlayCloud::applyRender(int level, bool keepOwn)
{
	level = qBound(0, level, QUALITY_TOP);
	QmlSettings *qs = backend->qmlSettings();
	// свою обробку з розширених налаштувань (власну чи найважчу ШІ) перед грою не перезаписуємо
	const int saved = qs ? qs->videoPreset() : -1;
	const bool own = keepOwn && (saved == static_cast<int>(PlaceboPreset::Custom) || saved == static_cast<int>(PlaceboPreset::HighQualityAdvancedSpatial));
	if(qs && !own)
		qs->setVideoPreset(static_cast<int>(level == 0 ? PlaceboPreset::Fast : level == 1 ? PlaceboPreset::Default
			: level == 2 ? PlaceboPreset::HighQuality : PlaceboPreset::HighQualitySpatial));
	// якщо цей ноутбук нещодавно не встигав, обробку тримаємо не вище тієї, що він тягнув (3 дні)
	QSettings s;
	int r = level;
	if(QDateTime::currentSecsSinceEpoch() < s.value(QStringLiteral("anyplay/render_cap_until"), 0).toLongLong())
		r = qMin(r, s.value(QStringLiteral("anyplay/render_cap"), QUALITY_TOP).toInt());
	r = qBound(0, r, QUALITY_TOP);
	// PlaceboPreset і VideoPreset ідуть в однаковому порядку
	if(QmlMainWindow *w = backend->qmlWindow())
		w->setVideoPreset(own && r >= level ? static_cast<QmlMainWindow::VideoPreset>(saved) : QUALITY_RENDER[r]);   // діє одразу, без перепідключення
}

bool AnyPlayCloud::renderLighter()
{
	QmlMainWindow *w = backend->qmlWindow();
	if(!w)
		return false;
	const auto p = w->videoPreset();
	QmlMainWindow::VideoPreset next;
	if(p == QmlMainWindow::VideoPreset::HighQualitySpatial || p == QmlMainWindow::VideoPreset::HighQualityAdvancedSpatial || p == QmlMainWindow::VideoPreset::Custom)
		next = QmlMainWindow::VideoPreset::HighQuality;
	else if(p == QmlMainWindow::VideoPreset::HighQuality)
		next = QmlMainWindow::VideoPreset::Default;
	else if(p == QmlMainWindow::VideoPreset::Default)
		next = QmlMainWindow::VideoPreset::Fast;
	else
		return false;
	// рівень у налаштуваннях не чіпаємо; лише обмежуємо обробку на цьому ноутбуці на 3 дні
	QSettings s;
	render_undo_ = { static_cast<int>(p), s.value(QStringLiteral("anyplay/render_cap")), s.value(QStringLiteral("anyplay/render_cap_until")) };
	w->setVideoPreset(next);
	s.setValue(QStringLiteral("anyplay/render_cap"), next == QmlMainWindow::VideoPreset::HighQuality ? 2 : next == QmlMainWindow::VideoPreset::Default ? 1 : 0);
	s.setValue(QStringLiteral("anyplay/render_cap_until"), QDateTime::currentSecsSinceEpoch() + 3 * 24 * 3600);
	// повідомлення показує сам екран гри (тост головного екрана тут не видно, а після гри він уже застарів)
	return true;
}

void AnyPlayCloud::renderUndo()
{
	if(render_undo_.preset < 0)
		return;
	if(QmlMainWindow *w = backend->qmlWindow())
		w->setVideoPreset(static_cast<QmlMainWindow::VideoPreset>(render_undo_.preset));
	QSettings s;
	if(render_undo_.cap.isValid())
		s.setValue(QStringLiteral("anyplay/render_cap"), render_undo_.cap);
	else
		s.remove(QStringLiteral("anyplay/render_cap"));
	if(render_undo_.until.isValid())
		s.setValue(QStringLiteral("anyplay/render_cap_until"), render_undo_.until);
	else
		s.remove(QStringLiteral("anyplay/render_cap_until"));
	render_undo_.preset = -1;
}

bool AnyPlayCloud::autoQualityDown()
{
	const int level = qualityLevel();
	if(level <= 0)
		return false;
	QSettings s;
	const qint64 now = QDateTime::currentSecsSinceEpoch();
	s.remove(QStringLiteral("anyplay/auto_up"));
	// щойно підняли якість, а зв'язок не витримав — кілька днів вище не пробуємо
	if(now - s.value(QStringLiteral("anyplay/auto_raised_at"), 0).toLongLong() < 20 * 60)
		s.setValue(QStringLiteral("anyplay/auto_no_up_until"), now + 3 * 24 * 3600);
	// «Ультра» і «Максимальна» йдуть з однаковою швидкістю, тому зі слабким зв'язком з «Ультра» одразу на «Оптимальну»
	const int to = level == 3 ? 1 : level - 1;
	setQualityLevel(to);
	emit message(tr("Зв'язок слабкий: знижую якість до «%1», щоб не було затримок. Гра перепідключиться сама.")
		.arg(QString::fromUtf8(QUALITY_NAMES[to])));
	return true;
}

void AnyPlayCloud::autoQualityGood()
{
	if(autoQuality() && qualityLevel() < QUALITY_TOP)
		QSettings().setValue(QStringLiteral("anyplay/auto_up"), true);
}

void AnyPlayCloud::copyText(const QString &text)
{
	if(QGuiApplication::clipboard())
		QGuiApplication::clipboard()->setText(text);
	emit message(tr("Скопійовано: %1").arg(text));
}

QString AnyPlayCloud::qrUrl() const
{
	if(!my_psn_qr_ || token_.isEmpty())
		return QString();
	QUrl url(server_ + "/api/app/psn/qr");
	QUrlQuery q;
	q.addQueryItem("t", token_);
	q.addQueryItem("r", QString::number(qr_rev_));
	url.setQuery(q);
	return url.toString();
}

bool AnyPlayCloud::beginMyPsnLogin()
{
	if(backend->qmlSession())
	{
		emit message(tr("Спершу заверши гру (або зроби це до її початку) — вхід у PSN займе хвилину."));
		return false;
	}
	psn_login_active_ = true;
	settings->ClearAnyPlayEphemeral();   // далі вхід PSN запишеться саме для клієнта
	settings->SetPsnRefreshToken(QString());
	settings->SetPsnAuthToken(QString());
	settings->SetPsnAccountId(QString());
	QSettings().remove(QStringLiteral("anyplay/psn_online_id"));
	psn_wait_tries_ = 0;
	psn_wait_timer.start();
	return true;
}

void AnyPlayCloud::sendMyPsnLogin()
{
	QString acc = settings->GetPsnAccountId(), rt = settings->GetPsnRefreshToken();
	if(acc.isEmpty() || rt.isEmpty())
	{
		if(++psn_wait_tries_ > 600)   // 10 хв без входу — скасовуємо
		{
			psn_wait_timer.stop();
			psn_login_active_ = false;
			refresh();
		}
		return;
	}
	psn_wait_timer.stop();
	QJsonObject body;
	body["accountId"] = acc;
	body["onlineId"] = QSettings().value(QStringLiteral("anyplay/psn_online_id")).toString();
	body["refresh_token"] = rt;
	body["auth_token"] = settings->GetPsnAuthToken();
	QDateTime exp = QDateTime::fromString(settings->GetPsnAuthTokenExpiry(), settings->GetTimeFormat());
	body["expiry"] = exp.isValid() ? exp.toSecsSinceEpoch() + skew_ : 0;
	request("POST", "/api/app/psn/link", body, [this](int status, const QJsonObject &o) {
		psn_login_active_ = false;
		if(status == 200 && o.value("ok").toBool())
			emit message(tr("✓ Вхід у PSN виконано. Тепер адміністратор додасть твій профіль на приставку — це кілька хвилин."));
		else
			emit message(tr("Не вдалося передати вхід PSN (помилка %1). Спробуй ще раз.").arg(status));
		refresh();
	});
}

void AnyPlayCloud::myPsnDone()
{
	request("POST", "/api/app/psn/done", QJsonObject(), [this](int status, const QJsonObject &o) {
		emit message(status == 200 && o.value("ok").toBool()
			? tr("Дякуємо! Адміністратор завершує підключення приставки до твого акаунта — ще 1–2 хвилини.")
			: tr("Не вдалося надіслати (помилка %1).").arg(status));
		refresh();
	});
}

void AnyPlayCloud::linkClientConsole(qint64 userId, const QString &accountId, const QString &pin)
{
	if(!admin_)
		return;
	QByteArray account = QByteArray::fromBase64(accountId.toUtf8());
	if(account.size() != CHIAKI_PSN_ACCOUNT_ID_SIZE)
	{
		emit linkResult(false, tr("Клієнт ще не увійшов у PSN у своїй програмі — попроси його натиснути «Увійти в PSN»."));
		return;
	}
	QString digits = pin;
	digits.remove(QRegularExpression("[^0-9]"));
	if(digits.size() != 8)
	{
		emit linkResult(false, tr("Код має бути з 8 цифр — він на екрані PS5."));
		return;
	}
	// спершу пробуємо PS5, яку програма вже бачить у мережі (точна адреса), і лише потім — пошук по всій мережі
	startClientLink(userId, account, digits, backend->discoveredPs5Address());
}

void AnyPlayCloud::startClientLink(qint64 userId, const QByteArray &account, const QString &digits, const QString &host)
{
	ChiakiRegistInfo info = {};
	QByteArray hostb = host.isEmpty() ? QByteArrayLiteral("255.255.255.255") : host.toUtf8();
	info.host = hostb.constData();
	info.target = CHIAKI_TARGET_PS5_1;
	info.broadcast = host.isEmpty();
	info.pin = (uint32_t)digits.toULong();
	info.console_pin = 0;
	info.holepunch_info = nullptr;
	info.rudp = nullptr;
	info.psn_online_id = nullptr;
	memcpy(info.psn_account_id, account.constData(), CHIAKI_PSN_ACCOUNT_ID_SIZE);
	setBusy(true);
	auto regist = new QmlRegist(info, settings->GetLogLevelMask(), this);
	auto errors = std::make_shared<QStringList>();
	connect(regist, &QmlRegist::log, this, [errors](ChiakiLogLevel level, const QString &msg) {
		if(level == CHIAKI_LOG_ERROR)
			errors->append(msg);
	});
	connect(regist, &QmlRegist::failed, this, [this, errors, userId, account, digits, host]() {
		const QString all = errors->join(QLatin1Char('\n'));
		const bool rejected = all.contains(QLatin1String("HTTP code")) || all.contains(QLatin1String("Application Reason"));
		if(!host.isEmpty() && !rejected)
		{
			// за точною адресою не вийшло, а приставка код ще не відхиляла — пробуємо пошук по всій мережі
			startClientLink(userId, account, digits, QString());
			return;
		}
		setBusy(false);
		emit linkResult(false, linkErrorText(all));
	});
	connect(regist, &QmlRegist::success, this, [this, userId](const RegisteredHost &rhost) {
		// прив'язку клієнта НЕ зберігаємо в цій програмі — лише передаємо на сервер (своя прив'язка адміна лишається)
		QJsonObject body;
		body["host"] = QJsonObject::fromVariantMap(rhost.ToVariantMap());
		body["ownerUserId"] = userId;
		body["label"] = rhost.GetServerNickname();
		saveClientLink(body, 0);
	});
}

// Приставка вже видала ключ — його не можна втратити: якщо сервер недоступний (перезапуск, зв'язок), пробуємо ще
void AnyPlayCloud::saveClientLink(const QJsonObject &body, int attempt)
{
	request("POST", "/api/app/console", body, [this, body, attempt](int status, const QJsonObject &o) {
		if(status == 200 && o.value("ok").toBool())
		{
			setBusy(false);
			emit linkResult(true, tr("✓ Готово! Клієнт тепер грає на своєму акаунті — і наступного разу теж. Йому прийшло повідомлення."));
			refreshAdmin();
			return;
		}
		const bool temporary = status == 0 || status >= 500;
		if(temporary && attempt < 8)
		{
			QTimer::singleShot(4000, this, [this, body, attempt]() { saveClientLink(body, attempt + 1); });
			return;
		}
		setBusy(false);
		emit linkResult(false, o.value("error").toString() == "client_psn"
			? tr("Клієнт ще не увійшов у PSN у своїй програмі.")
			: tr("Приставка прийняла код, але зберегти на сервері не вдалося (помилка %1). Згенеруй новий код і спробуй ще раз.").arg(status));
		refreshAdmin();
	});
}

// Зрозуміла причина, чому PS5 не прив'язалась (за тим, що повідомила бібліотека), плюс технічний рядок для підтримки
QString AnyPlayCloud::linkErrorText(const QString &errors) const
{
	QString last = errors.section(QLatin1Char('\n'), -1).trimmed();
	QString text;
	if(errors.contains(QLatin1String("HTTP code")) || errors.contains(QLatin1String("Application Reason")))
		text = tr("PS5 відхилила код. Зазвичай це означає одне з трьох: код згенеровано не під профілем цього клієнта, код уже використано або минуло 5 хвилин. На PS5 перемкнись на профіль клієнта, відкрий «Прив'язати пристрій» заново і введи новий код.");
	else if(errors.contains(QLatin1String("refused the registration search")))
		text = tr("PS5 знайдено, але вона зараз не чекає на прив'язку. Тримай на PS5 відкритим екран «Прив'язати пристрій» з кодом, поки програма прив'язує.");
	else if(errors.contains(QLatin1String("search")) || errors.contains(QLatin1String("connect")))
		text = tr("Програма не знайшла PS5 у локальній мережі. Перевір: цей комп'ютер і PS5 підключені до одного роутера, VPN вимкнено, на PS5 відкритий екран з кодом. На Mac: Системні налаштування → Приватність і безпека → Локальна мережа → AnyPlay увімкнено. Клієнту бути в цій мережі не потрібно.");
	else
		text = tr("PS5 не вдалося прив'язати. Перевір, що цей комп'ютер і PS5 в одній мережі, а код свіжий (діє 5 хв) і згенерований під профілем клієнта.");
	if(!last.isEmpty())
		text += QStringLiteral("\n") + tr("Технічно: %1").arg(last);
	return text;
}


// ═════════ етап 3: підтримка (К11), перегляд гри (К12), журнал (К13), CRM у програмі (К10) ═════════

void AnyPlayCloud::rawRequest(const QString &method, const QString &path, const QByteArray &contentType, const QByteArray &body,
                              std::function<void(int, const QByteArray &, const QByteArray &)> done)
{
	QNetworkRequest req(QUrl(server_ + path));
	req.setTransferTimeout(30000);
	req.setRawHeader("X-AnyPlay-Build", QByteArray::number(ANYPLAY_BUILD));
	req.setRawHeader("X-AnyPlay-Platform", anyplayPlatform());
	if(!token_.isEmpty())
		req.setRawHeader("Authorization", "Bearer " + token_.toUtf8());
	if(!contentType.isEmpty())
		req.setHeader(QNetworkRequest::ContentTypeHeader, contentType);
	QNetworkReply *reply = method == "GET" ? nam.get(req) : nam.post(req, body);
	connect(reply, &QNetworkReply::finished, this, [reply, done]() {
		reply->deleteLater();
		const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
		const QByteArray type = reply->header(QNetworkRequest::ContentTypeHeader).toByteArray();
		done(status, reply->readAll(), type);
	});
}

void AnyPlayCloud::applyExtras(const QJsonObject &o)
{
	// підтримка: скільки нових відповідей адміна (крапка на кнопці «Підтримка»)
	if(o.value("support").isObject())
	{
		const QJsonObject sup = o.value("support").toObject();
		const int unread = sup.value("unread").toInt();
		const qint64 last = sup.value("lastId").toVariant().toLongLong();
		if(unread != support_unread_)
		{
			support_unread_ = unread;
			emit supportChanged();
		}
		// чат уже відкривали: нові повідомлення підтягуємо одразу
		if(support_loaded_ && last > support_last_id_)
			loadSupport();
	}
	// перегляд гри: адмін дивиться — надсилаємо зменшені кадри до until
	if(o.value("preview").isObject())
	{
		const QJsonObject pv = o.value("preview").toObject();
		const qint64 until = pv.value("until").toVariant().toLongLong();
		if(pv.value("want").toBool() && until > 0)
		{
			preview_until_ms_ = (until - skew_) * 1000;
			const double interval = pv.value("interval").toDouble(1.5);
			// ноутбук не встигає малювати (обробку спрощено): кадри вдвічі рідше
			const bool weak = QSettings().contains(QStringLiteral("anyplay/render_cap"));
			preview_timer.setInterval(qBound(500, int(interval * 1000.0 * (weak ? 2 : 1)), 10000));
			preview_width_ = qBound(160, pv.value("width").toInt(480), 960);
			if(!preview_timer.isActive() && QDateTime::currentMSecsSinceEpoch() < preview_until_ms_)
			{
				preview_timer.start();
				previewTick();
			}
		}
		else
		{
			preview_until_ms_ = 0;
			preview_timer.stop();
		}
	}
	// адмін попросив журнал програми (CRM → «Отримати журнал»)
	if(o.value("sendLog").toBool())
	{
		const qint64 now = QDateTime::currentMSecsSinceEpoch();
		if(now - log_admin_ms_ > 60 * 1000)
		{
			log_admin_ms_ = now;
			uploadLog(QStringLiteral("admin"));
		}
	}
}

// ── підтримка (К11) ──

void AnyPlayCloud::mergeSupport(const QJsonArray &messages, bool replace)
{
	if(replace)
		support_msgs_.clear();
	QSet<qint64> have;
	for(const QVariant &v : support_msgs_)
		have.insert(v.toMap().value("id").toLongLong());
	for(const QJsonValue &v : messages)
	{
		const QVariantMap m = v.toObject().toVariantMap();
		const qint64 id = m.value("id").toLongLong();
		if(id && have.contains(id))
			continue;
		have.insert(id);
		support_msgs_.append(m);
		support_last_id_ = qMax(support_last_id_, id);
	}
	std::sort(support_msgs_.begin(), support_msgs_.end(), [](const QVariant &a, const QVariant &b) {
		return a.toMap().value("id").toLongLong() < b.toMap().value("id").toLongLong();
	});
}

void AnyPlayCloud::loadSupport()
{
	if(!loggedIn() || support_loading_)
		return;
	support_loading_ = true;
	const bool full = !support_loaded_;
	const QString path = full ? QStringLiteral("/api/app/support")
	                          : QStringLiteral("/api/app/support?after=%1").arg(support_last_id_);
	request("GET", path, QJsonObject(), [this, full](int status, const QJsonObject &o) {
		support_loading_ = false;
		if(status != 200 || !o.value("ok").toBool())
		{
			if(full)
				emit supportResult(false, status == 404
					? tr("Чат у програмі ще не працює на сервері. Напиши в бот: кнопка «Підтримка».")
					: tr("Не вдалося завантажити чат. Перевір інтернет і спробуй ще раз."));
			return;
		}
		mergeSupport(o.value("messages").toArray(), full);
		support_hours_ = o.value("hours").toString();
		support_typing_ = o.value("typing").toBool();
		support_loaded_ = true;
		support_unread_ = 0;   // чат відкрито: усе прочитано (сервер так само рахує прочитаним те, що віддав)
		emit supportChanged();
	});
}

void AnyPlayCloud::sendSupport(const QString &text)
{
	const QString t = text.trimmed();
	if(t.isEmpty() || !loggedIn())
		return;
	support_sending_ = true;
	emit supportChanged();
	QJsonObject body;
	body["text"] = t.left(4000);
	request("POST", "/api/app/support/send", body, [this](int status, const QJsonObject &o) {
		support_sending_ = false;
		emit supportChanged();
		if(status == 200 && o.value("ok").toBool())
		{
			emit supportResult(true, QString());
			loadSupport();
		}
		else
			emit supportResult(false, tr("Не вдалося надіслати. Перевір інтернет і спробуй ще раз."));
	});
}

void AnyPlayCloud::sendSupportPhoto(const QUrl &file)
{
	const QString path = file.isLocalFile() ? file.toLocalFile() : file.toString();
	QFile *f = new QFile(path);
	if(!f->open(QIODevice::ReadOnly))
	{
		delete f;
		emit supportResult(false, tr("Не вдалося відкрити файл."));
		return;
	}
	if(f->size() > 8 * 1024 * 1024)
	{
		delete f;
		emit supportResult(false, tr("Фото завелике: до 8 МБ."));
		return;
	}
	QHttpMultiPart *multi = new QHttpMultiPart(QHttpMultiPart::FormDataType);
	QHttpPart part;
	const QString mime = QMimeDatabase().mimeTypeForFile(path).name();
	QString name = QFileInfo(path).fileName();
	name.replace(QLatin1Char('"'), QLatin1Char('_'));
	part.setHeader(QNetworkRequest::ContentTypeHeader, mime.startsWith(QLatin1String("image/")) ? mime : QStringLiteral("image/jpeg"));
	part.setHeader(QNetworkRequest::ContentDispositionHeader, QStringLiteral("form-data; name=\"photo\"; filename=\"%1\"").arg(name));
	part.setBodyDevice(f);
	f->setParent(multi);
	multi->append(part);
	QNetworkRequest req(QUrl(server_ + "/api/app/support/photo"));
	req.setTransferTimeout(60000);
	req.setRawHeader("X-AnyPlay-Build", QByteArray::number(ANYPLAY_BUILD));
	req.setRawHeader("X-AnyPlay-Platform", anyplayPlatform());
	req.setRawHeader("Authorization", "Bearer " + token_.toUtf8());
	support_sending_ = true;
	emit supportChanged();
	QNetworkReply *reply = nam.post(req, multi);
	multi->setParent(reply);
	connect(reply, &QNetworkReply::finished, this, [this, reply]() {
		reply->deleteLater();
		support_sending_ = false;
		emit supportChanged();
		const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
		const QJsonObject o = QJsonDocument::fromJson(reply->readAll()).object();
		if(status == 200 && o.value("ok").toBool())
		{
			emit supportResult(true, QString());
			loadSupport();
		}
		else
			emit supportResult(false, status == 413 ? tr("Фото завелике: до 8 МБ.") : tr("Не вдалося надіслати фото. Спробуй ще раз."));
	});
}

void AnyPlayCloud::loadSupportImage(const QString &fileUrl)
{
	if(fileUrl.isEmpty())
		return;
	// фото з чату вимагає входу (заголовок), тому вантажимо самі й даємо QML як data:-адресу
	const QString path = fileUrl.startsWith(server_) ? fileUrl.mid(server_.size()) : fileUrl;
	if(!path.startsWith(QLatin1Char('/')))
		return;
	rawRequest("GET", path, QByteArray(), QByteArray(), [this, fileUrl](int status, const QByteArray &data, const QByteArray &type) {
		if(status != 200 || data.isEmpty())
			return;
		const QByteArray mime = type.isEmpty() ? QByteArrayLiteral("image/jpeg") : type.split(';').first().trimmed();
		emit supportImage(fileUrl, QStringLiteral("data:%1;base64,%2").arg(QString::fromLatin1(mime), QString::fromLatin1(data.toBase64())));
	});
}

void AnyPlayCloud::reportPicture(const QString &note)
{
	complaint_ = true;
	uploadLog(note.isEmpty() ? QStringLiteral("complaint") : QStringLiteral("complaint: ") + note.left(300));
	if(playing_)
		QTimer::singleShot(500, this, &AnyPlayCloud::heartbeat);   // скарга одразу видна адміну в «здоров'ї» картинки
	emit message(tr("Дякуємо! Ми отримали журнал програми й подивимось, що з картинкою."));
}

// ── перегляд гри клієнта (К12) ──

void AnyPlayCloud::previewTick()
{
	QmlMainWindow *w = backend->qmlWindow();
	if(!playing_ || !w || !backend->qmlSession() || QDateTime::currentMSecsSinceEpoch() >= preview_until_ms_)
	{
		preview_timer.stop();
		return;
	}
	if(preview_busy_)
		return;   // попередній кадр ще готується або летить: не накопичуємо
	if(w->metaObject()->indexOfMethod("requestPreviewFrame(int)") >= 0
		&& QMetaObject::invokeMethod(w, "requestPreviewFrame", Qt::QueuedConnection, Q_ARG(int, preview_width_)))
		preview_busy_ = true;
	else
		preview_timer.stop();   // вікно не вміє давати кадри
}

void AnyPlayCloud::onPreviewFrame(const QByteArray &jpeg)
{
	if(jpeg.isEmpty() || jpeg.size() > 200 * 1024 || !playing_)
	{
		preview_busy_ = false;
		return;
	}
	rawRequest("POST", "/api/app/preview", "image/jpeg", jpeg, [this](int status, const QByteArray &, const QByteArray &) {
		preview_busy_ = false;
		if(status == 404 || status == 410)
		{
			preview_until_ms_ = 0;   // сервер не хоче кадрів (адмін закрив перегляд або сервер старий)
			preview_timer.stop();
		}
	});
}

void AnyPlayCloud::loadPreview(qint64 bookingId)
{
	if(!admin_ || preview_loading_ || bookingId <= 0)
		return;
	preview_loading_ = true;
	rawRequest("GET", QStringLiteral("/api/app/admin/preview?bookingId=%1").arg(bookingId), QByteArray(), QByteArray(),
		[this](int status, const QByteArray &data, const QByteArray &type) {
		preview_loading_ = false;
		if(status != 200 || data.isEmpty() || !type.startsWith("image/"))
			return;
		preview_image_ = QStringLiteral("data:image/jpeg;base64,") + QString::fromLatin1(data.toBase64());
		preview_at_ = QDateTime::currentSecsSinceEpoch() + skew_;
		emit previewChanged();
	});
}

void AnyPlayCloud::clearPreview()
{
	if(preview_image_.isEmpty() && !preview_at_)
		return;
	preview_image_.clear();
	preview_at_ = 0;
	emit previewChanged();
}

// ── журнал програми (К13) ──

static QByteArray logTail(const QString &file, qint64 max)
{
	QFile f(file);
	if(max <= 0 || !f.open(QIODevice::ReadOnly))
		return QByteArray();
	const qint64 size = f.size();
	if(size > max)
	{
		f.seek(size - max);
		f.readLine();   // з початку цілого рядка
	}
	return f.readAll();
}

void AnyPlayCloud::uploadLog(const QString &reason)
{
	if(!loggedIn())
		return;
	const QString dir = GetLogBaseDir();
	QFileInfoList files;
	if(!dir.isEmpty())
		files = QDir(dir).entryInfoList({ QStringLiteral("chiaki_session_*.log") }, QDir::Files, QDir::Time);
	const qint64 limit = 480 * 1024;
	// найновіший журнал; якщо він короткий (гра щойно почалась), спереду ще кінець попереднього
	QByteArray tail;
	if(!files.isEmpty())
	{
		tail = logTail(files[0].absoluteFilePath(), limit);
		if(files.size() > 1 && files[0].size() < 64 * 1024)
		{
			const QByteArray prev = logTail(files[1].absoluteFilePath(), limit - tail.size());
			if(!prev.isEmpty())
				tail = "──── " + files[1].fileName().toUtf8() + " ────\n" + prev + "\n──── " + files[0].fileName().toUtf8() + " ────\n" + tail;
		}
	}
	// про всяк випадок прибираємо токен пристрою, якщо він десь потрапив у журнал
	if(!token_.isEmpty())
		tail.replace(token_.toUtf8(), QByteArrayLiteral("<token>"));
	QByteArray head;
	head += "AnyPlay " + QByteArray::number(ANYPLAY_BUILD) + " " + anyplayPlatform() + " " + QSysInfo::prettyProductName().toUtf8()
		+ " " + QSysInfo::currentCpuArchitecture().toUtf8() + "\n";
	head += "reason: " + reason.toUtf8() + "\n";
	head += "time: " + QDateTime::currentDateTime().toString(Qt::ISODate).toUtf8() + "\n";
	head += "quality: " + QByteArray::number(qualityLevel()) + (autoQuality() ? " auto" : "") + "\n";
	if(files.isEmpty())
		head += "(журналів трансляції на цьому комп'ютері ще немає)\n";
	head += "\n";
	rawRequest("POST", "/api/app/log", "text/plain; charset=utf-8", head + tail, [](int status, const QByteArray &, const QByteArray &) {
		if(status != 200)
			qWarning() << "AnyPlay: log upload failed with HTTP" << status;
	});
}

// ── CRM у програмі (К10) ──

bool AnyPlayCloud::webEngine() const
{
#ifdef CHIAKI_HAVE_WEBENGINE
	return true;
#else
	return false;
#endif
}

QString AnyPlayCloud::crmUrl() const
{
	return server_ + QStringLiteral("/app/admin.html");
}

bool AnyPlayCloud::isOwnUrl(const QUrl &url) const
{
	const QUrl own(server_);
	const int def = own.scheme() == QLatin1String("https") ? 443 : 80;
	return url.scheme() == own.scheme() && url.host() == own.host() && url.port(def) == own.port(def);
}

QString AnyPlayCloud::webAppScript() const
{
	if(token_.isEmpty())
		return QString();
	const QUrl own(server_);
	QJsonObject app;
	app["token"] = token_;
	app["platform"] = QString::fromLatin1(anyplayPlatform());
	app["build"] = ANYPLAY_BUILD;
	const QByteArray json = QJsonDocument(app).toJson(QJsonDocument::Compact);
	QJsonObject where;
	where["host"] = own.host();
	where["protocol"] = own.scheme() + QLatin1Char(':');
	const QByteArray whereJson = QJsonDocument(where).toJson(QJsonDocument::Compact);
	// токен пристрою отримує лише сторінка нашого сервера; на будь-якій іншій адресі скрипт нічого не робить
	return QStringLiteral(
		"(function(){var w=%1;if(location.protocol!==w.protocol||location.hostname!==w.host)return;"
		"try{Object.defineProperty(window,'AnyPlayApp',{value:Object.freeze(%2),writable:false,configurable:false});}catch(e){}})();")
		.arg(QString::fromUtf8(whereJson), QString::fromUtf8(json));
}

void AnyPlayCloud::openExternal(const QUrl &url)
{
	const QString scheme = url.scheme().toLower();
	if(scheme == QLatin1String("https") || scheme == QLatin1String("http") || scheme == QLatin1String("tg") || scheme == QLatin1String("mailto"))
		QDesktopServices::openUrl(url);
}
