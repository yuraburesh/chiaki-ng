// AnyPlay 125: статистика під час гри, як на комп'ютері (StreamView.qml, anyplayStats): кадри за секунду,
// швидкість, пінг, втрати. 128: тонкий скляний рядок угорі; «Докладно» — той самий рядок з підписами й рештою цифр.
// Дотики крізь неї проходять у гру (кнопки під нею працюють). Місце обирає StreamActivity: там, де немає кнопок.
package com.metallic.chiaki.anyplay

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Shader
import android.view.View
import kotlin.math.max
import kotlin.math.roundToInt

class AnyPlayStatsHud(context: Context): View(context)
{
	companion object
	{
		private const val PREFS = "anyplay_hud"
		private const val KEY = "mode"
		const val OFF = 0
		const val SHORT = 1
		const val FULL = 2

		fun mode(c: Context) = c.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getInt(KEY, OFF).coerceIn(0, 2)
		fun setMode(c: Context, m: Int) = c.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putInt(KEY, m.coerceIn(0, 2)).apply()
	}

	/** Цифри за останню секунду */
	class Stats(
		val fpsShown: Double, val fpsStream: Double, val target: Int,
		val mbps: Double, val pingMs: Long, val lossPct: Double, val dropped: Long,
		val codec: String, val width: Int, val height: Int, val quality: String)

	private val d = resources.displayMetrics.density
	private fun dp(v: Float) = v * d

	var mode = OFF
		set(value) { if(field != value) { field = value; requestLayout(); invalidate() } }
	private var st: Stats? = null

