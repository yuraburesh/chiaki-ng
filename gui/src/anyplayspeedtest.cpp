// AnyPlay: необов'язкова перевірка інтернету (екран «Якість»).
#include "anyplayspeedtest.h"

#include <QNetworkReply>
#include <QNetworkRequest>
#include <QRandomGenerator>
#include <QUrl>
#include <algorithm>
#include <cstring>

static const char *DOWN_URL = "https://speed.cloudflare.com/__down?bytes=";
static const char *UP_URL = "https://speed.cloudflare.com/__up";
static const int PINGS = 6;                       // перший запит лише відкриває з'єднання, рахуємо медіану решти п'яти
static const qint64 DOWN_BYTES = 25000000;        // до 25 МБ на завантаження
static const qint64 UP_BYTES = 5000000;           // 5 МБ на віддачу
static const qint64 PHASE_MS = 8000;              // не довше 8 с на кожен етап
static const int STALL_MS = 12000;                // за стільки не прийшло нічого — вважаємо, що зв'язку немає

// частки смуги прогресу: затримка, завантаження, віддача
static const double P_PING = 0.15, P_DOWN = 0.60;

AnyPlaySpeedTest::AnyPlaySpeedTest(QObject *parent)
	: QObject(parent)
{
	limit_timer_.setSingleShot(true);
}

AnyPlaySpeedTest::~AnyPlaySpeedTest()
{
	abortReply();
}

int AnyPlaySpeedTest::recommendedLevel() const
{
	if(down_mbps_ < 0)
		return -1;
	if(down_mbps_ >= 30)
		return 2;   // «Максимальна або Ультра»
	if(down_mbps_ >= 15)
		return 1;   // «Оптимальна»
	return 0;       // «Економна»
}

void AnyPlaySpeedTest::setProgress(double p)
{
	p = std::clamp(p, 0.0, 1.0);
	if(qFuzzyCompare(p + 1, progress_ + 1))
		return;
	progress_ = p;
	emit changed();
}

void AnyPlaySpeedTest::start(bool upload)
{
	if(running_)
		return;
	abortReply();
	generation_++;
	running_ = true;
	upload_ = upload;
	progress_ = 0;
	ping_ms_ = down_mbps_ = up_mbps_ = -1;
	error_.clear();
	stage_ = QStringLiteral("ping");
	pings_.clear();
	ping_left_ = PINGS;
	emit changed();
	nextPing();
}

void AnyPlaySpeedTest::cancel()
{
	generation_++;
	abortReply();
	if(!running_)
		return;
	running_ = false;
	stage_.clear();
	progress_ = 0;
	emit changed();
}

void AnyPlaySpeedTest::abortReply()
{
	limit_timer_.stop();
	disconnect(&limit_timer_, nullptr, this, nullptr);
	if(!reply_)
		return;
	QNetworkReply *r = reply_;
	reply_ = nullptr;
	r->disconnect(this);
	r->abort();
	r->deleteLater();
}

void AnyPlaySpeedTest::fail(const QString &text)
{
	abortReply();
	running_ = false;
	stage_.clear();
	error_ = text;
	emit changed();
}

void AnyPlaySpeedTest::finish()
{
	abortReply();
	running_ = false;
	stage_ = QStringLiteral("done");
	progress_ = 1;
	emit changed();
}

// ── затримка: кілька порожніх запитів по одному з'єднанню ──
void AnyPlaySpeedTest::nextPing()
{
	if(ping_left_ <= 0)
	{
		QVector<double> v = pings_;
		if(v.size() > 1)
			v.removeFirst();   // перший включає встановлення з'єднання
		std::sort(v.begin(), v.end());
		ping_ms_ = v.isEmpty() ? -1 : v.at(v.size() / 2);
		emit changed();
		startDownload();
		return;
	}
	QNetworkRequest req(QUrl(QString::fromLatin1(DOWN_URL) + "0"));
	req.setAttribute(QNetworkRequest::CacheLoadControlAttribute, QNetworkRequest::AlwaysNetwork);
	req.setRawHeader("Cache-Control", "no-cache");
	req.setTransferTimeout(STALL_MS);
	const int gen = generation_;
	clock_.start();
	reply_ = nam.get(req);
	connect(reply_, &QNetworkReply::finished, this, [this, gen]() {
		if(gen != generation_ || !reply_)
			return;
		QNetworkReply *r = reply_;
		reply_ = nullptr;
		r->deleteLater();
		if(r->error() != QNetworkReply::NoError)
		{
			fail(tr("Не вдалося перевірити інтернет. Перевір з'єднання і спробуй ще раз."));
			return;
		}
		pings_.append(clock_.nsecsElapsed() / 1e6);
		ping_left_--;
		setProgress(P_PING * (PINGS - ping_left_) / PINGS);
		nextPing();
	});
}

