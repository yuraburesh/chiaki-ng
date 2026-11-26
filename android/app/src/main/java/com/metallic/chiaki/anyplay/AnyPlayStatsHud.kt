// AnyPlay 125: статистика під час гри, як на комп'ютері (StreamView.qml, anyplayStats): кадри за секунду,
// швидкість, пінг, втрати. Скляна пігулка в кольорах AnyPlay; «Докладно» — картка з усіма цифрами.
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

	private val glass = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = 0xE0221D2E.toInt() }
	private val rim = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeWidth = dp(1f); color = 0x40FFFFFF }
	private val shine = Paint(Paint.ANTI_ALIAS_FLAG)
	private val dot = Paint(Paint.ANTI_ALIAS_FLAG)
	private val big = Paint(Paint.ANTI_ALIAS_FLAG).apply { typeface = AnyPlayStyle.bodyMedium(context); textSize = dp(12f); color = AnyPlayStyle.INK }
	private val small = Paint(Paint.ANTI_ALIAS_FLAG).apply { typeface = AnyPlayStyle.body(context); textSize = dp(11.5f); color = AnyPlayStyle.MUTE }
	private val label = Paint(Paint.ANTI_ALIAS_FLAG).apply { typeface = AnyPlayStyle.displayMedium(context); textSize = dp(10.5f); color = 0x8CFFFFFF.toInt(); letterSpacing = 0.12f }
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
		else if(width > 0 && measureW() > width + dp(2f))
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

	/** Короткий рядок: [текст, колір, жирний] */
	private fun shortParts(s: Stats): List<Triple<String, Int, Boolean>> = listOfNotNull(
		Triple("${fps(s)} FPS", fpsColor(s), true),
		Triple("${num(s.mbps, if(s.mbps < 10) 1 else 0)} Мбіт/с", AnyPlayStyle.MUTE, false),
		if(s.pingMs > 0) Triple("${s.pingMs} мс", pingColor(s.pingMs), false) else null,
		Triple("${num(s.lossPct, 1)}%", lossColor(s.lossPct), false))

	private fun fullRows(s: Stats): List<Triple<String, String, Int>> = listOf(
		Triple("КАДРИ", "${fps(s)} з ${s.target} за секунду", fpsColor(s)),
		Triple("З ПРИСТАВКИ", "${s.fpsStream.roundToInt()} кадрів/с, пропущено ${s.dropped}", AnyPlayStyle.MUTE),
		Triple("ШВИДКІСТЬ", "${num(s.mbps, 1)} Мбіт/с", AnyPlayStyle.INK),
		Triple("ПІНГ", if(s.pingMs > 0) "${s.pingMs} мс до приставки" else "вимірюю…", pingColor(s.pingMs)),
		Triple("ВТРАТИ", "${num(s.lossPct, 1)}% пакетів", lossColor(s.lossPct)),
		Triple("ВІДЕО", "${s.codec} ${s.width}×${s.height}", AnyPlayStyle.MUTE),
		Triple("ЯКІСТЬ", s.quality, AnyPlayStyle.MUTE))

	private val padX get() = dp(10f)
	private val gap get() = dp(9f)

	private fun measureW(): Float
	{
		val s = st ?: return 0f
		return if(mode == FULL)
		{
			val rows = fullRows(s)
			val lw = rows.maxOf { label.measureText(it.first) }
			val vw = rows.maxOf { big.measureText(it.second) }
			padX * 2 + lw + dp(10f) + vw
		}
		else
		{
			val parts = shortParts(s)
			padX * 2 + dp(6f) + gap + parts.sumOf { (if(it.third) big else small).measureText(it.first).toDouble() }.toFloat() + gap * (parts.size - 1)
		}
	}

	override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int)
	{
		val s = st
		if(s == null || mode == OFF)
		{
			setMeasuredDimension(0, 0)
			return
		}
		val w = measureW()
		val h = if(mode == FULL) dp(10f) * 2 + fullRows(s).size * dp(17f) else dp(24f)
		setMeasuredDimension(w.roundToInt() + 1, h.roundToInt())
	}

	override fun onDraw(canvas: Canvas)
	{
		val s = st ?: return
		if(mode == OFF)
			return
		rect.set(0f, 0f, width.toFloat(), height.toFloat())
		val r = if(mode == FULL) dp(6f) else height / 2f
		canvas.drawRoundRect(rect, r, r, glass)
		shine.shader = LinearGradient(0f, 0f, 0f, height * 0.6f, 0x14FFFFFF, Color.TRANSPARENT, Shader.TileMode.CLAMP)
		canvas.drawRoundRect(rect, r, r, shine)
		rect.inset(dp(0.5f), dp(0.5f))
		canvas.drawRoundRect(rect, r, r, rim)
		if(mode == FULL)
		{
			val rows = fullRows(s)
			val lw = rows.maxOf { label.measureText(it.first) }
			var y = dp(10f) + dp(12.5f)
			for(row in rows)
			{
				canvas.drawText(row.first, padX, y, label)
				big.color = row.third
				canvas.drawText(row.second, padX + lw + dp(10f), y, big)
				y += dp(17f)
			}
			big.color = AnyPlayStyle.INK
			return
		}
		// риска кольору кадрів зліва, як на комп'ютері
		val cy = height / 2f
		dot.color = fpsColor(s)
		rect.set(padX, cy - dp(6f), padX + dp(3f), cy + dp(6f))
		canvas.drawRoundRect(rect, dp(1.5f), dp(1.5f), dot)
		var x = padX + dp(3f) + gap
		for(p in shortParts(s))
		{
			val paint = if(p.third) big else small
			paint.color = p.second
			canvas.drawText(p.first, x, cy - (paint.descent() + paint.ascent()) / 2, paint)
			x += paint.measureText(p.first) + gap
		}
		big.color = AnyPlayStyle.INK
		small.color = AnyPlayStyle.MUTE
	}

	/** Ширина потрібна для вибору місця ще до розмітки */
	fun wantWidth(): Int = max(0f, measureW()).roundToInt()
	fun wantHeight(): Int = st?.let { if(mode == FULL) (dp(20f) + fullRows(it).size * dp(17f)).roundToInt() else dp(24f).roundToInt() } ?: 0
}