	private val glass = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = 0xB8221D2E.toInt() }
	private val rim = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeWidth = dp(1f); color = 0x40FFFFFF }
	private val shine = Paint(Paint.ANTI_ALIAS_FLAG)
	private val dot = Paint(Paint.ANTI_ALIAS_FLAG)
	private val big = Paint(Paint.ANTI_ALIAS_FLAG).apply { typeface = AnyPlayStyle.bodyMedium(context); textSize = dp(11f); color = AnyPlayStyle.INK }
	private val label = Paint(Paint.ANTI_ALIAS_FLAG).apply { typeface = AnyPlayStyle.body(context); textSize = dp(10f); color = 0x8CFFFFFF.toInt() }
	private val rect = RectF()

	init
	{
		isClickable = false
		isFocusable = false
		importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
	}

	// дотики проходять у гру
	override fun onTouchEvent(event: android.view.MotionEvent?) = false

	fun update(s: Stats?)
	{
		val wasNull = st == null
		st = s
		if(wasNull != (s == null))
			requestLayout()
		else if(width > 0 && kotlin.math.abs(measureW() - width) > dp(4f))
			requestLayout()
		invalidate()
	}

	private fun num(x: Double, digits: Int) = String.format(java.util.Locale.US, "%.${digits}f", x).replace('.', ',')

	private fun fps(s: Stats) = minOf(s.fpsShown, if(s.fpsStream > 0) s.fpsStream else s.fpsShown).roundToInt()

	private fun fpsColor(s: Stats): Int
	{
		val f = fps(s)
		return if(f >= s.target * 0.9) 0xFFC9F5D8.toInt() else if(f >= s.target * 0.6) AnyPlayStyle.GOLD else AnyPlayStyle.BAD
	}

	private fun lossColor(l: Double) = if(l < 0.5) AnyPlayStyle.MUTE else if(l < 2) AnyPlayStyle.GOLD else AnyPlayStyle.BAD
	private fun pingColor(p: Long) = if(p in 1..39) AnyPlayStyle.MUTE else if(p in 40..79) AnyPlayStyle.GOLD else if(p >= 80) AnyPlayStyle.BAD else AnyPlayStyle.MUTE

	/** 128: і коротко, і докладно — один тонкий рядок угорі: [підпис або null, значення, колір значення] */
	private class Part(val label: String?, val value: String, val color: Int)

	private fun parts(s: Stats): List<Part>
	{
		val p = ArrayList<Part>()
		if(mode == FULL)
		{
			p += Part("Кадри", "${fps(s)}/${s.target}", fpsColor(s))
			p += Part("Швидкість", "${num(s.mbps, 1)} Мбіт/с", AnyPlayStyle.INK)
			p += Part("Пінг", if(s.pingMs > 0) "${s.pingMs} мс" else "…", if(s.pingMs > 0) pingColor(s.pingMs) else AnyPlayStyle.MUTE)
			p += Part("Втрати", "${num(s.lossPct, 1)}%", lossColor(s.lossPct))
			p += Part("Пропущено", "${s.dropped}", if(s.dropped > 0) AnyPlayStyle.GOLD else AnyPlayStyle.MUTE)
			p += Part(null, "${s.height}p ${s.codec}", AnyPlayStyle.MUTE)
			p += Part(null, s.quality, AnyPlayStyle.MUTE)
		}
		else
		{
			p += Part(null, "${fps(s)} FPS", fpsColor(s))
			p += Part(null, "${num(s.mbps, if(s.mbps < 10) 1 else 0)} Мбіт/с", AnyPlayStyle.INK)
			if(s.pingMs > 0) p += Part(null, "${s.pingMs} мс", pingColor(s.pingMs))
			p += Part(null, "${num(s.lossPct, 1)}%", lossColor(s.lossPct))
		}
		return p
	}

	/** Найбільша ширина (задає StreamActivity: ширина екрана без відступів) — зайве з кінця відкидаємо */
	var maxW = Int.MAX_VALUE
		set(value) { if(field != value) { field = value; requestLayout() } }

	private val padX get() = dp(9f)
	private val gap get() = dp(10f)
	private val lgap get() = dp(4f)

	private fun partW(p: Part) = (p.label?.let { label.measureText(it) + lgap } ?: 0f) + big.measureText(p.value)

	/** Що влазить у maxW */
	private fun fitted(s: Stats): List<Part>
	{
		val all = parts(s)
		var n = all.size
		while(n > 1 && widthOf(all.subList(0, n)) > maxW)
			n--
		return all.subList(0, n)
	}

	private fun widthOf(ps: List<Part>) = padX * 2 + dp(3f) + gap + ps.sumOf { partW(it).toDouble() }.toFloat() + gap * (ps.size - 1)

	private fun measureW(): Float = st?.let { widthOf(fitted(it)) } ?: 0f

	private val barH get() = dp(20f)

	override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int)
	{
		val s = st
		if(s == null || mode == OFF)
		{
			setMeasuredDimension(0, 0)
			return
		}
		setMeasuredDimension(measureW().roundToInt() + 1, barH.roundToInt())
	}

	override fun onDraw(canvas: Canvas)
	{
		val s = st ?: return
		if(mode == OFF)
			return
		rect.set(0f, 0f, width.toFloat(), height.toFloat())
		val r = height / 2f
		canvas.drawRoundRect(rect, r, r, glass)
		shine.shader = LinearGradient(0f, 0f, 0f, height * 0.6f, 0x14FFFFFF, Color.TRANSPARENT, Shader.TileMode.CLAMP)
		canvas.drawRoundRect(rect, r, r, shine)
		rect.inset(dp(0.5f), dp(0.5f))
		canvas.drawRoundRect(rect, r, r, rim)
		// риска кольору кадрів зліва, як на комп'ютері
		val cy = height / 2f
		dot.color = fpsColor(s)
		rect.set(padX, cy - dp(5f), padX + dp(3f), cy + dp(5f))
		canvas.drawRoundRect(rect, dp(1.5f), dp(1.5f), dot)
		var x = padX + dp(3f) + gap
		val base = cy - (big.descent() + big.ascent()) / 2
		for(p in fitted(s))
		{
			if(p.label != null)
			{
				canvas.drawText(p.label, x, base, label)
				x += label.measureText(p.label) + lgap
			}
			big.color = p.color
			canvas.drawText(p.value, x, base, big)
			x += big.measureText(p.value) + gap
		}
		big.color = AnyPlayStyle.INK
	}

	/** Ширина потрібна для вибору місця ще до розмітки */
	fun wantWidth(): Int = max(0f, measureW()).roundToInt()
	fun wantHeight(): Int = if(st != null) barH.roundToInt() else 0
}
