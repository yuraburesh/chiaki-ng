// AnyPlay 125: вібрація як у DualSense. Один вібромотор телефона на все:
//  • вібрація гри (rumble і тактильний відгук DualSense) з плавною силою;
//  • «текстура» екранних кнопок: тік на ✕○□△ і стрілках, клац на L1/R1, упор стіка на краю;
//  • курки L2/R2: тугіше натискання, коли гра вмикає ефект курка (опір, «постріл», вібрація), як на DualSense;
//  • аналогові курки (за бажанням): сила натиску — наскільки протягнув палець униз, з відчутними сходинками.
// Телефони без керування силою вібрації (Galaxy S7 тощо) отримують силу ритмом імпульсів: слабше — коротші поштовхи.
package com.metallic.chiaki.anyplay

import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.os.VibrationEffect
import android.os.Vibrator
import org.json.JSONObject
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt

object AnyPlayHaptics
{
	private const val PREFS = "anyplay_feel"
	/** Вібрація гри: 0 вимкнено, 1 слабка, 2 середня, 3 сильна */
	private const val KEY_RUMBLE = "rumble"
	/** Відгук кнопок: 0 вимкнено, 1 легкий, 2 сильний */
	private const val KEY_BUTTONS = "buttons"
	/** Курки L2/R2: false — одразу повністю, true — сила залежить від того, наскільки протягнув палець */
	private const val KEY_ANALOG = "analog"
	/** 130: адаптивні курки (ефекти гри на L2/R2, як на DualSense) — окрема фішка, типово вимкнена */
	private const val KEY_ADAPTIVE = "adaptive"
	@Volatile private var adaptiveOn = false

	private val RUMBLE_GAIN = floatArrayOf(0f, 0.45f, 0.75f, 1f)
	private val BUTTON_GAIN = floatArrayOf(0f, 0.6f, 1f)

	enum class Tap { UI, TICK, CLICK, HEAVY, DETENT, TRIGGER_DOWN, TRIGGER_UP, TRIGGER_FULL }

	/** Що гра зробила з курком: як на DualSense */
	enum class Trigger { NONE, RESIST, WEAPON, VIBRATE }

	// ── налаштування ──
	private fun prefs(c: Context) = c.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
	@Volatile private var cache: IntArray? = null   // [rumble, buttons, analog]

	private fun settings(c: Context): IntArray = cache ?: prefs(c).let {
		intArrayOf(it.getInt(KEY_RUMBLE, 2).coerceIn(0, 3), it.getInt(KEY_BUTTONS, 1).coerceIn(0, 2), if(it.getBoolean(KEY_ANALOG, false)) 1 else 0,
			if(it.getBoolean(KEY_ADAPTIVE, false)) 1 else 0)
	}.also { cache = it; adaptiveOn = it[3] == 1; AnyPlaySticks.load(c) }

	fun adaptiveTriggers(c: Context) = settings(c)[3] == 1

	/** Прочитати налаштування заздалегідь (ефекти курків приходять без доступу до них) */
	fun load(c: Context) { settings(c) }

	fun rumbleLevel(c: Context) = settings(c)[0]
	fun buttonsLevel(c: Context) = settings(c)[1]
	fun analogTriggers(c: Context) = settings(c)[2] == 1

	fun json(c: Context): JSONObject = AnyPlaySticks.put(JSONObject())
		.put("rumble", rumbleLevel(c))
		.put("buttons", buttonsLevel(c))
		.put("analog", analogTriggers(c))
		.put("adaptive", adaptiveTriggers(c))
		.put("amp", hasAmplitude(c))

	/** Зі сторінки налаштувань: {rumble, buttons, analog} (будь-яке з них) */
	fun set(c: Context, o: JSONObject)
	{
		val e = prefs(c).edit()
		if(o.has("rumble")) e.putInt(KEY_RUMBLE, o.optInt("rumble", 2).coerceIn(0, 3))
		if(o.has("buttons")) e.putInt(KEY_BUTTONS, o.optInt("buttons", 1).coerceIn(0, 2))
		if(o.has("analog")) e.putBoolean(KEY_ANALOG, o.optBoolean("analog", false))
		if(o.has("adaptive")) e.putBoolean(KEY_ADAPTIVE, o.optBoolean("adaptive", false))
		e.apply()
		AnyPlaySticks.set(c, o)
		cache = null
		settings(c)
		if(rumbleLevel(c) == 0)
			stopRumble()
	}

	// ── вібромотор ──
	private var vibrator: Vibrator? = null
	private var amp: Boolean? = null
	private val main = Handler(Looper.getMainLooper())

