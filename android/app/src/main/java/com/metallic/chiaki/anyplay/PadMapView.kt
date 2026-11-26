// AnyPlay 125: малюнок DualSense для налаштування кнопок (як екран керування на комп'ютері).
// Режим «показ»: торкнувся кнопки на джойстику — вона ховається з екрана чи з'являється знову.
// Режим «вибір»: для своєї кнопки обираєш, яку кнопку геймпада вона натискатиме (кожна кнопка окремо: ✕, ↑, L3…).
package com.metallic.chiaki.anyplay

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.DashPathEffect
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.graphics.Shader
import android.view.MotionEvent
import android.view.View
import kotlin.math.hypot
import kotlin.math.min

class PadMapView(context: Context): View(context)
{
	/** Частина малюнка: id стандартної кнопки (для показу) і код кнопки геймпада (для вибору) */
	private class Part(val id: String, val code: String, val shape: Int, val x: Float, val y: Float, val w: Float, val h: Float, val label: String = "")
	{
		val r = RectF()
		var flash = 0f   // 1 → 0: спалах після дотику
	}

	private companion object
	{
		const val S_RECT = 0; const val S_CIRCLE = 1; const val S_PILL = 2; const val S_ARROW_U = 3; const val S_ARROW_D = 4
		const val S_ARROW_L = 5; const val S_ARROW_R = 6; const val S_CROSS = 7; const val S_MOON = 8; const val S_BOX = 9; const val S_PYR = 10
		const val S_STICK = 11; const val S_PS = 12
	}

	// координати в коробці 100 × 64 (корпус DualSense)
	private val parts = listOf(
		Part("l2", "L2", S_RECT, 22f, 4f, 15f, 5.4f, "L2"), Part("l1", "L1", S_RECT, 22f, 10.2f, 15f, 4.2f, "L1"),
		Part("r2", "R2", S_RECT, 78f, 4f, 15f, 5.4f, "R2"), Part("r1", "R1", S_RECT, 78f, 10.2f, 15f, 4.2f, "R1"),
		Part("touchpad", "TOUCHPAD", S_RECT, 50f, 22f, 30f, 17f, ""),
		Part("create", "CREATE", S_PILL, 32.5f, 16.5f, 2.6f, 5.4f, ""), Part("options", "OPTIONS", S_PILL, 67.5f, 16.5f, 2.6f, 5.4f, ""),
		Part("dpad", "UP", S_ARROW_U, 22f, 21.5f, 5.6f, 6f), Part("dpad", "DOWN", S_ARROW_D, 22f, 34.5f, 5.6f, 6f),
		Part("dpad", "LEFT", S_ARROW_L, 15.5f, 28f, 6f, 5.6f), Part("dpad", "RIGHT", S_ARROW_R, 28.5f, 28f, 6f, 5.6f),
		Part("face", "PYRAMID", S_PYR, 78f, 21f, 6.4f, 6.4f), Part("face", "CROSS", S_CROSS, 78f, 35f, 6.4f, 6.4f),
		Part("face", "BOX", S_BOX, 71f, 28f, 6.4f, 6.4f), Part("face", "MOON", S_MOON, 85f, 28f, 6.4f, 6.4f),
		Part("lstick", "L3", S_STICK, 36.5f, 43f, 11f, 11f, "L3"), Part("rstick", "R3", S_STICK, 63.5f, 43f, 11f, 11f, "R3"),
		Part("ps", "PS", S_PS, 50f, 40.5f, 4.6f, 4.6f, "PS"))

	/** Які стандартні кнопки показано на екрані (id → так/ні) */
	var shown: MutableMap<String, Boolean> = HashMap()
		set(value) { field = value; invalidate() }
	/** Вибір кнопки для своєї кнопки: що обрано */
	var picking = false
		set(value) { field = value; picked = null; invalidate() }
	var picked: String? = null
		private set
	/** Торкнулись стандартної кнопки (показ) */
	var onToggle: ((String) -> Unit)? = null
	/** Обрали кнопку геймпада (вибір) */
	var onPick: ((String) -> Unit)? = null

