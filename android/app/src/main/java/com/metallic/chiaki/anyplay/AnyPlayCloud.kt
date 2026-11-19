// AnyPlay: сервер оренди PS5 — вхід через Telegram, стан броні, ключі для гри лише на час броні.
package com.metallic.chiaki.anyplay

import android.content.Context
import android.os.Build
import android.util.Base64
import com.metallic.chiaki.BuildConfig
import com.metallic.chiaki.common.Preferences
import com.metallic.chiaki.lib.ChiakiPsn
import com.metallic.chiaki.lib.ConnectInfo
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
data class PlayReady(val connectInfo: ConnectInfo): PlayTarget()
data class PlayError(val text: String): PlayTarget()

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
		request(context, "POST", "/api/app/pair", JSONObject().put("name", "${Build.MANUFACTURER} ${Build.MODEL}".trim()), auth = false)

	fun pairPoll(context: Context, code: String): CloudResult =
		request(context, "GET", "/api/app/pair?code=" + URLEncoder.encode(code, "UTF-8"), auth = false)

	fun session(context: Context): CloudResult = request(context, "GET", "/api/app/session")

	fun heartbeat(context: Context, streaming: Boolean): CloudResult =
		request(context, "POST", "/api/app/heartbeat", JSONObject().put("streaming", streaming))

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
		ChiakiPsn.setEnv("SSL_CERT_FILE", file.absolutePath)
		caReady = true
	}

	/**
	 * З відповіді /api/app/session (state == "play") збирає все для підключення до PS5 через інтернет.
	 * Блокує потік (питає Sony про приставки акаунта).
	 */
	fun playTarget(context: Context, session: JSONObject): PlayTarget
	{
		val console = session.optJSONObject("console") ?: return PlayError("Сервер не передав приставку. Спробуй ще раз за хвилину.")
		val remote = console.optJSONObject("remote") ?: JSONObject()
		val token = remote.optString("auth_token")
		val account = try { Base64.decode(remote.optString("account_id"), Base64.DEFAULT) } catch(e: Exception) { ByteArray(0) }
		if(token.isEmpty() || account.size != 8)
			return PlayError("Вхід у PSN для цієї приставки ще не готовий. Напиши в підтримку через бота.")
		ensureCa(context)
		val nickname = console.optJSONObject("host")?.optString("server_nickname") ?: ""
		var devices = ChiakiPsn.listDevices(token)
		if(devices == null)
			devices = ChiakiPsn.listDevices(token)
		if(devices == null)
			return PlayError("Sony зараз не відповідає. Перевір інтернет і спробуй ще раз.")
		val enabled = devices.filter { it.remotePlayEnabled }
		val device = enabled.firstOrNull { it.name == nickname } ?: enabled.firstOrNull()
			?: return PlayError("Приставку не знайдено в цьому акаунті PSN. Можливо, вона вимкнена. Напиши в підтримку через бота.")
		val info = ConnectInfo(
			ps5 = true,
			host = "",
			registKey = ByteArray(0x10),
			morning = ByteArray(0x10),
			videoProfile = Preferences(context).videoProfile,
			psnToken = token,
			psnAccountId = account,
			psnDuid = device.duid)
		return PlayReady(info)
	}
}
