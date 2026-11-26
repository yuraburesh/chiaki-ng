// AnyPlay 125: той самий DualSense, що й на екрані керування на комп'ютері (AnyPlayControls.qml): шари-картинки
// з gui/res/anyplay-pad (тут assets/anyplay/pad) і pad.json з їхніми місцями.
// Режим «показ»: кнопки, що є на екрані телефона, світяться блакитним; торкнувся — ховається (стає притиснутою, без світла)
// або з'являється знову. Режим «вибір»: для своєї кнопки торкаєшся кнопки геймпада, яку вона натискатиме (✕, ↑, L3…).
package com.metallic.chiaki.anyplay

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.view.MotionEvent
import android.view.View
import org.json.JSONObject
import kotlin.math.hypot
import kotlin.math.min

class PadMapView(context: Context): View(context)
{
	private class Layer(val x: Float, val y: Float, val w: Float, val h: Float, val src: String, val dark: String?)
	{
		val r = RectF(x, y, x + w, y + h)
	}

	private companion object
	{
		const val PW = 1084f
		const val PH = 733f
		const val TOP = 16f    // малюнок починається з y = -16 (курки визирають над корпусом)

		/** Стандартна кнопка екрана → частини малюнка */
		val PARTS = mapOf(
			"l2" to listOf("L2"), "l1" to listOf("L1"), "r2" to listOf("R2"), "r1" to listOf("R1"),
			"touchpad" to listOf("TOUCHPAD"), "create" to listOf("SHARE"), "options" to listOf("OPTIONS"), "ps" to listOf("PS"),
			"dpad" to listOf("DPAD_UP", "DPAD_DOWN", "DPAD_LEFT", "DPAD_RIGHT"),
			"face" to listOf("PYRAMID", "MOON", "CROSS", "BOX"),
			"lstick" to listOf("L3"), "rstick" to listOf("R3"))

		/** Частина малюнка → код кнопки для своєї кнопки (PadLayout.BUTTONS) */
		fun codeOf(name: String) = when(name)
		{
			"DPAD_UP" -> "UP"; "DPAD_DOWN" -> "DOWN"; "DPAD_LEFT" -> "LEFT"; "DPAD_RIGHT" -> "RIGHT"; "SHARE" -> "CREATE"
			else -> name
		}

		fun idOf(name: String) = PARTS.entries.firstOrNull { name in it.value }?.key ?: ""

		private var cache: Data? = null
	}

	private class Data(val floor: Layer, val base: Layer, val trig: Map<String, Layer>, val sh: Map<String, Layer>,
		val caps: Map<String, Layer>, val pressed: Map<String, Layer>, val glow: Map<String, Layer>, val bmp: HashMap<String, Bitmap?>)

	private fun load(): Data?
	{
		cache?.let { return it }
		return try
		{
			val j = JSONObject(context.assets.open("anyplay/pad/pad.json").bufferedReader().use { it.readText() })
			fun layer(o: JSONObject) = Layer(o.getDouble("x").toFloat(), o.getDouble("y").toFloat(), o.getDouble("w").toFloat(), o.getDouble("h").toFloat(),
				o.getString("src"), o.optString("dark").ifEmpty { null })
			fun group(k: String): Map<String, Layer> { val o = j.getJSONObject(k); return o.keys().asSequence().associateWith { layer(o.getJSONObject(it)) } }
			Data(layer(j.getJSONObject("floor")), layer(j.getJSONObject("base")), group("l2"), group("sh"), group("caps"), group("pressed"), group("glow"), HashMap())
				.also { cache = it }
		}
		catch(e: Exception) { null }
	}

	private fun bmp(d: Data, name: String?): Bitmap?
	{
		if(name == null) return null
		if(d.bmp.containsKey(name)) return d.bmp[name]
		val b = try { context.assets.open("anyplay/pad/$name").use { BitmapFactory.decodeStream(it) } } catch(e: Exception) { null }
		d.bmp[name] = b
		return b
	}