	private val d = resources.displayMetrics.density
	private val body = Paint(Paint.ANTI_ALIAS_FLAG)
	private val rim = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeWidth = d * 1.2f; color = 0x33FFFFFF }
	private val fill = Paint(Paint.ANTI_ALIAS_FLAG)
	private val edge = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeWidth = d * 1.2f }
	private val dashEdge = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeWidth = d; pathEffect = DashPathEffect(floatArrayOf(d * 3, d * 3), 0f) }
	private val glyph = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeWidth = d * 1.4f; strokeCap = Paint.Cap.ROUND; strokeJoin = Paint.Join.ROUND }
	private val text = Paint(Paint.ANTI_ALIAS_FLAG).apply { textAlign = Paint.Align.CENTER; typeface = AnyPlayStyle.displayMedium(context) }
	private val path = Path()
	private val box = RectF()
	private var k = 1f
	private var ox = 0f
	private var oy = 0f
	private val cyan = Color.rgb(143, 227, 255)
	private val gold = AnyPlayStyle.GOLD

	init { isClickable = true }

	override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int)
	{
		k = min(w / 100f, h / 64f)
		ox = (w - 100f * k) / 2
		oy = (h - 64f * k) / 2
		for(p in parts)
			p.r.set(X(p.x - p.w / 2), Y(p.y - p.h / 2), X(p.x + p.w / 2), Y(p.y + p.h / 2))
		body.shader = LinearGradient(0f, Y(0f), 0f, Y(64f), 0x2EFFFFFF, 0x0DFFFFFF, Shader.TileMode.CLAMP)
	}

	private fun X(v: Float) = ox + v * k
	private fun Y(v: Float) = oy + v * k

	private fun isOn(p: Part) = picking || shown[p.id] != false

	override fun onDraw(canvas: Canvas)
	{
		// корпус: верхня частина і дві ручки
		path.rewind()
		path.moveTo(X(14f), Y(14f))
		path.cubicTo(X(16f), Y(9f), X(26f), Y(13f), X(34f), Y(13f))
		path.lineTo(X(66f), Y(13f))
		path.cubicTo(X(74f), Y(13f), X(84f), Y(9f), X(86f), Y(14f))
		path.cubicTo(X(93f), Y(26f), X(99f), Y(48f), X(96f), Y(58f))
		path.cubicTo(X(93f), Y(66f), X(84f), Y(64f), X(80f), Y(56f))
		path.cubicTo(X(76f), Y(49f), X(70f), Y(47f), X(62f), Y(50f))
		path.lineTo(X(38f), Y(50f))
		path.cubicTo(X(30f), Y(47f), X(24f), Y(49f), X(20f), Y(56f))
		path.cubicTo(X(16f), Y(64f), X(7f), Y(66f), X(4f), Y(58f))
		path.cubicTo(X(1f), Y(48f), X(7f), Y(26f), X(14f), Y(14f))
		path.close()
		canvas.drawPath(path, body)
		canvas.drawPath(path, rim)
		for(p in parts)
			drawPart(canvas, p)
	}

	private fun drawPart(canvas: Canvas, p: Part)
	{
		val on = isOn(p)
		val sel = picking && picked == p.code
		val a = if(on) 1f else 0.38f
		val fl = p.flash
		fill.color = when
		{
			sel -> Color.argb(150, 143, 227, 255)
			on -> Color.argb((46 + 90 * fl).toInt(), 255, 255, 255)
			else -> Color.argb((10 + 60 * fl).toInt(), 255, 255, 255)
		}
		val ec = if(sel) cyan else if(fl > 0.05f) gold else Color.argb((220 * a).toInt(), 255, 255, 255)
		edge.color = ec
		dashEdge.color = Color.argb(150, 255, 255, 255)
		glyph.color = Color.argb((235 * a).toInt(), 255, 255, 255)
		text.color = glyph.color
		val r = p.r
		val stroke = if(on) edge else dashEdge
		when(p.shape)
		{
			S_RECT, S_PILL ->
			{
				val rad = if(p.shape == S_PILL) r.width() / 2 else min(r.height() * 0.42f, d * 5)
				canvas.drawRoundRect(r, rad, rad, fill)
				canvas.drawRoundRect(r, rad, rad, stroke)
				if(p.label.isNotEmpty())
				{
					text.textSize = r.height() * 0.62f
					canvas.drawText(p.label, r.centerX(), r.centerY() - (text.descent() + text.ascent()) / 2, text)
				}
			}
			S_CIRCLE, S_PS, S_STICK, S_CROSS, S_MOON, S_BOX, S_PYR ->
			{
				val rr = r.width() / 2
				canvas.drawCircle(r.centerX(), r.centerY(), rr, fill)
				canvas.drawCircle(r.centerX(), r.centerY(), rr, stroke)
				val cx = r.centerX()
				val cy = r.centerY()
				val g = rr * 0.42f
				when(p.shape)
				{
					S_CROSS -> { canvas.drawLine(cx - g, cy - g, cx + g, cy + g, glyph); canvas.drawLine(cx + g, cy - g, cx - g, cy + g, glyph) }
					S_MOON -> canvas.drawCircle(cx, cy, g * 1.05f, glyph)
					S_BOX -> canvas.drawRect(cx - g, cy - g, cx + g, cy + g, glyph)
					S_PYR -> { path.rewind(); path.moveTo(cx, cy - g * 1.1f); path.lineTo(cx + g * 1.15f, cy + g * 0.8f); path.lineTo(cx - g * 1.15f, cy + g * 0.8f); path.close(); canvas.drawPath(path, glyph) }
					S_STICK ->
					{
						canvas.drawCircle(cx, cy, rr * 0.55f, glyph)
						if(picking) { text.textSize = rr * 0.5f; canvas.drawText(p.label, cx, cy - (text.descent() + text.ascent()) / 2, text) }
					}
					S_PS -> { text.textSize = rr * 0.9f; canvas.drawText("PS", cx, cy - (text.descent() + text.ascent()) / 2, text) }
				}
			}
			S_ARROW_U, S_ARROW_D, S_ARROW_L, S_ARROW_R ->
			{
				val rad = d * 2
				canvas.drawRoundRect(r, rad, rad, fill)
				canvas.drawRoundRect(r, rad, rad, stroke)
				val cx = r.centerX()
				val cy = r.centerY()
				val g = min(r.width(), r.height()) * 0.22f
				canvas.save()
				canvas.rotate(when(p.shape) { S_ARROW_D -> 180f; S_ARROW_L -> 270f; S_ARROW_R -> 90f; else -> 0f }, cx, cy)
				canvas.drawLine(cx - g, cy + g * 0.5f, cx, cy - g * 0.6f, glyph)
				canvas.drawLine(cx + g, cy + g * 0.5f, cx, cy - g * 0.6f, glyph)
				canvas.restore()
			}
		}
	}

	private fun partAt(x: Float, y: Float): Part?
	{
		var best: Part? = null
		var bestD = Float.MAX_VALUE
		val pad = d * 6
		for(p in parts)
		{
			if(x < p.r.left - pad || x > p.r.right + pad || y < p.r.top - pad || y > p.r.bottom + pad)
				continue
			val dd = hypot(x - p.r.centerX(), y - p.r.centerY())
			if(dd < bestD) { bestD = dd; best = p }
		}
		return best
	}

	override fun onTouchEvent(e: MotionEvent): Boolean
	{
		if(e.actionMasked != MotionEvent.ACTION_UP)
			return true
		val p = partAt(e.x, e.y) ?: return true
		AnyPlayHaptics.tap(context, AnyPlayHaptics.Tap.TICK)
		// спалах: група (усі ✕○□△ або всі стрілки) — разом, бо ховаються разом
		val group = if(picking) listOf(p) else parts.filter { it.id == p.id }
		ValueAnimator.ofFloat(1f, 0f).apply {
			duration = 380
			addUpdateListener { v -> group.forEach { it.flash = v.animatedValue as Float }; invalidate() }
			start()
		}
		if(picking)
		{
			picked = p.code
			onPick?.invoke(p.code)
		}
		else
			onToggle?.invoke(p.id)
		invalidate()
		return true
	}
}
