// AnyPlay: якість картинки — три рівні та «Авто», яке саме знижує рівень, коли інтернет не тягне.
package com.metallic.chiaki.anyplay

import android.content.Context
import android.media.MediaCodecList
import android.os.Build
import android.util.Log
import com.metallic.chiaki.common.Preferences
import com.metallic.chiaki.lib.Codec
import com.metallic.chiaki.lib.ConnectVideoProfile
import org.json.JSONArray
import org.json.JSONObject

object AnyPlayQuality
{
	class Level(val title: String, val hint: String, val resolution: Preferences.Resolution, val fps: Preferences.FPS, val bitrate: Int?)

	val levels = listOf(
		Level("Економна", "540p, 30 кадрів: для слабкого або мобільного інтернету", Preferences.Resolution.RES_540P, Preferences.FPS.FPS_30, null),
		Level("Оптимальна", "720p, 60 кадрів: підходить більшості", Preferences.Resolution.RES_720P, Preferences.FPS.FPS_60, null),
		Level("Максимальна", "1080p, 60 кадрів: потрібен швидкий Wi-Fi", Preferences.Resolution.RES_1080P, Preferences.FPS.FPS_60, 15000))

	private const val PREFS = "anyplay"
	private const val KEY_AUTO = "auto_quality"
	private const val KEY_UP = "auto_up"                 // минула гра була стабільною: наступного разу пробуємо рівень вище
	private const val KEY_RAISED_AT = "auto_raised_at"   // коли востаннє піднімали рівень
	private const val KEY_NO_UP_UNTIL = "auto_no_up_until"
	private const val DAY = 24L * 3600 * 1000

	private fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

	fun auto(context: Context) = prefs(context).getBoolean(KEY_AUTO, true)

	fun setAuto(context: Context, on: Boolean)
	{
		prefs(context).edit().putBoolean(KEY_AUTO, on).remove(KEY_UP).apply()
	}

	fun level(context: Context): Int
	{
		val p = Preferences(context)
		return when(p.resolution)
		{
			Preferences.Resolution.RES_1080P -> 2
			Preferences.Resolution.RES_720P -> 1
			else -> 0
		}
	}

	fun setLevel(context: Context, index: Int)
	{
		val q = levels[index.coerceIn(0, levels.size - 1)]
		val p = Preferences(context)
		p.resolution = q.resolution
		p.fps = q.fps
		p.bitrate = q.bitrate
	}

	fun name(context: Context): String
	{
		val title = levels[level(context)].title
		return if(auto(context)) "Авто: $title" else title
	}

	/** Перед грою: якщо минулого разу все було стабільно, пробуємо рівень вище */
	fun prepare(context: Context)
	{
		if(!auto(context))
			return
		val sp = prefs(context)
		val now = System.currentTimeMillis()
		val lvl = level(context)
		// 128: «Авто» на старих телефонах (Android 10 і старші, як Galaxy S7) не йде вище «Оптимальної»: 1080p у H.264
		// на 15 Мбіт/с їхній Wi-Fi і декодер тягнуть на межі, і за кілька хвилин картинка сиплеться. Вибрати вручну можна.
		val autoMax = if(Build.VERSION.SDK_INT < Build.VERSION_CODES.R) 1 else levels.size - 1
		if(lvl > autoMax)
		{
			setLevel(context, autoMax)
			sp.edit().remove(KEY_UP).apply()
			return
		}
		if(sp.getBoolean(KEY_UP, false) && lvl < autoMax && now > sp.getLong(KEY_NO_UP_UNTIL, 0))
		{
			setLevel(context, lvl + 1)
			sp.edit().putLong(KEY_RAISED_AT, now).apply()
		}
		else
			setLevel(context, lvl)   // вирівнюємо кадри й бітрейт під рівень
		sp.edit().remove(KEY_UP).apply()
	}

	/** Під час гри інтернет не тягне: рівень нижче. Повертає назву нового рівня або null, якщо нижче нікуди. */
	fun down(context: Context): String?
	{
		val lvl = level(context)
		if(!auto(context) || lvl <= 0)
			return null
		val sp = prefs(context)
		val now = System.currentTimeMillis()
		val e = sp.edit().remove(KEY_UP)
		if(now - sp.getLong(KEY_RAISED_AT, 0) < 20 * 60 * 1000)   // щойно підняли й одразу погано — три дні не пробуємо
			e.putLong(KEY_NO_UP_UNTIL, now + 3 * DAY)
		e.apply()
		setLevel(context, lvl - 1)
		return levels[lvl - 1].title
	}

	/** Гра довго йшла без втрат */
	fun good(context: Context)
	{
		if(auto(context))
			prefs(context).edit().putBoolean(KEY_UP, true).apply()
	}

