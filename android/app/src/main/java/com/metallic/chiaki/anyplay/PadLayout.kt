// AnyPlay: розташування екранних кнопок. Окремо для горизонтального й вертикального екрана, у налаштуваннях телефона.
// Положення кнопки — частка області кнопок (0..1 по ширині й висоті), розмір — множник до типового.
package com.metallic.chiaki.anyplay

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

/** Одна кнопка чи група (хрестовина, ✕○□△, стік) на екрані */
class PadElement(
	val id: String,
	var x: Float,
	var y: Float,
	var scale: Float = 1f,
	var on: Boolean = true,
	/** лише для додаткових кнопок: підпис і кнопка геймпада (PadLayout.BUTTONS) */
	var label: String = "",
	var button: String = "")
{
	val extra get() = id.startsWith("x_")

	fun copy() = PadElement(id, x, y, scale, on, label, button)

	fun json(): JSONObject = JSONObject().put("id", id).put("x", x.toDouble()).put("y", y.toDouble())
		.put("s", scale.toDouble()).put("on", on).put("label", label).put("btn", button)
}

class PadProfile(val elements: MutableList<PadElement>, var scale: Float)
{
	fun find(id: String) = elements.firstOrNull { it.id == id }
	fun copy() = PadProfile(elements.map { it.copy() }.toMutableList(), scale)
}

/** Додаткова кнопка з готового списку (для GTA V і GTA VI на PS5) */
class PadPreset(val id: String, val title: String, val label: String, val button: String)

object PadLayout
{
	private const val PREFS = "anyplay_pad"
	private const val KEY_OPACITY = "opacity"
	private const val KEY_AUTOHIDE = "autohide"
	private const val VERSION = 1

	const val MIN_SCALE = 0.5f
	const val MAX_SCALE = 2.2f

	/** Стандартні кнопки DualSense (меню «⋯» завжди є, його можна лише пересунути) */
	val STANDARD = listOf("l2", "l1", "r2", "r1", "touchpad", "dpad", "face", "lstick", "rstick", "create", "ps", "options", "menu")

	val TITLES = mapOf(
		"l2" to "L2", "l1" to "L1", "r2" to "R2", "r1" to "R1", "touchpad" to "Тачпад", "dpad" to "Хрестовина (стрілки)",
		"face" to "Кнопки ✕ ○ □ △", "lstick" to "Лівий стік", "rstick" to "Правий стік", "create" to "Create",
		"ps" to "PS", "options" to "Options", "menu" to "Меню AnyPlay ⋯")

	/** Кнопки геймпада, на які можна повісити додаткову кнопку: код і назва */
	val BUTTONS = listOf(
		"CROSS" to "✕ (хрестик)", "MOON" to "○ (коло)", "BOX" to "□ (квадрат)", "PYRAMID" to "△ (трикутник)",
		"L1" to "L1", "R1" to "R1", "L2" to "L2", "R2" to "R2",
		"L3" to "L3 (натиснути лівий стік)", "R3" to "R3 (натиснути правий стік)",
		"UP" to "Стрілка вгору", "DOWN" to "Стрілка вниз", "LEFT" to "Стрілка вліво", "RIGHT" to "Стрілка вправо",
		"CREATE" to "Create", "OPTIONS" to "Options", "PS" to "PS", "TOUCHPAD" to "Тачпад (натиснути)")

	/** Короткий знак кнопки під підписом додаткової кнопки */
	fun buttonMark(code: String): String = when(code)
	{
		"CROSS" -> "✕"; "MOON" -> "○"; "BOX" -> "□"; "PYRAMID" -> "△"
		"UP" -> "↑"; "DOWN" -> "↓"; "LEFT" -> "←"; "RIGHT" -> "→"
		"CREATE" -> "Create"; "OPTIONS" -> "Options"; "TOUCHPAD" -> "Тачпад"
		else -> code
	}

	// 125: готові кнопки під гру — ті самі дії, що в розкладках комп'ютера (gui/res/anyplay-controls-gta6.json і
	// anyplay-controls.json для GTA V). Кнопку кожної можна змінити, свої додаються окремо.
	val GAMES = listOf("gta6" to "GTA VI", "gta5" to "GTA V", "other" to "Інша гра")

	private val GTA6 = listOf(
		PadPreset("g6_shoot", "Постріл (R2)", "Постріл", "R2"),
		PadPreset("g6_aim", "Приціл (L2)", "Приціл", "L2"),
		PadPreset("g6_cover", "Укриття (R1)", "Укриття", "R1"),
		PadPreset("g6_car", "Взаємодія, сісти в авто (△)", "Авто", "PYRAMID"),
		PadPreset("g6_jump", "Стрибок, лізти (✕)", "Стрибок", "CROSS"),
		PadPreset("g6_crouch", "Присісти (○)", "Присісти", "MOON"),
		PadPreset("g6_melee", "Ближній бій (□)", "Бій", "BOX"),
		PadPreset("g6_sprint", "Біг (L3)", "Біг", "L3"),
		PadPreset("g6_weapons", "Колесо зброї (L1)", "Зброя", "L1"),
		PadPreset("g6_phone", "Телефон (стрілка вгору)", "Телефон", "UP"),
		PadPreset("g6_handbrake", "Ручне гальмо в авто (✕)", "Ручник", "CROSS"),
		PadPreset("g6_horn", "Сигнал, нітро (L3)", "Сигнал", "L3"))

