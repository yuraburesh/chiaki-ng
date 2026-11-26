// AnyPlay 129: адмінка на телефоні, як на комп'ютері. Прив'язка PS5 кодом з екрана приставки (8 цифр) — для клієнта
// зі своїм PSN або для спільного акаунта — і передача прив'язки на сервер (/api/app/console). Телефон має бути в тій самій
// мережі, що й приставка (так само, як ноутбук). Логіка — як AnyPlayCloud::startClientLink / adminUploadConsole на комп'ютері.
package com.metallic.chiaki.anyplay

import android.content.Context
import android.util.Base64
import com.metallic.chiaki.lib.ChiakiLog
import com.metallic.chiaki.lib.CreateError
import com.metallic.chiaki.lib.DiscoveryHost
import com.metallic.chiaki.lib.DiscoveryService
import com.metallic.chiaki.lib.DiscoveryServiceOptions
import com.metallic.chiaki.lib.Regist
import com.metallic.chiaki.lib.RegistEventCanceled
import com.metallic.chiaki.lib.RegistEventFailed
import com.metallic.chiaki.lib.RegistEventSuccess
import com.metallic.chiaki.lib.RegistHost
import com.metallic.chiaki.lib.RegistInfo
import com.metallic.chiaki.lib.Target
import org.json.JSONObject
import java.net.InetSocketAddress
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

object AnyPlayAdminLink
{
	private const val PREFS = "anyplay_admin_psn"

	// ── вхід у PSN спільним акаунтом (ключі лишаються на телефоні, поки адмін не передасть їх на сервер з прив'язкою) ──

	fun saveShared(context: Context, t: AnyPlayPsn.Tokens)
	{
		context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
			.putString("access", t.access).putString("refresh", t.refresh).putString("account", t.account)
			.putString("online", t.onlineId).putLong("expiry", t.expiry).apply()
	}

	/** Хто увійшов у PSN на цьому телефоні для спільного акаунта ("" — ще ніхто) */
	fun sharedOnline(context: Context): String = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString("online", "") ?: ""

	private fun sharedAccount(context: Context): String = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString("account", "") ?: ""

	// ── пошук приставки в мережі ──

	/** Адреса PS5 у мережі телефона (перша знайдена, увімкнена) або null — тоді прив'язка шукатиме широкомовно */
	private fun findPs5(): String?
	{
		val latch = CountDownLatch(1)
		var addr: String? = null
		val service = try
		{
			DiscoveryService(DiscoveryServiceOptions(16U, 3U, 400U, InetSocketAddress("255.255.255.255", 987))) { hosts ->
				hosts.firstOrNull { it.isPS5 && it.state == DiscoveryHost.State.READY && !it.hostAddr.isNullOrEmpty() }?.let {
					addr = it.hostAddr
					latch.countDown()
				}
			}
		}
		catch(e: Exception) { return null }
		try { latch.await(2500, TimeUnit.MILLISECONDS) } finally { service.dispose() }
		return addr
	}

	private fun b64(b: ByteArray) = Base64.encodeToString(b, Base64.NO_WRAP)

	/** Прив'язка у форматі, який розуміє сервер і програма на комп'ютері (RegisteredHost::ToVariantMap) */
	private fun hostJson(h: RegistHost) = JSONObject()
		.put("target", h.target.value)
		.put("ap_ssid", h.apSsid).put("ap_bssid", h.apBssid).put("ap_key", h.apKey).put("ap_name", h.apName)
		.put("server_nickname", h.serverNickname)
		.put("server_mac", b64(h.serverMac))
		.put("rp_regist_key", b64(h.rpRegistKey))
		.put("rp_key_type", h.rpKeyType.toLong())
		.put("rp_key", b64(h.rpKey))
		.put("console_pin", "")

