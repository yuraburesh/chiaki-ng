// AnyPlay: екранний джойстик у стилі DualSense. Малює все сам і сам розкладає кнопки:
// вертикально — під картинкою гри, горизонтально — поверх неї по краях.
package com.metallic.chiaki.anyplay

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.graphics.Typeface
import android.os.SystemClock
import android.util.AttributeSet
import android.view.MotionEvent
import android.view.View
import com.metallic.chiaki.lib.ControllerState
import com.metallic.chiaki.touchcontrols.ButtonHaptics
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min

class GamepadView @JvmOverloads constructor(context: Context, attrs: AttributeSet? = null): View(context, attrs)
{
	/** Нижній край картинки гри у вертикальному режимі (кнопки йдуть нижче) */
	var videoBottom = 0
		set(value) { if(field != value) { field = value; relayout(); invalidate() } }

	/** Безпечні відступи від країв екрана (виріз камери, заокруглення) */
	var safeLeft = 0
	var safeRight = 0
	var safeBottom = 0

	var stateChangedCallback: ((ControllerState) -> Unit)? = null
	var menuCallback: (() -> Unit)? = null

	private val haptics = ButtonHaptics(context)
	private var state = ControllerState()

	private enum class Kind { CROSS, MOON, BOX, PYRAMID, L1, R1, L2, R2, CREATE, OPTIONS, PS, MENU }
	private class Button(val kind: Kind)
	{
		val rect = RectF()
		var pressed = false
		val cx get() = rect.centerX()
		val cy get() = rect.centerY()
	}
	private val buttons = Kind.values().associateWith { Button(it) }

	private class Stick
	{
		var homeX = 0f; var homeY = 0f     // де стік намальований, поки його не чіпають
		var cx = 0f; var cy = 0f           // центр під час дотику (там, де поставили палець)
		var dx = 0f; var dy = 0f           // відхилення -1..1
		var pointer = -1
		var lastUp = 0L
		var click = false                  // L3 / R3 (подвійний дотик)
		val zone = RectF()
	}
	private val leftStick = Stick()
	private val rightStick = Stick()

	private var dpadX = 0f; private var dpadY = 0f; private var dpadR = 0f
	private var dpadPointer = -1
	private var dpadMask = 0U

	private val touchpad = RectF()
	private var touchpadPointer = -1
	private var touchpadTouchId: UByte? = null
	private var touchpadDownAt = 0L
	private var touchpadDownX = 0f; private var touchpadDownY = 0f
	private var touchpadPressed = false
	private val touchpadRelease = Runnable {
		touchpadPressed = false
		pushState()
		invalidate()
	}

	private val buttonPointers = HashMap<Int, Button>()
	private var u = 1f                    // одиниця розміру
	private var stickR = 1f
	private var landscape = false

