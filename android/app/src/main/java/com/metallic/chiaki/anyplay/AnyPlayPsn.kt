// AnyPlay: вхід у PSN на телефоні. Пароль клієнт вводить лише на сторінці Sony; програма отримує від Sony
// ключ входу й передає його серверу AnyPlay — так само, як програма на комп'ютері.
package com.metallic.chiaki.anyplay

import android.content.Context
import android.net.Uri
import android.util.Base64
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.SecureRandom
import java.util.UUID

object AnyPlayPsn
{
	private const val CLIENT_ID = "ba495a24-818c-472b-b12d-ff231c1b5745"
	private const val CLIENT_SECRET = "mvaiZkRsAsI1IBkY"
	private const val TOKEN_URL = "https://auth.api.sonyentertainmentnetwork.com/2.0/oauth/token"
	const val REDIRECT_PAGE = "https://remoteplay.dl.playstation.net/remoteplay/redirect"
	private const val SCOPE = "psn:clientapp referenceDataService:countryConfig.read pushNotification:webSocket.desktop.connect sessionManager:remotePlaySession.system.update"
	private const val LOGIN_URL = "https://auth.api.sonyentertainmentnetwork.com/2.0/oauth/authorize?service_entity=urn:service-entity:psn&response_type=code&client_id=ba495a24-818c-472b-b12d-ff231c1b5745&redirect_uri=https://remoteplay.dl.playstation.net/remoteplay/redirect&scope=psn:clientapp referenceDataService:countryConfig.read pushNotification:webSocket.desktop.connect sessionManager:remotePlaySession.system.update&request_locale=en_US&ui=pr&service_logo=ps&layout_type=popup&smcid=remoteplay&prompt=always&PlatformPrivacyWs1=minimal&"
	private const val DUID_PREFIX = "0000000700410080"

	private fun randomDuid(): String
	{
		val bytes = ByteArray(16)
		SecureRandom().nextBytes(bytes)
		return DUID_PREFIX + bytes.joinToString("") { "%02x".format(it) }
	}

	/** Сторінка входу Sony (або пряма сторінка реєстрації, після якої Sony продовжує вхід) */
	fun pageUrl(create: Boolean): String
	{
		val login = LOGIN_URL.replace(" ", "%20") + "duid=" + randomDuid() + "&"
		if(!create)
			return login
		val uri = Uri.parse(login)
		val parts = ArrayList<String>()
		for(name in uri.queryParameterNames)
		{
			if(name.isEmpty() || name == "prompt")
				continue
			parts.add(name + "=" + URLEncoder.encode(uri.getQueryParameter(name) ?: "", "UTF-8"))
		}
		parts.add("cid=" + UUID.randomUUID().toString())
		parts.add("no_captcha=true")
		return "https://web.np.playstation.com/app/id/create_account/?" + parts.joinToString("&") + "#/accountcreation/pc/personal_info"
	}

	private fun basicAuth() = "Basic " + Base64.encodeToString("$CLIENT_ID:$CLIENT_SECRET".toByteArray(), Base64.NO_WRAP)

	private fun http(method: String, url: String, body: String?): Pair<Int, JSONObject>
	{
		var conn: HttpURLConnection? = null
		try
		{
			conn = URL(url).openConnection() as HttpURLConnection
			conn.requestMethod = method
			conn.connectTimeout = 20000
			conn.readTimeout = 20000
			conn.setRequestProperty("Authorization", basicAuth())
			if(body != null)
			{
				conn.doOutput = true
				conn.setRequestProperty("Content-Type", "application/x-www-form-urlencoded")
				conn.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
			}
			val status = conn.responseCode
			val text = (if(status in 200..299) conn.inputStream else conn.errorStream)?.bufferedReader()?.use { it.readText() } ?: ""
			return Pair(status, try { JSONObject(text) } catch(e: Exception) { JSONObject() })
		}
		catch(e: Exception)
		{
			return Pair(0, JSONObject())
		}
		finally
		{
			conn?.disconnect()
		}
	}

	/**
	 * Код зі сторінки «redirect» → ключі входу Sony → сервер AnyPlay. Блокує потік.
	 * Повертає null, якщо все вдалося, або текст помилки для клієнта.
	 */
	fun finishLogin(context: Context, code: String): String?
	{
		val form = "grant_type=authorization_code&code=" + URLEncoder.encode(code, "UTF-8") +
			"&scope=" + URLEncoder.encode(SCOPE, "UTF-8").replace("+", "%20") +
			"&redirect_uri=" + URLEncoder.encode(REDIRECT_PAGE, "UTF-8") + "&"
		val (status, tokens) = http("POST", TOKEN_URL, form)
		val access = tokens.optString("access_token")
		val refresh = tokens.optString("refresh_token")
		if(status != 200 || access.isEmpty() || refresh.isEmpty())
			return if(status == 0) "Немає зв'язку з Sony. Перевір інтернет і спробуй ще раз."
				else "Sony не прийняла цей вхід (код діє лише кілька хвилин). Спробуй увійти ще раз."
		val (infoStatus, info) = http("GET", "$TOKEN_URL/$access", null)
		val userId = info.optString("user_id").toLongOrNull()
		if(infoStatus != 200 || userId == null)
			return "Sony не віддала дані акаунта. Спробуй увійти ще раз."
		val account = Base64.encodeToString(ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN).putLong(userId).array(), Base64.NO_WRAP)
		val body = JSONObject()
			.put("accountId", account)
			.put("onlineId", info.optString("online_id"))
			.put("refresh_token", refresh)
			.put("auth_token", access)
			.put("expiry", System.currentTimeMillis() / 1000 + tokens.optLong("expires_in", 3600))
		val r = AnyPlayCloud.request(context, "POST", "/api/app/psn/link", body)
		if(!r.ok)
			return if(r.status == 0) "Немає зв'язку з сервером AnyPlay. Перевір інтернет і спробуй ще раз."
				else "Не вдалося передати вхід PSN (помилка ${r.status}). Спробуй ще раз."
		return null
	}
}
