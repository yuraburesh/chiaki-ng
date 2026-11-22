// AnyPlay: сервер оренди PS5 — вхід через Telegram, стан броні, ключі для гри лише на час броні.
package com.metallic.chiaki.anyplay

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.util.Base64
import com.metallic.chiaki.BuildConfig
import com.metallic.chiaki.common.Preferences
import com.metallic.chiaki.lib.ChiakiPsn
import com.metallic.chiaki.lib.ConnectInfo
import com.metallic.chiaki.lib.PsnDeviceList
import com.metallic.chiaki.lib.PsnDiag
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder

class CloudResult(val status: Int, val json: JSONObject)
{
	val ok get() = status == 200 && json.optBoolean("ok", false)
}

/** Що вийшло, коли шукали приставку для гри */
sealed class PlayTarget
data class PlayReady(val connectInfo: ConnectInfo, val guest: Boolean = false): PlayTarget()
/** text — для людини; code — короткий технічний код (дрібним рядком), щоб власник міг переслати його розробникам */
data class PlayError(val text: String, val code: String = ""): PlayTarget()

object AnyPlayCloud
{
	const val SERVER = "https://34-123-25-16.sslip.io"
	const val BUILD = BuildConfig.ANYPLAY_BUILD   // з anyplay-build.txt через build.gradle
	const val BOT_URL = "https://t.me/play_any_bot"
	private const val PREFS = "anyplay"
	private const val KEY_TOKEN = "device_token"