	/** Прив'язати PS5 кодом під акаунт PSN (accountId — base64 8 байт). Блокує потік. Результат: прив'язка або текст помилки */
	private fun regist(accountB64: String, pin: String): Pair<JSONObject?, String?>
	{
		val account = try { Base64.decode(accountB64, Base64.DEFAULT) } catch(e: Exception) { ByteArray(0) }
		if(account.size != 8)
			return null to "Немає даних акаунта PSN. Увійди в PSN ще раз."
		val digits = pin.filter { it.isDigit() }
		if(digits.length != 8)
			return null to "Код має бути з 8 цифр: він на екрані PS5 (Налаштування → Система → Дистанційне відтворення → Прив'язати пристрій)."
		var lastError = ""
		for(host in listOf(findPs5(), null).distinct())
		{
			val latch = CountDownLatch(1)
			var result: RegistHost? = null
			val errors = StringBuilder()
			val log = ChiakiLog(ChiakiLog.Level.ERROR.value or ChiakiLog.Level.WARNING.value or ChiakiLog.Level.INFO.value) { level, text ->
				if(level == ChiakiLog.Level.ERROR.value) errors.append(text).append('\n')
			}
			val info = RegistInfo(Target.PS5_1, host ?: "255.255.255.255", host == null, null, account, digits.toInt())
			val r = try
			{
				Regist(info, log) { e ->
					when(e)
					{
						is RegistEventSuccess -> result = e.host
						is RegistEventFailed, is RegistEventCanceled -> {}
					}
					latch.countDown()
				}
			}
			catch(e: CreateError) { return null to "Не вдалося почати прив'язку (${e.errorCode})." }
			if(!latch.await(40, TimeUnit.SECONDS))
				r.stop()
			r.dispose()
			result?.let { return hostJson(it) to null }
			lastError = errors.toString()
			AnyPlayDiag.w("Прив'язка PS5 з телефона не вдалась (${host ?: "пошук у мережі"}): ${lastError.trim().takeLast(300)}")
			// приставка відхилила код — шукати далі немає сенсу
			if(lastError.contains("HTTP code") || lastError.contains("Application Reason"))
				break
		}
		return null to when
		{
			lastError.contains("HTTP code") || lastError.contains("Application Reason") ->
				"Приставка не прийняла код. Код діє кілька хвилин: згенеруй новий на PS5 і введи ще раз."
			else -> "Приставку не знайдено в мережі. Телефон має бути в тому самому Wi-Fi, що й PS5, а приставка увімкнена (не в режимі спокою)."
		}
	}

	/** Свій PSN клієнта: прив'язати PS5 під його акаунт і передати серверу. null — готово, інакше текст помилки */
	fun linkClient(context: Context, userId: Long, accountB64: String, pin: String): String?
	{
		if(accountB64.isEmpty())
			return "Клієнт ще не увійшов у PSN у своїй програмі: попроси його натиснути «Увійти в PSN»."
		val (host, err) = regist(accountB64, pin)
		if(host == null)
			return err
		val body = JSONObject().put("host", host).put("ownerUserId", userId).put("label", host.optString("server_nickname"))
		return save(context, body) { r ->
			if(r.json.optString("error") == "client_psn") "Клієнт ще не увійшов у PSN у своїй програмі."
			else "Приставка прийняла код, але зберегти на сервері не вдалося (помилка ${r.status}). Згенеруй новий код і спробуй ще раз."
		}
	}

	/** Спільний акаунт: прив'язати PS5 під акаунт, яким адмін увійшов на телефоні, і передати серверу разом із входом PSN */
	fun linkShared(context: Context, pin: String): String?
	{
		val p = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
		val account = sharedAccount(context)
		val refresh = p.getString("refresh", "") ?: ""
		if(account.isEmpty() || refresh.isEmpty())
			return "Спершу крок 1: увійди в PSN спільним акаунтом."
		val (host, err) = regist(account, pin)
		if(host == null)
			return err
		val remote = JSONObject().put("refresh_token", refresh).put("auth_token", p.getString("access", ""))
			.put("account_id", account).put("expiry", p.getLong("expiry", 0))
		val body = JSONObject().put("host", host).put("remote", remote).put("label", host.optString("server_nickname"))
			.put("psnName", p.getString("online", "")).put("registAccount", account)
		return save(context, body) { r ->
			if(r.json.optString("error") == "regist_mismatch") "Приставку прив'язано під іншим профілем PS5, ніж вхід у PSN. На PS5 перемкнись на потрібний профіль і згенеруй код заново."
			else "Не вдалося передати PS5 на сервер (помилка ${r.status})."
		}
	}

	/** Приставка вже видала ключ — його не можна втратити: якщо сервер недоступний, пробуємо ще кілька разів */
	private fun save(context: Context, body: JSONObject, error: (CloudResult) -> String): String?
	{
		var r = AnyPlayCloud.request(context, "POST", "/api/app/console", body)
		var attempt = 0
		while(!r.ok && (r.status == 0 || r.status >= 500) && attempt < 8)
		{
			Thread.sleep(4000)
			attempt++
			r = AnyPlayCloud.request(context, "POST", "/api/app/console", body)
		}
		return if(r.ok) null else error(r)
	}
}