	// GTA V на PS5: постріл R2, приціл L2, перезарядка ○, сісти в машину △, стрибок □, біг ✕, укриття R1, колесо зброї L1,
	// телефон стрілкою вгору; в авто ручне гальмо R1, сигнал L3, фари стрілкою вправо. id ті самі, що до 125 (збережені кнопки лишаються)
	private val GTA5 = listOf(
		PadPreset("shoot", "Постріл (R2)", "Постріл", "R2"),
		PadPreset("aim", "Приціл (L2)", "Приціл", "L2"),
		PadPreset("reload", "Перезарядка (○)", "Перезаряд", "MOON"),
		PadPreset("car", "Сісти в машину (△)", "Машина", "PYRAMID"),
		PadPreset("jump", "Стрибок (□)", "Стрибок", "BOX"),
		PadPreset("sprint", "Біг (✕)", "Біг", "CROSS"),
		PadPreset("cover", "Укриття (R1)", "Укриття", "R1"),
		PadPreset("weapons", "Колесо зброї (L1)", "Зброя", "L1"),
		PadPreset("phone", "Телефон (стрілка вгору)", "Телефон", "UP"),
		PadPreset("handbrake", "Ручне гальмо в авто (R1)", "Ручник", "R1"),
		PadPreset("horn", "Клаксон (L3)", "Сигнал", "L3"),
		PadPreset("lights", "Фари (стрілка вправо)", "Фари", "RIGHT"))

	/** Що робить кнопка в грі (як підказки на екрані керування комп'ютера); ключ — частина малюнка PadMapView */
	fun action(game: String, part: String): String = (when(game)
	{
		"gta6" -> mapOf("L2" to "Приціл. В авто: гальмо, задній хід", "R2" to "Постріл. В авто: газ", "R1" to "Укриття. В авто: стріляти з авто",
			"L1" to "Колесо зброї. В авто: зброя", "PYRAMID" to "Взаємодія, сісти в авто. В авто: вийти", "MOON" to "Присісти. В авто: фари",
			"CROSS" to "Стрибок, лізти. В авто: ручне гальмо", "BOX" to "Ближній бій. В авто: удар", "L3" to "Біг. В авто: сигнал, нітро",
			"R3" to "Глянути назад", "DPAD_UP" to "Телефон", "DPAD_LEFT" to "Радіо. В авто: поворотник", "DPAD_DOWN" to "Ціль, навігація",
			"DPAD_RIGHT" to "Підірвати, напарник. В авто: поворотник")
		"gta5" -> mapOf("L2" to "Приціл. В авто: гальмо, задній хід", "R2" to "Постріл. В авто: газ", "R1" to "Укриття. В авто: ручне гальмо",
			"L1" to "Колесо зброї. В авто: приціл з авто", "PYRAMID" to "Сісти в транспорт. В авто: вийти", "MOON" to "Перезарядка. В авто: кінокамера",
			"CROSS" to "Біг. В авто: пригнутися", "BOX" to "Стрибок. В авто: зброя транспорту", "L3" to "Присісти. В авто: клаксон",
			"R3" to "Глянути назад", "DPAD_UP" to "Телефон", "DPAD_LEFT" to "Радіо", "DPAD_DOWN" to "Колесо персонажів",
			"DPAD_RIGHT" to "Взаємодія. В авто: фари", "SHARE" to "Змінити камеру")
		else -> emptyMap()
	}[part]) ?: when(part) { "TOUCHPAD" -> "Мапа"; "OPTIONS" -> "Пауза, меню гри"; "PS" -> "Меню приставки"; "SHARE" -> "Знімок екрана"; else -> "" }

	/** Готові кнопки для гри */
	fun presets(game: String): List<PadPreset> = when(game) { "gta6" -> GTA6; "gta5" -> GTA5; else -> emptyList() }
	/** Усі готові (щоб відрізнити їх від своїх кнопок гравця) */
	val PRESETS = GTA6 + GTA5

	private const val KEY_GAME = "game"
	fun game(context: Context) = prefs(context).getString(KEY_GAME, "gta6")?.takeIf { g -> GAMES.any { it.first == g } } ?: "gta6"
	fun setGame(context: Context, g: String) = prefs(context).edit().putString(KEY_GAME, g).apply()

	private fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