	private fun vib(c: Context): Vibrator?
	{
		vibrator?.let { return it }
		@Suppress("DEPRECATION")
		val v = c.applicationContext.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
		vibrator = if(v != null && v.hasVibrator()) v else null
		return vibrator
	}

	/** Чи вміє мотор міняти силу (інакше силу передаємо ритмом) */
	fun hasAmplitude(c: Context): Boolean = amp ?: (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && vib(c)?.hasAmplitudeControl() == true).also { amp = it }

	/**
	 * Відтворити візерунок: пари (тривалість мс, сила 0..1). Без керування силою — сила стає часткою часу,
	 * коли мотор крутиться (ШІМ): слабкий відрізок — короткий поштовх і пауза.
	 */
	private fun play(c: Context, ms: IntArray, power: FloatArray, repeat: Boolean = false)
	{
		val v = vib(c) ?: return
		try
		{
			if(Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && hasAmplitude(c))
			{
				val t = LongArray(ms.size + 1)
				val a = IntArray(ms.size + 1)
				for(i in ms.indices)
				{
					t[i + 1] = ms[i].toLong()
					a[i + 1] = if(power[i] <= 0f) 0 else (power[i].coerceIn(0f, 1f) * 255).roundToInt().coerceIn(1, 255)
				}
				v.vibrate(VibrationEffect.createWaveform(t, a, if(repeat) 1 else -1))
				return
			}
			// ШІМ: кожен відрізок — увімкнено частку часу, решта пауза; дуже короткі поштовхи мотор не відчуває
			val t = ArrayList<Long>()
			t.add(0L)
			var on = false
			fun seg(d: Long, motor: Boolean)
			{
				if(d <= 0) return
				if(motor == on) { t[t.size - 1] = t[t.size - 1] + d; return }
				t.add(d); on = motor
			}
			for(i in ms.indices)
			{
				val p = power[i].coerceIn(0f, 1f)
				val d = ms[i].toLong()
				if(p <= 0.02f) { seg(d, false); continue }
				if(p >= 0.9f || d <= 12) { seg(d, true); continue }
				// усередині відрізка — імпульси з періодом 20–30 мс
				val period = 24L
				var left = d
				while(left > 0)
				{
					val chunk = min(period, left)
					val onMs = max(5L, (chunk * p.pow(0.8f)).roundToInt().toLong()).coerceAtMost(chunk)
					seg(onMs, true)
					seg(chunk - onMs, false)
					left -= chunk
				}
			}
			// t[0] — пауза перед першим відрізком (0, якщо почали з мотора)
			val arr = t.toLongArray()
			if(Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
				v.vibrate(VibrationEffect.createWaveform(arr, if(repeat) 0 else -1))
			else
				@Suppress("DEPRECATION") v.vibrate(arr, if(repeat) 0 else -1)
		}
		catch(e: Exception) {}
	}

	/** Короткий типовий відгук системи (Android 10+), коли мотор не вміє силу: на таких телефонах він найчіткіший */
	private fun predefined(c: Context, id: Int): Boolean
	{
		if(Build.VERSION.SDK_INT < Build.VERSION_CODES.Q || hasAmplitude(c))
			return false
		val v = vib(c) ?: return false
		return try { v.vibrate(VibrationEffect.createPredefined(id)); true } catch(e: Exception) { false }
	}

	// ── курки від гри ──
	@Volatile private var effL = Trigger.NONE
	@Volatile private var effR = Trigger.NONE
	@Volatile private var strL = 0f
	@Volatile private var strR = 0f
	@Volatile private var hzL = 0
	@Volatile private var hzR = 0

	private fun parse(type: Int, b: ByteArray): Triple<Trigger, Float, Int>
	{
		fun u(i: Int) = if(i < b.size) b[i].toInt() and 0xff else 0
		// сили зон упаковані по 3 біти (опір і вібрація): беремо найбільшу
		fun zones(from: Int): Float
		{
			var bits = 0L
			for(i in 0 until 4) bits = bits or (u(from + i).toLong() shl (8 * i))
			var m = 0L
			for(z in 0 until 10) m = max(m, (bits shr (3 * z)) and 7L)
			return (m + 1) / 8f
		}
		return when(type)
		{
			0x21, 0x22 -> Triple(Trigger.RESIST, zones(2), 0)                                     // опір по зонах
			0x01, 0x11 -> Triple(Trigger.RESIST, (u(1) / 255f).coerceIn(0.3f, 1f), 0)            // простий опір
			0x25, 0x02, 0x12 -> Triple(Trigger.WEAPON, ((u(2) and 7) + 1) / 8f, 0)               // «постріл»: клацання курка
			0x26 -> Triple(Trigger.VIBRATE, zones(2), u(8))                                         // вібрація курка
			0x06 -> Triple(Trigger.VIBRATE, (u(1) / 255f).coerceIn(0.3f, 1f), u(0))
			else -> Triple(Trigger.NONE, 0f, 0)
		}
	}

	/** Гра змінила ефекти курків (з потоку сесії) */
	fun triggerEffects(typeLeft: Int, typeRight: Int, left: ByteArray, right: ByteArray)
	{
		val l = parse(typeLeft, left)
		val r = parse(typeRight, right)
		effL = l.first; strL = l.second; hzL = l.third
		effR = r.first; strR = r.second; hzR = r.third
		AnyPlayDiag.i("Курки: L2 ${l.first} ${"%.2f".format(l.second)}, R2 ${r.first} ${"%.2f".format(r.second)}")
	}

	/** Нова гра: ефекти курків з минулої гри не діють */
	fun resetTriggers()
	{
		effL = Trigger.NONE; effR = Trigger.NONE
		heldVibrate = 0
	}

	fun triggerEffect(side: Int): Trigger = if(!adaptiveOn) Trigger.NONE else if(side == 1) effL else if(side == 2) effR else Trigger.NONE

	// ── відгук кнопок ──
	private var lastTapAt = 0L
	@Volatile private var heldVibrate = 0   // курок з ефектом «вібрація» тримають: 1 — L2, 2 — R2

	/**
	 * Відгук на дотик. side: 1 — L2, 2 — R2 (для ефектів курків), 0 — інші кнопки.
	 * Після короткого відгуку вібрація гри (якщо була) продовжується сама.
	 */
	fun tap(c: Context, tap: Tap, side: Int = 0)
	{
		val g = BUTTON_GAIN[buttonsLevel(c)]
		if(g <= 0f)
			return
		val now = SystemClock.uptimeMillis()
		// дуже часті тіки (палець ковзає по хрестовині) не зливаються в одне гудіння
		if(tap == Tap.TICK && now - lastTapAt < 35)
			return
		lastTapAt = now
		val strong = buttonsLevel(c) >= 2
		val eff = triggerEffect(side)
		val s = if(side == 1) strL else if(side == 2) strR else 0f
		val dur: Int = when(tap)
		{
			Tap.UI -> { if(!predefined(c, if(strong) VibrationEffect.EFFECT_CLICK else VibrationEffect.EFFECT_TICK)) play(c, intArrayOf(10), floatArrayOf(0.5f * g)); 15 }
			Tap.TICK -> { if(!predefined(c, if(strong) VibrationEffect.EFFECT_CLICK else VibrationEffect.EFFECT_TICK)) play(c, intArrayOf(9), floatArrayOf(0.55f * g)); 15 }
			Tap.CLICK -> { if(!predefined(c, VibrationEffect.EFFECT_CLICK)) play(c, intArrayOf(14), floatArrayOf(0.8f * g)); 20 }
			Tap.HEAVY -> { if(!predefined(c, VibrationEffect.EFFECT_HEAVY_CLICK)) play(c, intArrayOf(22), floatArrayOf(1f * g)); 30 }
			Tap.DETENT -> { play(c, intArrayOf(7), floatArrayOf(0.4f * g)); 10 }
			Tap.TRIGGER_DOWN -> when(eff)
			{
				// тугий курок: спершу упор, потім натиск, що поступово слабшає
				Trigger.RESIST -> { play(c, intArrayOf(16, 26, 24), floatArrayOf((0.55f + 0.45f * s) * g, (0.4f + 0.4f * s) * g, 0.25f * g)); 70 }
				// «постріл»: легкий хід, зрив і різкий удар
				Trigger.WEAPON -> { play(c, intArrayOf(14, 16, 26), floatArrayOf(0.3f * g, 0f, (0.75f + 0.25f * s) * g)); 60 }
				Trigger.VIBRATE -> { heldVibrate = side; buzz(c, s * g, if(side == 1) hzL else hzR); 0 }
				// звичайний курок: м'якше за кнопку, з коротким ходом
				Trigger.NONE -> { play(c, intArrayOf(12, 14), floatArrayOf(0.7f * g, 0.3f * g)); 30 }
			}
			Tap.TRIGGER_UP -> {
				if(heldVibrate == side) { heldVibrate = 0; stopNow(c) }
				if(eff == Trigger.RESIST) play(c, intArrayOf(10), floatArrayOf(0.35f * g)) else if(strong) play(c, intArrayOf(6), floatArrayOf(0.3f * g))
				12
			}
			// аналоговий курок дотиснули до кінця: різкий упор, як у DualSense
			Tap.TRIGGER_FULL -> { play(c, intArrayOf(18), floatArrayOf(1f * g)); 25 }
		}
		if(dur > 0)
			resumeRumbleAfter(c, dur + 25L)
	}

	/** Курок з ефектом «вібрація»: гуде, поки тримаєш */
	private fun buzz(c: Context, power: Float, hz: Int)
	{
		val period = if(hz in 5..80) (1000 / hz).coerceIn(14, 120) else 40
		val on = max(6, (period * 0.5f).roundToInt())
		play(c, intArrayOf(on, period - on), floatArrayOf(power.coerceIn(0.35f, 1f), 0f), repeat = true)
	}

	private fun stopNow(c: Context)
	{
		try { vib(c)?.cancel() } catch(e: Exception) {}
	}

	// ── вібрація гри ──
	private var rumbleCtx: Context? = null
	private var rumbleNow = 0f          // поточна сила 0..1 (після множника налаштувань)
	private var rumbleStartedAt = 0L
	private var padRumble = 0f
	private var padRumbleAt = 0L
	private val resume = Runnable { rumbleCtx?.let { startRumble(it, rumbleNow, true) } }

	/** Нова сила вібрації від гри: left — важкий мотор, right — легкий (0..255) */
	fun rumble(c: Context, left: Int, right: Int)
	{
		rumbleCtx = c.applicationContext
		val gain = RUMBLE_GAIN[rumbleLevel(c)]
		val raw = max(left, (right * 0.8f).roundToInt()) / 255f
		// крок 1/16: дрібні коливання не перезапускають мотор
		val s = ((raw * gain) * 16).roundToInt() / 16f
		// 125: граємо геймпадом з моторчиками — віддача на геймпад, як на приставці
		if(AnyPlayGamepads.rumbleToPad())
		{
			if(rumbleNow > 0f && heldVibrate == 0) stopNow(c)
			rumbleNow = 0f
			val now0 = SystemClock.uptimeMillis()
			if(s < 0.04f) { if(padRumble > 0f) { padRumble = 0f; AnyPlayGamepads.rumble(0f, 0) }; return }
			if(s != padRumble || now0 - padRumbleAt > 1200) { padRumble = s; padRumbleAt = now0; AnyPlayGamepads.rumble(0.15f + 0.85f * s, 2000) }
			return
		}
		if(s < 0.04f)
		{
			if(rumbleNow > 0f) { rumbleNow = 0f; if(heldVibrate == 0) stopNow(c) }
			return
		}
		val now = SystemClock.uptimeMillis()
		if(s == rumbleNow && now - rumbleStartedAt < 1200)
			return
		rumbleNow = s
		startRumble(c, s, false)
	}

	private fun startRumble(c: Context, s: Float, resumed: Boolean)
	{
		if(s <= 0f || heldVibrate != 0)
			return
		rumbleStartedAt = SystemClock.uptimeMillis()
		// вікно 2 с: якщо гра замовкла і не сказала «стоп», мотор зупиниться сам (як і до 125, там було 1 с)
		val len = if(resumed) 1500 else 2000
		// слабка вібрація на телефоні майже не відчувається — піднімаємо низ шкали
		play(c, intArrayOf(len), floatArrayOf(0.18f + 0.82f * s))
	}

	private fun resumeRumbleAfter(c: Context, ms: Long)
	{
		rumbleCtx = c.applicationContext
		main.removeCallbacks(resume)
		if(rumbleNow > 0f)
			main.postDelayed(resume, ms)
	}

	fun stopRumble()
	{
		main.removeCallbacks(resume)
		rumbleNow = 0f
		padRumble = 0f
		AnyPlayGamepads.stop()
		heldVibrate = 0
		try { vibrator?.cancel() } catch(e: Exception) {}
	}

	/** Перевірка в налаштуваннях: «Спробувати» */
	fun demo(c: Context, what: String)
	{
		when(what)
		{
			// вибух удалині, ближче, поруч: сила наростає
			"rumble" -> {
				val g = RUMBLE_GAIN[rumbleLevel(c)]
				if(g <= 0f) return
				play(c, intArrayOf(220, 120, 260, 120, 420), floatArrayOf(0.25f * g, 0f, 0.6f * g, 0f, 1f * g))
			}
			"buttons" -> {
				tap(c, Tap.TICK)
				main.postDelayed({ tap(c, Tap.CLICK) }, 220)
				main.postDelayed({ tap(c, Tap.HEAVY) }, 480)
			}
			"trigger" -> {
				val g = BUTTON_GAIN[max(1, buttonsLevel(c))]
				play(c, intArrayOf(16, 26, 24, 260, 14, 16, 26), floatArrayOf(0.95f * g, 0.75f * g, 0.25f * g, 0f, 0.3f * g, 0f, 1f * g))
			}
		}
	}
}
