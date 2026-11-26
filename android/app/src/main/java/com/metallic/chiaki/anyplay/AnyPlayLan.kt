// AnyPlay 128: гра в домашній мережі приставки — напряму, як на комп'ютері. Якщо телефон у тому самому Wi-Fi, що й PS5,
// підключаємось за її адресою в мережі ключами прив'язки з сервера (console.host), без PSN: секунди замість пів хвилини
// (через PSN телефон довго «пробиває» з'єднання через сервери Sony). Приставку шукаємо так само, як головний екран
// chiaki (DiscoveryService): спершу ~1,2 с; у режимі спокою будимо й чекаємо, поки прокинеться.
// Не знайшли (клієнт не вдома, мобільний інтернет) — звичайний шлях через PSN.
package com.metallic.chiaki.anyplay

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.SystemClock
import android.util.Base64
import com.metallic.chiaki.lib.ConnectInfo
import com.metallic.chiaki.lib.DiscoveryHost
import com.metallic.chiaki.lib.DiscoveryService
import com.metallic.chiaki.lib.DiscoveryServiceOptions
import org.json.JSONObject
import java.net.InetSocketAddress
import java.nio.charset.StandardCharsets

object AnyPlayLan
{
	private const val SEARCH_MS = 1200L
	private const val WAKE_MS = 25000L

	private fun b64(s: String): ByteArray? = try { if(s.isEmpty()) null else Base64.decode(s, Base64.DEFAULT) } catch(e: Exception) { null }

	/** Телефон у Wi-Fi чи дротовій мережі (у мобільному інтернеті домашньої приставки не буває) */
	private fun localNetwork(context: Context): Boolean = try
	{
		val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
		val caps = cm.getNetworkCapabilities(cm.activeNetwork)
		caps != null && (caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) || caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET))
	}
	catch(e: Exception) { false }

	/** Ключ прив'язки як число для команди «прокинься» (так само, як DiscoveryManager.sendWakeup) */
	private fun credential(regist: ByteArray): ULong?
	{
		val end = regist.indexOfFirst { it == 0.toByte() }.let { if(it >= 0) it else regist.size }
		return try { String(regist, 0, end, StandardCharsets.UTF_8).toULong(16) } catch(e: Exception) { null }
	}

	/**
	 * Підключення в домашній мережі або null (тоді — через PSN). Блокує потік: до ~1,2 с, якщо приставки поруч немає,
	 * і до ~25 с, якщо вона в режимі спокою і її треба розбудити (через PSN це однаково довше).
	 */
	fun target(context: Context, console: JSONObject, profile: com.metallic.chiaki.lib.ConnectVideoProfile): ConnectInfo?
	{
		val host = console.optJSONObject("host") ?: return null
		val regist = b64(host.optString("rp_regist_key")) ?: return null
		val morning = b64(host.optString("rp_key")) ?: return null
		val mac = b64(host.optString("server_mac")) ?: return null
		if(regist.size != 0x10 || morning.size != 0x10 || mac.size != 6 || !localNetwork(context))
			return null
		val id = mac.joinToString("") { "%02X".format(it) }
		val lock = Object()
		var found: DiscoveryHost? = null
		val started = SystemClock.elapsedRealtime()
		val service = try
		{
			DiscoveryService(DiscoveryServiceOptions(16U, 3U, 400U, InetSocketAddress("255.255.255.255", 987))) { hosts ->
				val h = hosts.firstOrNull { it.hostId.equals(id, ignoreCase = true) && !it.hostAddr.isNullOrEmpty() }
				if(h != null)
					synchronized(lock) { found = h; lock.notifyAll() }
			}
		}
		catch(e: Exception)
		{
			AnyPlayDiag.i("Домашня мережа: пошук приставки не запустився ($e), підключення через PSN")
			return null
		}
		try
		{
			fun waitFor(ms: Long, ok: (DiscoveryHost) -> Boolean): DiscoveryHost?
			{
				val until = SystemClock.elapsedRealtime() + ms
				synchronized(lock) {
					while(true)
					{
						found?.let { if(ok(it)) return it }
						val left = until - SystemClock.elapsedRealtime()
						if(left <= 0)
							return found
						lock.wait(left)
					}
				}
			}
			var h = waitFor(SEARCH_MS) { it.state == DiscoveryHost.State.READY }
			if(h == null)
			{
				AnyPlayDiag.i("Домашня мережа: приставки поруч немає, підключення через PSN")
				return null
			}
			if(h.state == DiscoveryHost.State.STANDBY)
			{
				val cred = credential(regist)
				if(cred == null)
					return null
				AnyPlayDiag.i("Домашня мережа: приставка ${h.hostAddr} у режимі спокою, будимо")
				DiscoveryService.wakeup(service, h.hostAddr!!, cred, true)
				h = waitFor(WAKE_MS) { it.state == DiscoveryHost.State.READY }
				if(h?.state != DiscoveryHost.State.READY)
				{
					AnyPlayDiag.i("Домашня мережа: приставка не прокинулась, підключення через PSN")
					return null
				}
			}
			AnyPlayDiag.i("Домашня мережа: приставка ${h.hostAddr} поруч, підключаємось напряму (пошук ${SystemClock.elapsedRealtime() - started} мс)")
			return ConnectInfo(ps5 = true, host = h.hostAddr!!, registKey = regist, morning = morning, videoProfile = profile)
		}
		finally
		{
			service.dispose()
		}
	}
}
