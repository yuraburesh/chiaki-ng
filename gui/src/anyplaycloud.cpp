#include "anyplaycloud.h"
#include "settings.h"
#include "qmlbackend.h"

#include <QClipboard>
#include <QDateTime>
#include <QGuiApplication>
#include <QDesktopServices>
#include <QJsonArray>
#include <QJsonDocument>
#include <QNetworkReply>
#include <QSettings>
#include <QSysInfo>
#include <QUrl>
#include <QUrlQuery>
#include <QRegularExpression>
#include <memory>

static const char *DEFAULT_SERVER = "https://34-123-25-16.sslip.io";
static const int POLL_MS = 60 * 1000;
static const int BEAT_MS = 20 * 1000;
static const int PAIR_MS = 2000;
static const int PAIR_MAX_TRIES = 300; // ~10 хв

// Номер версії програми: сервер порівнює його з мінімальним і просить оновитись, якщо програма застаріла
static const int ANYPLAY_BUILD = 102;

AnyPlayCloud::AnyPlayCloud(Settings *settings, QmlBackend *backend, QObject *parent)
	: QObject(parent), settings(settings), backend(backend)
{
	QSettings s;
	server_ = s.value("anyplay/server", DEFAULT_SERVER).toString();
	token_ = s.value("anyplay/device_token").toString();

	poll_timer.setInterval(POLL_MS);
	connect(&poll_timer, &QTimer::timeout, this, &AnyPlayCloud::refresh);
	beat_timer.setInterval(BEAT_MS);
	connect(&beat_timer, &QTimer::timeout, this, &AnyPlayCloud::heartbeat);
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

void AnyPlayCloud::login()
{
	QJsonObject body;
	body["name"] = QSysInfo::machineHostName();
	setState("pairing");
	request("POST", "/api/app/pair", body, [this](int status, const QJsonObject &o) {
		if(status != 200 || !o.value("ok").toBool())
		{
			setState("login");
			emit message(tr("Сервер AnyPlay недоступний. Перевір інтернет і спробуй ще раз."));
			return;
		}
		pair_code_ = o.value("code").toString();
		pair_tries_ = 0;
		QDesktopServices::openUrl(QUrl(o.value("link").toString()));
		pair_timer.start();
	}, false);
}

void AnyPlayCloud::cancelLogin()
{
	pair_timer.stop();
	pair_code_.clear();
	setState(loggedIn() ? "wait" : "login");
}

void AnyPlayCloud::logout()
{
	stopPlay(QString());
	token_.clear();
	QSettings().remove("anyplay/device_token");
	poll_timer.stop();
	admin_ = false;
	user_.clear();
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
	admin_ = o.value("admin").toBool();
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
			emit message(tr("✅ Твій акаунт PSN підключено — можна грати на своєму акаунті!"));
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
	QString st = o.value("state").toString();

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
	else
	{
		if(playing_ || settings->HasAnyPlayEphemeral())
			stopPlay(QString());
		setState(st == "no_console" ? "no_console" : st == "update" ? "update" : "wait");
	}
	emit changed();
}

void AnyPlayCloud::heartbeat()
{
	if(!playing_)
		return;
	QJsonObject body;
	body["streaming"] = backend->qmlSession() != nullptr;
	request("POST", "/api/app/heartbeat", body, [this](int status, const QJsonObject &o) {
		if(status == 401)
		{
			stopPlay(tr("Доступ скасовано адміністратором."));
			logout();
			return;
		}
		if(status != 200)
			return; // тимчасові проблеми зі зв'язком не обривають гру
		if(!o.value("continue").toBool())
		{
			QString reason = o.value("reason").toString() == "kicked"
				? tr("Сеанс завершив адміністратор AnyPlay.")
				: tr("Час твоєї броні вийшов — дякуємо за гру! Забронювати ще можна тут, кнопкою «Бронювання».");
			stopPlay(reason);
			refresh();
			return;
		}
		qint64 end = o.value("end").toVariant().toLongLong();
		if(end_ > 0 && end > end_)
		{
			emit message(tr("✅ Оплату отримано — гру продовжено до %1").arg(formatTime(end)));
			emit extendResult(true, tr("✅ Оплату отримано — гру продовжено до %1").arg(formatTime(end)));
			pay_timer.stop();
			loadExtend();
		}
		end_ = end;
		emit changed();
	});
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
			? (name.isEmpty() ? tr("✅ PS5 і вхід PSN передано на сервер. Клієнти гратимуть через нього.")
			                  : tr("✅ Спільний акаунт «%1» передано на сервер. Клієнти гратимуть через нього.").arg(name))
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
			? tr("🗑 Спільний акаунт прибрано з сервера. Клієнти не зможуть грати, доки не передаси новий (кроки 1–3).")
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
			? tr("⛔ Гру клієнта завершено. Йому прийшло повідомлення в боті.")
			: tr("Не вдалося завершити гру (помилка %1).").arg(status));
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
				? tr("🔒 Доступ закрито: клієнти не можуть грати, бот показує «технічні роботи».")
				: tr("🔓 Доступ відкрито: клієнти знову грають у свій час."));
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
		emit extendChanged();
	});
}