	/** Прозорість кнопок: 0.2 — ледь видно, 1 — найчіткіше */
	fun opacity(context: Context) = prefs(context).getFloat(KEY_OPACITY, 0.7f).coerceIn(0.2f, 1f)
	fun setOpacity(context: Context, v: Float) = prefs(context).edit().putFloat(KEY_OPACITY, v.coerceIn(0.2f, 1f)).apply()

	/** Через скільки секунд без дотиків ховати кнопки (горизонтально), 0 — не ховати, -1 — одразу, щойно відпустив екран */
	val AUTOHIDE_STEPS = intArrayOf(-1, 5, 10, 20, 0)
	const val AUTOHIDE_INSTANT = -1
	const val INSTANT_HIDE_MS = 1000L   // 125: через секунду після того, як прибрав пальці (було 0,35 с)
	fun autoHide(context: Context) = prefs(context).getInt(KEY_AUTOHIDE, AUTOHIDE_INSTANT)
	fun setAutoHide(context: Context, sec: Int) = prefs(context).edit().putInt(KEY_AUTOHIDE, sec).apply()

	private fun key(landscape: Boolean) = if(landscape) "land" else "port"

	/** Типове розташування: кнопки менші, ніж були в збірках до 114, по краях, щоб не закривати середину картинки */
	fun defaults(landscape: Boolean): PadProfile
	{
		fun e(id: String, x: Float, y: Float) = PadElement(id, x, y)
		val list = if(landscape) mutableListOf(
			e("l2", 0.075f, 0.09f), e("l1", 0.075f, 0.205f), e("r2", 0.925f, 0.09f), e("r1", 0.925f, 0.205f),
			e("touchpad", 0.5f, 0.075f),
			e("dpad", 0.11f, 0.52f), e("face", 0.89f, 0.52f),
			e("lstick", 0.29f, 0.77f), e("rstick", 0.71f, 0.77f),
			e("create", 0.41f, 0.92f), e("ps", 0.5f, 0.92f), e("options", 0.59f, 0.92f), e("menu", 0.965f, 0.92f))
		else mutableListOf(
			e("l2", 0.13f, 0.07f), e("l1", 0.13f, 0.17f), e("r2", 0.87f, 0.07f), e("r1", 0.87f, 0.17f),
			e("touchpad", 0.5f, 0.08f),
			e("dpad", 0.22f, 0.42f), e("face", 0.78f, 0.42f),
			e("lstick", 0.28f, 0.72f), e("rstick", 0.72f, 0.72f),
			e("create", 0.37f, 0.91f), e("ps", 0.5f, 0.91f), e("options", 0.63f, 0.91f), e("menu", 0.08f, 0.91f))
		return PadProfile(list, 1f)
	}

	fun load(context: Context, landscape: Boolean): PadProfile
	{
		val def = defaults(landscape)
		val text = prefs(context).getString(key(landscape), null) ?: return def
		return try
		{
			val o = JSONObject(text)
			val arr = o.getJSONArray("el")
			val list = mutableListOf<PadElement>()
			for(i in 0 until arr.length())
			{
				val j = arr.getJSONObject(i)
				val id = j.optString("id")
				if(id.isEmpty() || list.any { it.id == id })
					continue
				if(!id.startsWith("x_") && id !in STANDARD)
					continue
				val btn = j.optString("btn")
				if(id.startsWith("x_") && BUTTONS.none { it.first == btn })
					continue
				list.add(PadElement(id,
					j.optDouble("x", 0.5).toFloat().coerceIn(0f, 1f),
					j.optDouble("y", 0.5).toFloat().coerceIn(0f, 1f),
					j.optDouble("s", 1.0).toFloat().coerceIn(MIN_SCALE, MAX_SCALE),
					j.optBoolean("on", true) || id == "menu",
					j.optString("label").take(14), btn))
			}
			// стандартні кнопки, яких немає в збереженому (нова версія програми додала), — на типові місця
			for(d in def.elements)
				if(list.none { it.id == d.id })
					list.add(d)
			PadProfile(list, o.optDouble("scale", 1.0).toFloat().coerceIn(MIN_SCALE, MAX_SCALE))
		}
		catch(e: Exception) { def }
	}

	fun save(context: Context, landscape: Boolean, p: PadProfile)
	{
		val arr = JSONArray()
		p.elements.forEach { arr.put(it.json()) }
		val o = JSONObject().put("v", VERSION).put("scale", p.scale.toDouble()).put("el", arr)
		prefs(context).edit().putString(key(landscape), o.toString()).apply()
	}

	fun reset(context: Context, landscape: Boolean) = prefs(context).edit().remove(key(landscape)).apply()

	/** Новий id для додаткової кнопки: x_<готова> або x_<n> для своєї */
	fun extraId(p: PadProfile, preset: String?): String
	{
		if(preset != null)
			return "x_$preset"
		var n = 1
		while(p.find("x_c$n") != null)
			n++
		return "x_c$n"
	}
}