// ── швидкість завантаження: до 25 МБ, не довше 8 с від першого байта ──
void AnyPlaySpeedTest::startDownload()
{
	stage_ = QStringLiteral("down");
	bytes_ = 0;
	first_byte_ms_ = -1;
	emit changed();
	QNetworkRequest req(QUrl(QString::fromLatin1(DOWN_URL) + QString::number(DOWN_BYTES)));
	req.setAttribute(QNetworkRequest::CacheLoadControlAttribute, QNetworkRequest::AlwaysNetwork);
	req.setRawHeader("Cache-Control", "no-cache");
	const int gen = generation_;
	phase_clock_.start();
	reply_ = nam.get(req);
	reply_->setReadBufferSize(1 << 20);
	connect(reply_, &QNetworkReply::readyRead, this, [this, gen]() {
		if(gen != generation_ || !reply_)
			return;
		bytes_ += reply_->readAll().size();   // дані не потрібні, лише їхня кількість
		const qint64 now = phase_clock_.elapsed();
		if(first_byte_ms_ < 0)
			first_byte_ms_ = now;
		const qint64 spent = now - first_byte_ms_;
		setProgress(P_PING + P_DOWN * std::max(double(bytes_) / DOWN_BYTES, double(spent) / PHASE_MS));
		// досить даних: 8 с минуло або вже 15 МБ за 3 с (швидкий інтернет)
		if(spent >= PHASE_MS || (spent >= 3000 && bytes_ >= 15000000))
			finishDownload();
	});
	connect(reply_, &QNetworkReply::finished, this, [this, gen]() {
		if(gen != generation_ || !reply_)
			return;
		if(reply_->error() != QNetworkReply::NoError && bytes_ < 1000000)
		{
			fail(tr("Не вдалося перевірити швидкість. Перевір з'єднання і спробуй ще раз."));
			return;
		}
		bytes_ += reply_->readAll().size();
		finishDownload();
	});
	// захист від завислого з'єднання: нічого не прийшло — помилка, щось прийшло — рахуємо те, що є
	connect(&limit_timer_, &QTimer::timeout, this, [this, gen]() {
		if(gen != generation_)
			return;
		if(bytes_ < 1000000)
			fail(tr("Інтернет зараз дуже повільний або недоступний. Спробуй ще раз пізніше."));
		else
			finishDownload();
	});
	limit_timer_.start(STALL_MS);
}

void AnyPlaySpeedTest::finishDownload()
{
	const qint64 spent = phase_clock_.elapsed() - std::max<qint64>(0, first_byte_ms_);
	const qint64 bytes = bytes_;
	abortReply();
	if(spent <= 0 || bytes <= 0)
	{
		fail(tr("Не вдалося перевірити швидкість. Спробуй ще раз."));
		return;
	}
	down_mbps_ = bytes * 8.0 / spent / 1000.0;   // біт за мілісекунду / 1000 = Мбіт/с
	setProgress(P_PING + P_DOWN);
	emit changed();
	if(upload_)
		startUpload();
	else
		finish();
}

// ── віддача: 5 МБ на сервер, не довше 8 с; помилка тут не скасовує результат завантаження ──
void AnyPlaySpeedTest::startUpload()
{
	stage_ = QStringLiteral("up");
	bytes_ = 0;
	first_byte_ms_ = -1;
	emit changed();
	QByteArray payload(UP_BYTES, Qt::Uninitialized);
	QRandomGenerator *rnd = QRandomGenerator::global();
	for(qsizetype i = 0; i + 4 <= payload.size(); i += 4)
	{
		const quint32 x = rnd->generate();
		memcpy(payload.data() + i, &x, 4);
	}
	QNetworkRequest req{QUrl(QString::fromLatin1(UP_URL))};
	req.setHeader(QNetworkRequest::ContentTypeHeader, QStringLiteral("application/octet-stream"));
	const int gen = generation_;
	phase_clock_.start();
	reply_ = nam.post(req, payload);
	connect(reply_, &QNetworkReply::uploadProgress, this, [this, gen](qint64 sent, qint64 total) {
		if(gen != generation_ || !reply_ || sent <= 0)
			return;
		bytes_ = sent;
		const qint64 spent = phase_clock_.elapsed();
		setProgress(P_PING + P_DOWN + (1 - P_PING - P_DOWN) * std::max(total > 0 ? double(sent) / total : 0.0, double(spent) / PHASE_MS));
		if(spent >= PHASE_MS)
			finishUpload();
	});
	connect(reply_, &QNetworkReply::finished, this, [this, gen]() {
		if(gen != generation_ || !reply_)
			return;
		if(reply_->error() == QNetworkReply::NoError)
			bytes_ = UP_BYTES;
		finishUpload();
	});
	connect(&limit_timer_, &QTimer::timeout, this, [this, gen]() {
		if(gen == generation_)
			finishUpload();
	});
	limit_timer_.start(STALL_MS);
}

void AnyPlaySpeedTest::finishUpload()
{
	const qint64 spent = phase_clock_.elapsed();
	const qint64 bytes = bytes_;
	abortReply();
	if(spent > 0 && bytes >= 500000)
		up_mbps_ = bytes * 8.0 / spent / 1000.0;
	finish();
}