void AnyPlayCloud::extend(int hours, const QString &method)
{
	QJsonObject body;
	body["hours"] = hours;
	if(!method.isEmpty())
		body["method"] = method;
	request("POST", "/api/app/extend", body, [this, hours](int status, const QJsonObject &o) {
		if(status == 200 && o.value("ok").toBool())
		{
			QJsonObject p = o.value("pending").toObject();
			qint64 hold = p.value("holdUntil").toVariant().toLongLong() - (QDateTime::currentSecsSinceEpoch() + skew_);
			emit extendResult(true, tr("Час %1–%2 закріплено за тобою на %3 хв. Оплати за реквізитами нижче й натисни «✅ Я оплатив» — гра продовжиться сама, без перезапуску.")
				.arg(formatTime(p.value("start").toVariant().toLongLong())).arg(formatTime(p.value("end").toVariant().toLongLong()))
				.arg(qMax<qint64>(1, hold / 60)));
		}
		else
		{
			QString e = o.value("error").toString();
			emit extendResult(false, e == "busy" ? tr("На жаль, наступні %1 год уже хтось забронював. Спробуй менше годин.").arg(hours)
				: e == "no_session" ? tr("Продовжити можна лише під час своєї гри.")
				: e == "pending" ? tr("Твою оплату продовження вже перевіряють — зачекай трохи.")
				: tr("Не вдалося продовжити (помилка %1). Спробуй ще раз за хвилину.").arg(status));
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
				emit extendResult(true, tr("✅ Оплату вже отримано!"));
			else if(o.value("auto").toBool())
				emit extendResult(true, tr("⏳ Шукаємо твій платіж у виписці — зазвичай до хвилини. Можна повертатися до гри."));
			else
				emit extendResult(true, tr("⏳ Адміністратор перевіряє оплату — зазвичай кілька хвилин. Гра не перерветься, якщо оплата прийде до кінця часу."));
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

void AnyPlayCloud::book(qint64 start, const QString &code, const QString &method)
{
	QJsonObject body;
	body["start"] = start;
	body["code"] = code;
	body["method"] = method;
	setBusy(true);
	request("POST", "/api/app/book", body, [this](int status, const QJsonObject &o) {
		setBusy(false);
		if(status == 200 && o.value("ok").toBool())
		{
			QJsonObject p = o.value("pending").toObject();
			qint64 hold = p.value("holdUntil").toVariant().toLongLong() - (QDateTime::currentSecsSinceEpoch() + skew_);
			emit bookResult(true, tr("Час закріплено за тобою на %1 хв. Оплати й натисни «✅ Я оплатив».").arg(qMax<qint64>(1, hold / 60)));
		}
		else
		{
			const QString e = o.value("error").toString();
			emit bookResult(false, e == "busy" ? tr("Цей час щойно зайняли — обери інший.")
				: e == "limit" ? tr("У тебе вже максимум активних броней (%1). Оплати або скасуй одну з них.").arg(o.value("limit").toInt())
				: e == "closed" ? tr("Зараз технічні роботи — бронювання тимчасово недоступне.")
				: tr("Не вдалося забронювати (помилка %1). Спробуй ще раз.").arg(status));
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
		if(text.isEmpty())
			text = ok ? tr("Бронь скасовано, час звільнено.")
			          : tr("Цю бронь уже не можна скасувати: до початку лишилось надто мало часу.");
		emit bookResult(ok, text);
		if(o.value("refund").toString() == QLatin1String("bot"))
			openBot();   // оплачена бронь: бот питає, куди повернути кошти
		loadBook();
		loadExtend();
		refresh();
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
				emit bookResult(true, tr("✅ Оплату вже отримано — бронь підтверджено!"));
			else if(o.value("auto").toBool())
				emit bookResult(true, tr("⏳ Шукаємо твій платіж — зазвичай до хвилини. Бронь підтвердиться сама."));
			else
				emit bookResult(true, tr("⏳ Адміністратор перевіряє оплату — зазвичай кілька хвилин. Час уже закріплено за тобою."));
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
			emit message(tr("✅ Вхід у PSN виконано. Тепер адміністратор додасть твій профіль на приставку — це кілька хвилин."));
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
			emit linkResult(true, tr("✅ Готово! Клієнт тепер грає на своєму акаунті — і наступного разу теж. Йому прийшло повідомлення."));
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