	fun token(context: Context): String =
		context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY_TOKEN, "") ?: ""

	fun setToken(context: Context, token: String)
	{
		context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString(KEY_TOKEN, token).apply()
	}

	/** Запит до сервера. Блокує потік — викликати з Dispatchers.IO. status 0 — немає зв'язку. */
	fun request(context: Context, method: String, path: String, body: JSONObject? = null, auth: Boolean = true): CloudResult
	{
		var conn: HttpURLConnection? = null
		try
		{
			conn = URL(SERVER + path).openConnection() as HttpURLConnection
			conn.requestMethod = method
			conn.connectTimeout = 15000
			conn.readTimeout = 15000
			conn.setRequestProperty("Content-Type", "application/json")
			conn.setRequestProperty("X-AnyPlay-Build", BUILD.toString())
			conn.setRequestProperty("X-AnyPlay-Platform", "android")
			val token = token(context)
			if(auth && token.isNotEmpty())
				conn.setRequestProperty("Authorization", "Bearer $token")
			if(method != "GET")
			{
				conn.doOutput = true
				conn.outputStream.use { it.write((body ?: JSONObject()).toString().toByteArray(Charsets.UTF_8)) }
			}
			val status = conn.responseCode
			val stream = if(status in 200..299) conn.inputStream else conn.errorStream
			val text = stream?.bufferedReader(Charsets.UTF_8)?.use { it.readText() } ?: ""
			val json = try { JSONObject(text) } catch(e: Exception) { JSONObject() }
			return CloudResult(status, json)
		}
		catch(e: Exception)
		{
			return CloudResult(0, JSONObject())
		}
		finally
		{
			conn?.disconnect()
		}
	}

	fun pairStart(context: Context): CloudResult =
		request(context, "POST", "/api/app/pair", JSONObject()
			.put("name", "${Build.MANUFACTURER} ${Build.MODEL}".trim())
			.put("platform", "android")
			.put("build", BUILD), auth = false)

	fun pairPoll(context: Context, code: String): CloudResult =
		request(context, "GET", "/api/app/pair?code=" + URLEncoder.encode(code, "UTF-8"), auth = false)

	fun session(context: Context): CloudResult = request(context, "GET", "/api/app/session")

	/** stats — телеметрія гри (К1); до тіла додаємо й останню помилку підключення за добу (lastError), якщо була */
	fun heartbeat(context: Context, streaming: Boolean, stats: JSONObject? = null): CloudResult
	{
		val body = JSONObject().put("streaming", streaming)
		stats?.let { body.put("stats", it) }
		lastError(context)?.let { body.put("lastError", it) }
		return request(context, "POST", "/api/app/heartbeat", body)
	}

	// ── остання помилка підключення: для підтримки (сервер поки її лише приймає; старий сервер поле ігнорує) ──
	private const val KEY_LAST_ERROR = "last_error"
	private const val LAST_ERROR_TTL = 24 * 3600L

	/** {"code","text","at","build","platform"} останньої помилки за добу або null */
	fun lastError(context: Context): JSONObject?
	{
		val raw = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY_LAST_ERROR, null) ?: return null
		val o = try { JSONObject(raw) } catch(e: Exception) { return null }
		return if(System.currentTimeMillis() / 1000 - o.optLong("at") <= LAST_ERROR_TTL) o else null
	}

	/** Запам'ятати помилку підключення й одразу спробувати передати її серверу (у фоні; без зв'язку — з наступним heartbeat) */
	fun noteError(context: Context, error: PlayError)
	{
		val o = JSONObject()
			.put("code", error.code)
			.put("text", error.text.take(300))
			.put("at", System.currentTimeMillis() / 1000)
			.put("build", BUILD)
			.put("platform", "android")
			.put("device", "${Build.MANUFACTURER} ${Build.MODEL}".trim())
			.put("android", Build.VERSION.RELEASE)
		val app = context.applicationContext
		app.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString(KEY_LAST_ERROR, o.toString()).apply()
		if(token(app).isNotEmpty())
			Thread { request(app, "POST", "/api/app/error", o) }.apply { isDaemon = true }.start()
	}

	/** Чи є в телефона хоч якась мережа з інтернетом (Wi-Fi, мобільний) */
	fun online(context: Context): Boolean
	{
		return try
		{
			val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
			val caps = cm.getNetworkCapabilities(cm.activeNetwork ?: return false) ?: return false
			caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
		}
		catch(e: Exception) { true }   // не знаємо — не звинувачуємо інтернет
	}

	/** Панель адміна: хто грає зараз, найближчі броні, заявки на свій PSN */
	fun admin(context: Context): CloudResult = request(context, "GET", "/api/app/admin")

	fun adminAction(context: Context, body: JSONObject): CloudResult = request(context, "POST", "/api/app/admin", body)

	private var caReady = false

	/** Кореневі сертифікати для запитів до PSN з рідної бібліотеки: файл із застосунку, шлях — у SSL_CERT_FILE */
	@Synchronized
	fun ensureCa(context: Context)
	{
		if(caReady)
			return
		val file = File(context.filesDir, "cacert.pem")
		val asset = context.assets.open("cacert.pem").use { it.readBytes() }
		if(!file.exists() || file.length() != asset.size.toLong())
			file.writeBytes(asset)
		// і змінна SSL_CERT_FILE, і явний файл для кожного з'єднання curl: одна змінна в застосунку Android не працює
		// (OpenSSL ігнорує її в процесах з AT_SECURE, тобто в усіх застосунках), див. cpp/chiaki-jni.c
		ChiakiPsn.setCaBundle(file.absolutePath)
		caReady = true
	}

	/**
	 * З відповіді /api/app/session (state == "play") збирає все для підключення до PS5 через інтернет.
	 * Блокує потік (питає Sony про приставки акаунта). Помилку одразу запам'ятовує для підтримки.
	 */
	fun playTarget(context: Context, session: JSONObject): PlayTarget
	{
		val t = findTarget(context, session)
		if(t is PlayError)
			noteError(context, t)
		return t
	}

	private fun findTarget(context: Context, session: JSONObject): PlayTarget
	{
		val console = session.optJSONObject("console") ?: return PlayError("Сервер не передав приставку. Спробуй ще раз за хвилину.", "AP-NO-CONSOLE")
		val remote = console.optJSONObject("remote") ?: JSONObject()
		val token = remote.optString("auth_token")
		val account = try { Base64.decode(remote.optString("account_id"), Base64.DEFAULT) } catch(e: Exception) { ByteArray(0) }
		if(token.isEmpty() || account.size != 8)
			return PlayError("Вхід у PSN для цієї приставки ще не готовий. Напиши в підтримку через бота.", "AP-NO-PSN")
		ensureCa(context)
		val nickname = console.optJSONObject("host")?.optString("server_nickname") ?: ""
		var list = ChiakiPsn.listDevices(token)
		if(list.devices == null && list.http != 401 && list.http != 403)
			list = ChiakiPsn.listDevices(token)   // один повтор, як на комп'ютері: мережа телефона часто «прокидається» не одразу
		val devices = list.devices ?: return listError(context, list)
		val enabled = devices.filter { it.remotePlayEnabled }
		val device = enabled.firstOrNull { it.name == nickname } ?: enabled.firstOrNull()
			?: return if(devices.isEmpty())
				PlayError("Приставку не знайдено в акаунті PSN. Можливо, її відв'язали від акаунта. Напиши в підтримку через бота.", "PSN-LIST 0 PS5")
			else
				PlayError("Приставка є в акаунті PSN, але на ній вимкнено дистанційне відтворення або вона вимкнена повністю. Напиши в підтримку через бота.",
					"PSN-LIST ${devices.size} PS5, RP off")
		val info = ConnectInfo(
			ps5 = true,
			host = "",
			registKey = ByteArray(0x10),
			morning = ByteArray(0x10),
			videoProfile = Preferences(context).videoProfile,
			psnToken = token,
			psnAccountId = account,
			psnDuid = device.duid)
		return PlayReady(info, session.optBoolean("guest"))
	}

	/** Коди curl, які означають збій захищеного з'єднання (сертифікати, TLS) */
	private val CURL_TLS = setOf(35, 51, 53, 54, 58, 59, 60, 64, 66, 77, 80, 82, 83, 90, 91)

	private fun techCode(where: String, http: Int, curl: Int, extra: String = ""): String
	{
		val parts = arrayListOf(where)
		if(extra.isNotEmpty()) parts.add(extra)
		if(http > 0) parts.add("HTTP $http")
		if(curl != 0) parts.add("curl $curl")
		return parts.joinToString(" ")
	}

	/** Зрозумілий текст за технічними подробицями помилки запиту до Sony */
	fun sonyText(context: Context, http: Int, curl: Int): String = when
	{
		!online(context) -> "Немає інтернету на телефоні. Увімкни Wi-Fi або мобільний інтернет і спробуй ще раз."
		http == 401 || http == 403 -> "Sony не прийняла вхід у PSN для цієї приставки: ключ входу застарів. Спробуй ще раз за хвилину. Якщо повторюється, напиши в підтримку через бота."
		http == 429 || http >= 500 -> "Сервери Sony зараз не відповідають (збій на боці Sony). Спробуй ще раз за кілька хвилин."
		curl in CURL_TLS -> "Не вдалося встановити захищене з'єднання із серверами Sony. Перевір, що на телефоні правильні дата й час (краще автоматично), і спробуй ще раз."
		curl == 6 -> "Телефон не знаходить сервери Sony у цій мережі. Перевір інтернет або спробуй інший Wi-Fi чи мобільний інтернет."
		curl == 7 || curl == 28 || curl == 52 || curl == 55 || curl == 56 -> "Сервери Sony не відповідають через цю мережу. Спробуй ще раз або підключись до іншого Wi-Fi чи мобільного інтернету."
		else -> "Sony зараз не відповідає. Спробуй ще раз за хвилину. Якщо повторюється, напиши в підтримку через бота."
	}

	private fun listError(context: Context, list: PsnDeviceList): PlayError =
		PlayError(sonyText(context, list.http, list.curl),
			techCode("PSN-LIST", list.http, list.curl, if(online(context)) "E${list.error}" else "E${list.error} offline"))

	/**
	 * Не вдалося з'єднатися з приставкою через PSN (уже під час підключення в грі).
	 * step — на якому кроці зупинились (Session.psnStep), error — код бібліотеки.
	 */
	fun connectError(context: Context, step: Int, error: Int, diag: PsnDiag): PlayError
	{
		val code = techCode("PSN-$step", diag.http, diag.curl, "E$error" + if(online(context)) "" else " offline")
		val text = when
		{
			!online(context) -> "Немає інтернету на телефоні. Увімкни Wi-Fi або мобільний інтернет і спробуй ще раз."
			diag.http > 0 || diag.curl != 0 || step <= 2 -> sonyText(context, diag.http, diag.curl)
			step == 3 -> "Не вдалося підготувати з'єднання через твою мережу: вона не пропускає потрібні запити. Спробуй інший Wi-Fi або мобільний інтернет."
			step == 4 && (error == 8 || error == 15) -> "Приставка не відповіла. Можливо, вона вимкнена повністю (не в режимі спокою) або втратила інтернет. Спробуй ще раз за хвилину, а якщо не допоможе, напиши в підтримку через бота."
			step == 4 -> "Приставка не прийняла підключення. Спробуй ще раз за хвилину, а якщо не допоможе, напиши в підтримку через бота."
			else -> "Не вдалося пробити з'єднання з приставкою через твою мережу. Так буває з мобільним інтернетом деяких операторів і з деякими роутерами. Спробуй інший Wi-Fi або мобільний інтернет."
		}
		return PlayError(text, code).also { noteError(context, it) }
	}
}
