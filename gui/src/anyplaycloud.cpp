#include "anyplaycloud.h"
#include "settings.h"
#include "qmlbackend.h"

#include <QDateTime>
#include <QDesktopServices>
#include <QJsonArray>
#include <QJsonDocument>
#include <QNetworkReply>
#include <QSettings>
#include <QSysInfo>
#include <QUrl>
#include <QUrlQuery>

static const char *DEFAULT_SERVER = "https://34-123-25-16.sslip.io";
static const int POLL_MS = 60 * 1000;
static const int BEAT_MS = 20 * 1000;
static const int PAIR_MS = 2000;
static const int PAIR_MAX_TRIES = 300; // ~10 хв

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
			bool first = !settings->HasAnyPlayEphemeral();
			settings->SetAnyPlayEphemeral(console.value("host").toObject().toVariantMap(), psn);
			if(first)
				backend->refreshPsnToken(); // оновити список PS5 через PSN
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
		setState(st == "no_console" ? "no_console" : "wait");
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
				: tr("Час твоєї броні вийшов — дякуємо за гру! Продовжити можна в боті.");
			stopPlay(reason);
			refresh();
			return;
		}
		qint64 end = o.value("end").toVariant().toLongLong();
		if(end_ > 0 && end > end_)
		{
			emit message(tr("✅ Оплату отримано — гру продовжено до %1").arg(formatTime(end)));
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
	request("POST", "/api/app/console", body, [this](int status, const QJsonObject &o) {
		emit message(status == 200 && o.value("ok").toBool()
			? tr("✅ PS5 і вхід PSN передано на сервер. Клієнти гратимуть через нього.")
			: tr("Не вдалося передати PS5 на сервер (помилка %1).").arg(status));
	});
}

void AnyPlayCloud::refreshAdmin()
{
	if(!admin_ || token_.isEmpty())
		return;
	request("GET", "/api/app/admin", QJsonObject(), [this](int status, const QJsonObject &o) {
		if(status != 200 || !o.value("ok").toBool())
			return;
		admin_info_ = o.toVariantMap();
		emit adminChanged();
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

void AnyPlayCloud::extend(int hours)
{
	QJsonObject body;
	body["hours"] = hours;
	request("POST", "/api/app/extend", body, [this, hours](int status, const QJsonObject &o) {
		if(status == 200 && o.value("ok").toBool())
		{
			QJsonObject p = o.value("pending").toObject();
			qint64 hold = p.value("holdUntil").toVariant().toLongLong() - (QDateTime::currentSecsSinceEpoch() + skew_);
			emit extendResult(true, tr("Час %1–%2 закріплено за тобою на %3 хв. Реквізити і кнопку «✅ Я оплатив» ми надіслали в Telegram — оплати, і гра продовжиться сама, без перезапуску.")
				.arg(formatTime(p.value("start").toVariant().toLongLong())).arg(formatTime(p.value("end").toVariant().toLongLong()))
				.arg(qMax<qint64>(1, hold / 60)));
		}
		else
		{
			QString e = o.value("error").toString();
			emit extendResult(false, e == "busy" ? tr("На жаль, наступні %1 год уже хтось забронював. Спробуй менше годин.").arg(hours)
				: e == "no_session" ? tr("Продовжити можна лише під час своєї гри.")
				: e == "pending" ? tr("Твою оплату продовження вже перевіряють — зачекай трохи.")
				: tr("Не вдалося продовжити (помилка %1). Спробуй у боті.").arg(status));
		}
		loadExtend();
	});
}