	private val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; color = Color.argb(170, 255, 255, 255) }
	private val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL }
	private val glyph = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; color = Color.WHITE; strokeCap = Paint.Cap.ROUND; strokeJoin = Paint.Join.ROUND }
	private val text = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.WHITE; textAlign = Paint.Align.CENTER; typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD) }
	private val path = Path()
	private val tmp = RectF()

	// кольори нового дизайну AnyPlay: темно-фіолетове тло, натиснуте підсвічується блакитним (#8fe3ff), без неону
	private val idleFill get() = if(landscape) Color.argb(70, 13, 10, 22) else Color.argb(255, 43, 39, 64)
	private val pressedFill = Color.argb(150, 143, 227, 255)

	override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) = relayout()

	/** Перерахувати розкладку (змінились відступи чи положення картинки) */
	fun refreshLayout()
	{
		relayout()
		invalidate()
	}

	private fun dp(v: Float) = v * resources.displayMetrics.density

	private fun place(kind: Kind, cx: Float, cy: Float, w: Float, h: Float)
	{
		buttons[kind]!!.rect.set(cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2)
	}

	private fun relayout()
	{
		val w = width.toFloat()
		val h = height.toFloat()
		if(w <= 0 || h <= 0)
			return
		landscape = w > h
		if(landscape)
		{
			u = min(h, dp(430f)) / 100f
			val l = safeLeft + 3 * u
			val r = w - safeRight - 3 * u
			place(Kind.L2, l + 11 * u, 10.5f * u, 21 * u, 13 * u)
			place(Kind.L1, l + 27 * u, 24.5f * u, 21 * u, 13 * u)
			place(Kind.R2, r - 11 * u, 10.5f * u, 21 * u, 13 * u)
			place(Kind.R1, r - 27 * u, 24.5f * u, 21 * u, 13 * u)
			dpadX = l + 18 * u; dpadY = h * 0.52f; dpadR = 15.5f * u
			val fx = r - 18 * u; val fy = h * 0.52f; val d = 11.5f * u; val s = 10.5f * u
			place(Kind.PYRAMID, fx, fy - d, s, s)
			place(Kind.CROSS, fx, fy + d, s, s)
			place(Kind.BOX, fx - d, fy, s, s)
			place(Kind.MOON, fx + d, fy, s, s)
			val by = h - safeBottom - 7 * u
			place(Kind.CREATE, w / 2 - 13 * u, by, 9 * u, 8 * u)
			place(Kind.PS, w / 2, by, 9 * u, 9 * u)
			place(Kind.OPTIONS, w / 2 + 13 * u, by, 9 * u, 8 * u)
			place(Kind.MENU, r - 3 * u, by, 8 * u, 8 * u)
			touchpad.set(w / 2 - 15 * u, 3 * u, w / 2 + 15 * u, 14 * u)
			stickR = 9.5f * u
			leftStick.homeX = l + 50 * u; leftStick.homeY = h - safeBottom - 17 * u
			rightStick.homeX = r - 50 * u; rightStick.homeY = h - safeBottom - 17 * u
			leftStick.zone.set(0f, 34 * u, w / 2 - 22 * u, h)
			rightStick.zone.set(w / 2 + 22 * u, 34 * u, w, h)
		}
		else
		{
			val top = videoBottom.toFloat()
			val avail = h - safeBottom - top
			val full = min(w, dp(480f)) / 100f
			u = full * min(1f, avail / (122f * full))
			val content = 122f * u
			val y0 = top + max(0f, (avail - content) * 0.45f)
			val l = (w - 100f * u) / 2f * 0.35f      // на широких екранах групи тримаються ближче до країв
			val r = w - l
			place(Kind.L2, l + 14 * u, y0 + 9 * u, 22 * u, 13 * u)
			place(Kind.L1, l + 29 * u, y0 + 24 * u, 22 * u, 13 * u)
			place(Kind.R2, r - 14 * u, y0 + 9 * u, 22 * u, 13 * u)
			place(Kind.R1, r - 29 * u, y0 + 24 * u, 22 * u, 13 * u)
			touchpad.set(w / 2 - 8.5f * u, y0 + 3 * u, w / 2 + 8.5f * u, y0 + 16 * u)
			dpadX = l + 21 * u; dpadY = y0 + 52 * u; dpadR = 16.5f * u
			val fx = r - 21 * u; val fy = y0 + 52 * u; val d = 12f * u; val s = 11f * u
			place(Kind.PYRAMID, fx, fy - d, s, s)
			place(Kind.CROSS, fx, fy + d, s, s)
			place(Kind.BOX, fx - d, fy, s, s)
			place(Kind.MOON, fx + d, fy, s, s)
			stickR = 9.5f * u
			leftStick.homeX = l + 29 * u; leftStick.homeY = y0 + 84 * u
			rightStick.homeX = r - 29 * u; rightStick.homeY = y0 + 84 * u
			leftStick.zone.set(0f, y0 + 70 * u, w / 2, y0 + 101 * u)
			rightStick.zone.set(w / 2, y0 + 70 * u, w, y0 + 101 * u)
			val by = y0 + 112 * u
			place(Kind.MENU, l + 7 * u, by, 10 * u, 10 * u)
			place(Kind.CREATE, w / 2 - 22 * u, by, 10 * u, 9 * u)
			place(Kind.PS, w / 2, by, 11 * u, 11 * u)
			place(Kind.OPTIONS, w / 2 + 22 * u, by, 10 * u, 9 * u)
		}
		for(s in arrayOf(leftStick, rightStick))
			if(s.pointer < 0) { s.cx = s.homeX; s.cy = s.homeY }
		stroke.strokeWidth = max(dp(1.2f), 0.35f * u)
		glyph.strokeWidth = max(dp(1.6f), 0.55f * u)
	}

	// ── малювання ──
	override fun onDraw(canvas: Canvas)
	{
		if(!landscape)
		{
			// під картинкою — темне тло в кольорах AnyPlay
			fill.color = Color.rgb(29, 26, 43)
			canvas.drawRect(0f, videoBottom.toFloat(), width.toFloat(), height.toFloat(), fill)
		}
		drawShoulder(canvas, buttons[Kind.L2]!!, "L2")
		drawShoulder(canvas, buttons[Kind.L1]!!, "L1")
		drawShoulder(canvas, buttons[Kind.R2]!!, "R2")
		drawShoulder(canvas, buttons[Kind.R1]!!, "R1")
		drawTouchpad(canvas)
		drawDpad(canvas)
		for(k in arrayOf(Kind.PYRAMID, Kind.CROSS, Kind.BOX, Kind.MOON))
			drawFace(canvas, buttons[k]!!)
		drawStick(canvas, leftStick)
		drawStick(canvas, rightStick)
		drawSmall(canvas, buttons[Kind.CREATE]!!)
		drawSmall(canvas, buttons[Kind.OPTIONS]!!)
		drawSmall(canvas, buttons[Kind.PS]!!)
		drawSmall(canvas, buttons[Kind.MENU]!!)
	}

	private fun body(canvas: Canvas, rect: RectF, radius: Float, pressed: Boolean)
	{
		fill.color = if(pressed) pressedFill else idleFill
		canvas.drawRoundRect(rect, radius, radius, fill)
		canvas.drawRoundRect(rect, radius, radius, stroke)
	}

	private fun drawShoulder(canvas: Canvas, b: Button, label: String)
	{
		body(canvas, b.rect, b.rect.height() * 0.42f, b.pressed)
		text.textSize = b.rect.height() * 0.44f
		text.alpha = 235
		canvas.drawText(label, b.cx, b.cy - (text.descent() + text.ascent()) / 2, text)
	}

	private fun drawFace(canvas: Canvas, b: Button)
	{
		val r = b.rect.width() / 2
		fill.color = if(b.pressed) pressedFill else idleFill
		canvas.drawCircle(b.cx, b.cy, r, fill)
		canvas.drawCircle(b.cx, b.cy, r, stroke)
		val g = r * 0.42f
		when(b.kind)
		{
			Kind.CROSS ->
			{
				canvas.drawLine(b.cx - g, b.cy - g, b.cx + g, b.cy + g, glyph)
				canvas.drawLine(b.cx + g, b.cy - g, b.cx - g, b.cy + g, glyph)
			}
			Kind.MOON -> canvas.drawCircle(b.cx, b.cy, g * 1.1f, glyph)
			Kind.BOX -> canvas.drawRect(b.cx - g, b.cy - g, b.cx + g, b.cy + g, glyph)
			else ->
			{
				path.rewind()
				path.moveTo(b.cx, b.cy - g * 1.15f)
				path.lineTo(b.cx + g * 1.2f, b.cy + g * 0.85f)
				path.lineTo(b.cx - g * 1.2f, b.cy + g * 0.85f)
				path.close()
				canvas.drawPath(path, glyph)
			}
		}
	}

	private fun drawSmall(canvas: Canvas, b: Button)
	{
		val r = min(b.rect.width(), b.rect.height()) / 2
		when(b.kind)
		{
			Kind.PS ->
			{
				fill.color = if(b.pressed) pressedFill else idleFill
				canvas.drawCircle(b.cx, b.cy, r, fill)
				canvas.drawCircle(b.cx, b.cy, r, stroke)
				text.textSize = r * 0.85f
				canvas.drawText("PS", b.cx, b.cy - (text.descent() + text.ascent()) / 2, text)
			}
			Kind.MENU ->
			{
				fill.color = if(b.pressed) pressedFill else idleFill
				canvas.drawCircle(b.cx, b.cy, r, fill)
				canvas.drawCircle(b.cx, b.cy, r, stroke)
				fill.color = Color.WHITE
				for(i in -1..1)
					canvas.drawCircle(b.cx + i * r * 0.42f, b.cy, r * 0.11f, fill)
			}
			else ->
			{
				// «Створити» та «Параметри» на DualSense — вузькі овальні кнопки
				tmp.set(b.cx - r * 0.5f, b.cy - r * 0.2f, b.cx + r * 0.5f, b.cy + r)
				body(canvas, tmp, r * 0.5f, b.pressed)
				if(b.kind == Kind.OPTIONS)
				{
					for(i in 0..2)
					{
						val y = b.cy - r * 0.95f + i * r * 0.25f
						canvas.drawLine(b.cx - r * 0.42f, y, b.cx + r * 0.42f, y, glyph)
					}
				}
				else
				{
					val y = b.cy - r * 0.45f
					canvas.drawLine(b.cx, y, b.cx, y - r * 0.42f, glyph)
					canvas.drawLine(b.cx - r * 0.38f, y, b.cx - r * 0.62f, y - r * 0.36f, glyph)
					canvas.drawLine(b.cx + r * 0.38f, y, b.cx + r * 0.62f, y - r * 0.36f, glyph)
				}
			}
		}
	}

	private fun drawTouchpad(canvas: Canvas)
	{
		body(canvas, touchpad, touchpad.height() * 0.28f, touchpadPressed || touchpadPointer >= 0)
		val cx = touchpad.centerX(); val cy = touchpad.centerY(); val s = touchpad.height() * 0.16f
		tmp.set(cx - s * 1.5f, cy - s, cx + s * 1.5f, cy + s)
		val a = glyph.alpha
		glyph.alpha = 150
		canvas.drawRoundRect(tmp, s * 0.5f, s * 0.5f, glyph)
		glyph.alpha = a
	}

	private fun drawDpad(canvas: Canvas)
	{
		val masks = arrayOf(ControllerState.BUTTON_DPAD_UP, ControllerState.BUTTON_DPAD_RIGHT, ControllerState.BUTTON_DPAD_DOWN, ControllerState.BUTTON_DPAD_LEFT)
		val half = dpadR * 0.27f        // половина ширини пелюстки
		val outer = dpadR * 0.98f
		val inner = dpadR * 0.44f
		val tip = dpadR * 0.13f
		for(i in 0..3)
		{
			canvas.save()
			canvas.rotate(90f * i, dpadX, dpadY)
			path.rewind()
			val x0 = dpadX - half; val x1 = dpadX + half
			val yo = dpadY - outer; val yi = dpadY - inner
			val c = half * 0.7f
			path.moveTo(x0, yo + c)
			path.quadTo(x0, yo, x0 + c, yo)
			path.lineTo(x1 - c, yo)
			path.quadTo(x1, yo, x1, yo + c)
			path.lineTo(x1, yi)
			path.lineTo(dpadX, dpadY - tip)
			path.lineTo(x0, yi)
			path.close()
			fill.color = if(dpadMask and masks[i] != 0U) pressedFill else idleFill
			canvas.drawPath(path, fill)
			canvas.drawPath(path, stroke)
			canvas.restore()
		}
	}

	private fun drawStick(canvas: Canvas, s: Stick)
	{
		val active = s.pointer >= 0
		fill.color = if(landscape) Color.argb(if(active) 60 else 35, 255, 255, 255) else Color.argb(255, 36, 32, 54)
		canvas.drawCircle(s.cx, s.cy, stickR * 1.55f, fill)
		val a = stroke.alpha
		stroke.alpha = if(active) 200 else 110
		canvas.drawCircle(s.cx, s.cy, stickR * 1.55f, stroke)
		stroke.alpha = a
		val hx = s.cx + s.dx * stickR; val hy = s.cy + s.dy * stickR
		fill.color = if(s.click) pressedFill else Color.argb(if(active) 150 else 90, 255, 255, 255)
		canvas.drawCircle(hx, hy, stickR, fill)
		canvas.drawCircle(hx, hy, stickR, stroke)
	}

	// ── дотики ──
	private fun buttonAt(x: Float, y: Float): Button?
	{
		var best: Button? = null
		var bestD = Float.MAX_VALUE
		for(b in buttons.values)
		{
			val pad = b.rect.width() * 0.22f
			if(x < b.rect.left - pad || x > b.rect.right + pad || y < b.rect.top - pad || y > b.rect.bottom + pad)
				continue
			val d = hypot(x - b.cx, y - b.cy)
			if(d < bestD) { bestD = d; best = b }
		}
		return best
	}

	private fun dpadMaskAt(x: Float, y: Float): UInt
	{
		val dx = x - dpadX; val dy = y - dpadY
		if(hypot(dx, dy) < dpadR * 0.16f)
			return 0U
		val deg = (Math.toDegrees(atan2(dy.toDouble(), dx.toDouble())) + 360.0) % 360.0   // 0 — праворуч, 90 — вниз
		val sector = (((deg + 22.5) % 360.0) / 45.0).toInt()
		return when(sector)
		{
			0 -> ControllerState.BUTTON_DPAD_RIGHT
			1 -> ControllerState.BUTTON_DPAD_RIGHT or ControllerState.BUTTON_DPAD_DOWN
			2 -> ControllerState.BUTTON_DPAD_DOWN
			3 -> ControllerState.BUTTON_DPAD_DOWN or ControllerState.BUTTON_DPAD_LEFT
			4 -> ControllerState.BUTTON_DPAD_LEFT
			5 -> ControllerState.BUTTON_DPAD_LEFT or ControllerState.BUTTON_DPAD_UP
			6 -> ControllerState.BUTTON_DPAD_UP
			else -> ControllerState.BUTTON_DPAD_UP or ControllerState.BUTTON_DPAD_RIGHT
		}
	}

	private fun moveStick(s: Stick, x: Float, y: Float)
	{
		var dx = (x - s.cx) / stickR
		var dy = (y - s.cy) / stickR
		val len = hypot(dx, dy)
		if(len > 1f) { dx /= len; dy /= len }
		s.dx = dx; s.dy = dy
	}

	private fun touchpadPos(x: Float, y: Float): Pair<UShort, UShort>
	{
		val fx = ((x - touchpad.left) / touchpad.width()).coerceIn(0f, 1f)
		val fy = ((y - touchpad.top) / touchpad.height()).coerceIn(0f, 1f)
		return Pair((fx * (ControllerState.TOUCHPAD_WIDTH.toInt() - 1)).toInt().toUShort(),
			(fy * (ControllerState.TOUCHPAD_HEIGHT.toInt() - 1)).toInt().toUShort())
	}

	private fun pointerDown(id: Int, x: Float, y: Float)
	{
		val now = SystemClock.uptimeMillis()
		val b = buttonAt(x, y)
		if(b != null)
		{
			buttonPointers[id] = b
			if(!b.pressed)
			{
				b.pressed = true
				haptics.trigger()
			}
			return
		}
		if(dpadPointer < 0 && hypot(x - dpadX, y - dpadY) <= dpadR * 1.2f)
		{
			dpadPointer = id
			dpadMask = dpadMaskAt(x, y)
			haptics.trigger()
			return
		}
		if(touchpadPointer < 0 && touchpad.contains(x, y))
		{
			touchpadPointer = id
			touchpadDownAt = now
			touchpadDownX = x; touchpadDownY = y
			val p = touchpadPos(x, y)
			touchpadTouchId = state.startTouch(p.first, p.second)
			return
		}
		for(s in arrayOf(leftStick, rightStick))
		{
			if(s.pointer < 0 && s.zone.contains(x, y))
			{
				s.pointer = id
				// стік з'являється там, де поставили палець, але не тікає далеко від свого місця у вертикальному режимі
				if(landscape) { s.cx = x; s.cy = y }
				else { s.cx = s.homeX; s.cy = s.homeY; moveStick(s, x, y) }
				s.click = now - s.lastUp < 300
				if(s.click)
					haptics.trigger(true)
				return
			}
		}
	}

	private fun pointerMove(id: Int, x: Float, y: Float)
	{
		val held = buttonPointers[id]
		if(held != null)
		{
			// палець з'їхав на сусідню кнопку (наприклад з ✕ на ○) — перемикаємо без відривання
			val b = buttonAt(x, y)
			if(b != null && b !== held && held.kind != Kind.MENU && b.kind != Kind.MENU)
			{
				if(buttonPointers.values.count { it === held } <= 1)
					held.pressed = false
				buttonPointers[id] = b
				if(!b.pressed)
				{
					b.pressed = true
					haptics.trigger()
				}
			}
			return
		}
		if(id == dpadPointer)
		{
			val m = dpadMaskAt(x, y)
			if(m != dpadMask)
			{
				dpadMask = m
				if(m != 0U)
					haptics.trigger()
			}
			return
		}
		if(id == touchpadPointer)
		{
			val p = touchpadPos(x, y)
			touchpadTouchId?.let { state.setTouchPos(it, p.first, p.second) }
			return
		}
		for(s in arrayOf(leftStick, rightStick))
			if(id == s.pointer)
				moveStick(s, x, y)
	}

	private fun pointerUp(id: Int, x: Float, y: Float, cancelled: Boolean)
	{
		val now = SystemClock.uptimeMillis()
		val b = buttonPointers.remove(id)
		if(b != null)
		{
			if(buttonPointers.values.none { it === b })
				b.pressed = false
			if(b.kind == Kind.MENU && !cancelled && b.rect.contains(x, y))
				menuCallback?.invoke()
			return
		}
		if(id == dpadPointer)
		{
			dpadPointer = -1
			dpadMask = 0U
			return
		}
		if(id == touchpadPointer)
		{
			touchpadPointer = -1
			touchpadTouchId?.let { state.stopTouch(it) }
			touchpadTouchId = null
			// короткий дотик без руху — це натискання тачпада
			if(!cancelled && now - touchpadDownAt < 250 && hypot(x - touchpadDownX, y - touchpadDownY) < dp(12f))
			{
				touchpadPressed = true
				haptics.trigger(true)
				removeCallbacks(touchpadRelease)
				postDelayed(touchpadRelease, 110)
			}
			return
		}
		for(s in arrayOf(leftStick, rightStick))
		{
			if(id == s.pointer)
			{
				s.pointer = -1
				s.dx = 0f; s.dy = 0f
				s.click = false
				s.cx = s.homeX; s.cy = s.homeY
				s.lastUp = now
			}
		}
	}

	override fun onTouchEvent(event: MotionEvent): Boolean
	{
		when(event.actionMasked)
		{
			MotionEvent.ACTION_DOWN, MotionEvent.ACTION_POINTER_DOWN ->
			{
				val i = event.actionIndex
				pointerDown(event.getPointerId(i), event.getX(i), event.getY(i))
			}
			MotionEvent.ACTION_MOVE ->
				for(i in 0 until event.pointerCount)
					pointerMove(event.getPointerId(i), event.getX(i), event.getY(i))
			MotionEvent.ACTION_UP, MotionEvent.ACTION_POINTER_UP ->
			{
				val i = event.actionIndex
				pointerUp(event.getPointerId(i), event.getX(i), event.getY(i), false)
			}
			MotionEvent.ACTION_CANCEL ->
				for(i in 0 until event.pointerCount)
					pointerUp(event.getPointerId(i), event.getX(i), event.getY(i), true)
		}
		pushState()
		invalidate()
		return true
	}

	private fun quantize(f: Float): Short = (Short.MAX_VALUE * f.coerceIn(-1f, 1f)).toInt().toShort()

	private fun pushState()
	{
		var mask = dpadMask
		fun on(kind: Kind, bit: UInt) { if(buttons[kind]!!.pressed) mask = mask or bit }
		on(Kind.CROSS, ControllerState.BUTTON_CROSS)
		on(Kind.MOON, ControllerState.BUTTON_MOON)
		on(Kind.BOX, ControllerState.BUTTON_BOX)
		on(Kind.PYRAMID, ControllerState.BUTTON_PYRAMID)
		on(Kind.L1, ControllerState.BUTTON_L1)
		on(Kind.R1, ControllerState.BUTTON_R1)
		on(Kind.CREATE, ControllerState.BUTTON_SHARE)
		on(Kind.OPTIONS, ControllerState.BUTTON_OPTIONS)
		on(Kind.PS, ControllerState.BUTTON_PS)
		if(leftStick.click) mask = mask or ControllerState.BUTTON_L3
		if(rightStick.click) mask = mask or ControllerState.BUTTON_R3
		if(touchpadPressed) mask = mask or ControllerState.BUTTON_TOUCHPAD
		state.buttons = mask
		state.l2State = if(buttons[Kind.L2]!!.pressed) 255U else 0U
		state.r2State = if(buttons[Kind.R2]!!.pressed) 255U else 0U
		state.leftX = quantize(leftStick.dx)
		state.leftY = quantize(leftStick.dy)
		state.rightX = quantize(rightStick.dx)
		state.rightY = quantize(rightStick.dy)
		// копія з окремими об'єктами дотиків: стан читає інший потік
		stateChangedCallback?.invoke(state.copy(touches = state.touches.map { it.copy() }.toTypedArray()))
	}

	/** Відпустити все (екран згорнули, кнопки сховали) */
	fun releaseAll()
	{
		buttonPointers.clear()
		buttons.values.forEach { it.pressed = false }
		dpadPointer = -1; dpadMask = 0U
		touchpadPointer = -1
		touchpadTouchId?.let { state.stopTouch(it) }
		touchpadTouchId = null
		touchpadPressed = false
		for(s in arrayOf(leftStick, rightStick))
		{
			s.pointer = -1; s.dx = 0f; s.dy = 0f; s.click = false; s.cx = s.homeX; s.cy = s.homeY
		}
		pushState()
		invalidate()
	}
}