	/** Які стандартні кнопки показано на екрані (id → так/ні) */
	var shown: MutableMap<String, Boolean> = HashMap()
		set(value) { field = value; invalidate() }
	/** Вибір кнопки для своєї кнопки */
	var picking = false
		set(value) { field = value; picked = null; invalidate() }
	var picked: String? = null
		private set
	var onToggle: ((String) -> Unit)? = null
	var onPick: ((String) -> Unit)? = null

	private val paint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)
	private val dst = RectF()
	private var k = 1f
	private var ox = 0f
	private var oy = 0f
	private val flash = HashMap<String, Float>()

	init { isClickable = true }

	override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int)
	{
		k = min(w / PW, h / PH)
		ox = (w - PW * k) / 2
		oy = (h - PH * k) / 2 + TOP * k
	}

	private fun on(name: String) = shown[idOf(name)] != false

	private fun draw(canvas: Canvas, d: Data, l: Layer?, dark: Boolean = false, alpha: Float = 1f)
	{
		if(l == null || alpha <= 0f) return
		val b = bmp(d, if(dark) l.dark ?: l.src else l.src) ?: return
		dst.set(ox + l.x * k, oy + l.y * k, ox + (l.x + l.w) * k, oy + (l.y + l.h) * k)
		paint.alpha = (alpha.coerceIn(0f, 1f) * 255).toInt()
		canvas.drawBitmap(b, null, dst, paint)
	}

	override fun onDraw(canvas: Canvas)
	{
		val d = load() ?: return
		// як на комп'ютері: підлога, курки позаду корпусу, корпус, притиснуті кнопки, ковпачки стіків, світіння
		draw(canvas, d, d.floor)
		for(n in listOf("L2", "R2")) draw(canvas, d, d.trig[n], dark = !picking && !on(n))
		for(n in listOf("L1", "R1")) draw(canvas, d, d.sh[n], dark = !picking && !on(n))
		draw(canvas, d, d.base)
		for((n, l) in d.pressed)
			if((!picking && !on(n)) || (picking && picked == n))
				draw(canvas, d, l)
		for(n in listOf("L3", "R3")) draw(canvas, d, d.caps[n], dark = (!picking && !on(n)) || (picking && picked == n))
		for((n, l) in d.glow)
		{
			val f = flash[n] ?: 0f
			val a = if(picking) (if(picked == n) 1f else 0f) else if(on(n)) 0.85f else 0f
			draw(canvas, d, l, alpha = maxOf(a, f))
		}
	}

	private fun partAt(x: Float, y: Float): String?
	{
		val d = load() ?: return null
		val px = (x - ox) / k
		val py = (y - oy) / k
		var best: String? = null
		var bestD = Float.MAX_VALUE
		val pad = 14f
		for((n, l) in d.glow)
		{
			val r = l.r
			if(px < r.left - pad || px > r.right + pad || py < r.top - pad || py > r.bottom + pad)
				continue
			val dd = hypot(px - r.centerX(), py - r.centerY())
			if(dd < bestD) { bestD = dd; best = n }
		}
		return best
	}

	override fun onTouchEvent(e: MotionEvent): Boolean
	{
		if(e.actionMasked != MotionEvent.ACTION_UP)
			return true
		val n = partAt(e.x, e.y) ?: return true
		AnyPlayHaptics.tap(context, if(n.startsWith("L") || n.startsWith("R")) AnyPlayHaptics.Tap.CLICK else AnyPlayHaptics.Tap.TICK)
		// спалах: у показі вся група (✕○□△ чи всі стрілки ховаються разом), у виборі — одна кнопка
		val group = if(picking) listOf(n) else PARTS[idOf(n)] ?: listOf(n)
		ValueAnimator.ofFloat(1f, 0f).apply {
			duration = 420
			addUpdateListener { v -> group.forEach { flash[it] = v.animatedValue as Float }; invalidate() }
			start()
		}
		if(picking)
		{
			picked = n
			onPick?.invoke(codeOf(n))
		}
		else
			onToggle?.invoke(idOf(n))
		invalidate()
		return true
	}
}
