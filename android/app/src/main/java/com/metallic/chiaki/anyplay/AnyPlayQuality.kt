// AnyPlay: якість картинки — три рівні та «Авто», яке саме знижує рівень, коли інтернет не тягне.
package com.metallic.chiaki.anyplay

import android.content.Context
import com.metallic.chiaki.common.Preferences
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
		if(sp.getBoolean(KEY_UP, false) && lvl < levels.size - 1 && now > sp.getLong(KEY_NO_UP_UNTIL, 0))
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