	// ── формат відео (AnyPlay 118) ──
	// Типово H.265 (менше трафіку при тій самій якості). Але частина телефонів не має апаратного декодера H.265
	// потрібного розміру або він на потоці PS5 не показує картинку (звук є, картинки немає). Тоді — H.264:
	// апаратний декодер H.264 є на всіх телефонах.
	private const val KEY_HEVC_BROKEN = "hevc_broken_until"
	private const val HEVC_BROKEN_MS = 14 * DAY
	@Volatile private var hevcCache: String? = null   // "WxH" → результат перевірки
	@Volatile private var hevcCacheOk = false

	/** Чи є апаратний декодер H.265 для такого розміру (програмний на 60 кадрах не встигає) */
	private fun hevcHardware(width: Int, height: Int): Boolean
	{
		val key = "${width}x$height"
		if(hevcCache == key)
			return hevcCacheOk
		var ok = false
		try
		{
			for(info in MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos)
			{
				if(info.isEncoder || info.supportedTypes.none { it.equals("video/hevc", true) })
					continue
				val name = info.name.lowercase()
				val software = if(Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) info.isSoftwareOnly
					else name.startsWith("omx.google.") || name.startsWith("c2.android.")
				if(software)
					continue
				val caps = info.getCapabilitiesForType("video/hevc").videoCapabilities ?: continue
				if(caps.isSizeSupported(width, height))
				{
					ok = true
					break
				}
			}
		}
		catch(e: Exception)
		{
			ok = true   // не змогли перевірити — лишаємо як є, перевірка картинки в грі підстрахує
		}
		hevcCache = key
		hevcCacheOk = ok
		if(!ok)
			AnyPlayDiag.i("Апаратного декодера H.265 для $key немає: відео в H.264")
		return ok
	}

	/** Профіль відео для гри: якість з налаштувань, формат — H.265, якщо телефон його справді показує, інакше H.264 */
	fun videoProfile(context: Context): ConnectVideoProfile
	{
		val p = Preferences(context)
		val profile = p.videoProfile
		if(profile.codec != Codec.CODEC_H265)
			return profile
		// 155: гравець веде трансляції — гра в H.264, бо H.265 більшість браузерів глядачів не показує
		if(liveH264(context))
		{
			val h264 = ConnectVideoProfile.preset(p.resolution.preset, p.fps.preset, Codec.CODEC_H264)
			return p.bitrate?.let { h264.copy(bitrate = it) } ?: h264
		}
		val broken = System.currentTimeMillis() < prefs(context).getLong(KEY_HEVC_BROKEN, 0)
		// 118.1: Android 10 і старші (телефони до ~2019, як Galaxy S7 з журналу власника) — H.264: їхні декодери H.265
		// на потоці PS5 1080p не встигали брати кадри («Failed to get input buffer»), а H.264 вони тягнуть упевнено
		val old = Build.VERSION.SDK_INT < Build.VERSION_CODES.R
		if(!broken && !old && hevcHardware(profile.width, profile.height))
			return profile
		val h264 = ConnectVideoProfile.preset(p.resolution.preset, p.fps.preset, Codec.CODEC_H264)
		return p.bitrate?.let { h264.copy(bitrate = it) } ?: h264
	}

	private const val KEY_LIVE_H264 = "liveH264"
	fun liveH264(context: Context): Boolean = prefs(context).getBoolean(KEY_LIVE_H264, false)
	fun setLiveH264(context: Context, on: Boolean) { prefs(context).edit().putBoolean(KEY_LIVE_H264, on).apply() }

	/** У грі з H.265 картинка так і не з'явилась (декодер не створився або не показав жодного кадру): два тижні — H.264 */
	fun hevcFailed(context: Context)
	{
		prefs(context).edit().putLong(KEY_HEVC_BROKEN, System.currentTimeMillis() + HEVC_BROKEN_MS).apply()
		AnyPlayDiag.w("H.265 на цьому телефоні не показав картинку: наступні підключення в H.264")
	}

	/** Для сторінки: {auto, level, name, levels: [{title, hint}]} */
	fun json(context: Context): JSONObject
	{
		val list = JSONArray()
		for(l in levels)
			list.put(JSONObject().put("title", l.title).put("hint", l.hint))
		return JSONObject().put("auto", auto(context)).put("level", level(context)).put("name", name(context)).put("levels", list)
	}

	/** Вибір на сторінці: -1 — «Авто», 0..2 — сталий рівень. true, якщо вибір справді змінився. */
	fun select(context: Context, choice: Int): Boolean
	{
		val current = if(auto(context)) -1 else level(context)
		if(choice == current || choice < -1 || choice >= levels.size)
			return false
		if(choice < 0)
			setAuto(context, true)
		else
		{
			setAuto(context, false)
			setLevel(context, choice)
		}
		return true
	}
}
