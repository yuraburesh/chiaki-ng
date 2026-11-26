// AnyPlay: екранний геймпад DualSense. Скляні напівпрозорі кнопки з тонким світлим краєм; розташування, розмір
// і прозорість налаштовує сам гравець (PadLayout, редактор PadEditor), окремо для горизонтального й вертикального екрана.
// Вертикально кнопки під картинкою гри, горизонтально — поверх неї по краях. Якщо екрана не торкаються
// (граючи з геймпада), кнопки ховаються; перший дотик лише показує їх і в гру не йде.
package com.metallic.chiaki.anyplay

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.DashPathEffect
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.os.SystemClock
import android.util.AttributeSet
import android.view.MotionEvent
import android.view.View
import com.metallic.chiaki.lib.ControllerState
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

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
	/** Редактор: змінився вибір, розмір або орієнтація екрана */
	var editListener: (() -> Unit)? = null
	/** 123: у редакторі почали (true) або закінчили (false) тягнути чи змінювати кнопку — панель редактора ховається */
	var editDragListener: ((Boolean) -> Unit)? = null

	private val state = ControllerState()

	private enum class Kind { SHOULDER, TOUCHPAD, DPAD, FACE, STICK, SMALL, PS, MENU, EXTRA, CLICK }

	private class Item(val el: PadElement, val kind: Kind)
	{
		var cx = 0f
		var cy = 0f
		var hw = 0f     // половина ширини
		var hh = 0f     // половина висоти
		val bounds = RectF()
	}

	/** Кнопка, яку можна натиснути (у групи ✕○□△ їх чотири) */
	private class Key(val item: Item, val glyph: Int, val bits: UInt, val trigger: Int)
	{
		val rect = RectF()
		var downs = 0          // скільки пальців тримають
		// 125: аналоговий курок — сила натиску 0..1 (протягнути палець униз), де почали і яку сходинку вже відчули
		var level = 1f
		var downY = 0f
		var step = 0
		var full = false
		val pressed get() = downs > 0
		val cx get() = rect.centerX()
		val cy get() = rect.centerY()
	}

	private class Stick(val right: Boolean)
	{
		var item: Item? = null
		var cx = 0f; var cy = 0f           // центр під час дотику
		var dx = 0f; var dy = 0f           // відхилення -1..1
		var pointer = -1
		var lastUp = 0L
		var click = false                  // L3 / R3 (подвійний дотик)
		var edge = false                   // 125: стік дотягнуто до краю (упор уже відчули)
		val zone = RectF()
	}

	private companion object
	{
		const val G_TEXT = 0
		const val G_CROSS = 1
		const val G_MOON = 2
		const val G_BOX = 3
		const val G_PYRAMID = 4
		const val G_CREATE = 5
		const val G_OPTIONS = 6
		const val G_PS = 7
		const val G_MENU = 8
		const val G_EXTRA = 9
		const val G_CLICK = 10   // 126: окремі кнопки L3/R3 (натиснути стік)
		const val TRIGGER_L2 = 1
		const val TRIGGER_R2 = 2
		const val ANALOG_START = 0.45f     // аналоговий курок: сила одразу після дотику
		const val ANALOG_PULL_DP = 42f     // на скільки dp протягнути вниз до повного натиску

		fun kindOf(id: String): Kind = when(id)
		{
			"l2", "l1", "r2", "r1" -> Kind.SHOULDER
			"touchpad" -> Kind.TOUCHPAD
			"dpad" -> Kind.DPAD
			"face" -> Kind.FACE
			"lstick", "rstick" -> Kind.STICK
			"create", "options" -> Kind.SMALL
			"ps" -> Kind.PS
			"menu" -> Kind.MENU
			"l3", "r3" -> Kind.CLICK
			else -> Kind.EXTRA
		}

		/** Типовий розмір у dp (ширина, висота) до множників екрана й гравця */
		fun baseW(kind: Kind): Float = when(kind)
		{
			Kind.SHOULDER -> 60f; Kind.TOUCHPAD -> 112f; Kind.DPAD -> 92f; Kind.FACE -> 108f; Kind.STICK -> 88f
			Kind.SMALL -> 30f; Kind.PS -> 32f; Kind.MENU -> 34f; Kind.EXTRA -> 54f; Kind.CLICK -> 40f
		}

		fun baseH(kind: Kind): Float = when(kind)
		{
			Kind.SHOULDER -> 32f; Kind.TOUCHPAD -> 34f; Kind.SMALL -> 28f
			else -> baseW(kind)
		}

		/** Біти кнопки геймпада і курок (L2/R2) для коду з PadLayout.BUTTONS */
		fun bitsOf(code: String): Pair<UInt, Int> = when(code)
		{
			"CROSS" -> ControllerState.BUTTON_CROSS to 0
			"MOON" -> ControllerState.BUTTON_MOON to 0
			"BOX" -> ControllerState.BUTTON_BOX to 0
			"PYRAMID" -> ControllerState.BUTTON_PYRAMID to 0
			"L1" -> ControllerState.BUTTON_L1 to 0
			"R1" -> ControllerState.BUTTON_R1 to 0
			"L2" -> 0U to TRIGGER_L2
			"R2" -> 0U to TRIGGER_R2
			"L3" -> ControllerState.BUTTON_L3 to 0
			"R3" -> ControllerState.BUTTON_R3 to 0
			"UP" -> ControllerState.BUTTON_DPAD_UP to 0
			"DOWN" -> ControllerState.BUTTON_DPAD_DOWN to 0
			"LEFT" -> ControllerState.BUTTON_DPAD_LEFT to 0
			"RIGHT" -> ControllerState.BUTTON_DPAD_RIGHT to 0
			"CREATE" -> ControllerState.BUTTON_SHARE to 0
			"OPTIONS" -> ControllerState.BUTTON_OPTIONS to 0
			"PS" -> ControllerState.BUTTON_PS to 0
			"TOUCHPAD" -> ControllerState.BUTTON_TOUCHPAD to 0
			else -> 0U to 0
		}
	}

	// ── розташування ──
	private var landscape = false
	private var profileLand: Boolean? = null
	var profile: PadProfile = PadLayout.defaults(false)
		private set
	private val items = ArrayList<Item>()
	private val keys = ArrayList<Key>()
	private var dpad: Item? = null
	private var touchpad: Item? = null
	private val leftStick = Stick(false)
	private val rightStick = Stick(true)
	private val sticks = arrayOf(leftStick, rightStick)
	private val area = RectF()        // де можуть стояти кнопки
	private var unit = 1f             // пікселів на 1 dp типового розміру

	private var opacity = PadLayout.opacity(context)
	private var autoHideSec = PadLayout.autoHide(context)

	// ── дотики ──
	private val keyPointers = HashMap<Int, Key>()
	private val swallowed = HashSet<Int>()    // дотик, що лише показав сховані кнопки: у гру не йде
	private var dpadPointer = -1
	private var dpadMask = 0U
	private var touchpadPointer = -1
	private var touchpadTouchId: UByte? = null
	private var touchpadDownAt = 0L
	private var touchpadDownX = 0f
	private var touchpadDownY = 0f
	private var touchpadPressed = false
	private val touchpadRelease = Runnable {
		touchpadPressed = false
		pushState()
		invalidate()
	}

	// ── малювання ──
	private val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL }
	private val edge = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE }
	private val shade = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE }
	private val glyph = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeCap = Paint.Cap.ROUND; strokeJoin = Paint.Join.ROUND }
	private val text = Paint(Paint.ANTI_ALIAS_FLAG).apply { textAlign = Paint.Align.CENTER; typeface = AnyPlayStyle.displayMedium(context) }
	private val frame = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE }
	private val dash = DashPathEffect(floatArrayOf(dp(5f), dp(4f)), 0f)
	private val path = Path()
	private val tmp = RectF()

	init
	{
		isHapticFeedbackEnabled = false
	}

	// прозорість задаємо в самих кольорах, а згасання — через alpha вікна без окремого буфера
	override fun hasOverlappingRendering() = false

	override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int)
	{
		relayout()
		// 128: вертикально кнопки завжди на екрані (під картинкою вони нічого не закривають)
		if(!landscape && !shown)
			reveal()
		scheduleHide()
	}

	/** Перерахувати розкладку (змінились відступи чи положення картинки) */
	fun refreshLayout()
	{
		relayout()
		invalidate()
	}

	/** Перечитати прозорість і автоховання (змінили в редакторі) */
	fun reloadSettings()
	{
		opacity = PadLayout.opacity(context)
		autoHideSec = PadLayout.autoHide(context)
		reveal()
		invalidate()
	}

	private fun dp(v: Float) = v * resources.displayMetrics.density

	private fun loadProfile()
	{
		val land = landscape
		// у редакторі повернули телефон: зберігаємо розташування для попередньої орієнтації
		profileLand?.let { old -> if(editMode && old != land) PadLayout.save(context, old, profile) }
		profileLand = land
		profile = PadLayout.load(context, land)
		if(editMode)
			selectedId = null
		rebuild()
		editListener?.invoke()
	}

	/** Створити кнопки з профілю (після завантаження чи змін у редакторі) */
	private fun rebuild()
	{
		releasePointers()
		items.clear()
		keys.clear()
		dpad = null
		touchpad = null
		leftStick.item = null
		rightStick.item = null
		for(el in profile.elements)
		{
			if(!el.on && el.id != "menu")
				continue
			val kind = kindOf(el.id)
			val it = Item(el, kind)
			items.add(it)
			when(kind)
			{
				Kind.SHOULDER -> keys.add(when(el.id)
				{
					"l2" -> Key(it, G_TEXT, 0U, TRIGGER_L2)
					"r2" -> Key(it, G_TEXT, 0U, TRIGGER_R2)
					"l1" -> Key(it, G_TEXT, ControllerState.BUTTON_L1, 0)
					else -> Key(it, G_TEXT, ControllerState.BUTTON_R1, 0)
				})
				Kind.FACE ->
				{
					keys.add(Key(it, G_PYRAMID, ControllerState.BUTTON_PYRAMID, 0))
					keys.add(Key(it, G_MOON, ControllerState.BUTTON_MOON, 0))
					keys.add(Key(it, G_CROSS, ControllerState.BUTTON_CROSS, 0))
					keys.add(Key(it, G_BOX, ControllerState.BUTTON_BOX, 0))
				}
				Kind.SMALL -> keys.add(if(el.id == "create") Key(it, G_CREATE, ControllerState.BUTTON_SHARE, 0)
					else Key(it, G_OPTIONS, ControllerState.BUTTON_OPTIONS, 0))
				Kind.PS -> keys.add(Key(it, G_PS, ControllerState.BUTTON_PS, 0))
				Kind.CLICK -> keys.add(Key(it, G_CLICK, if(el.id == "l3") ControllerState.BUTTON_L3 else ControllerState.BUTTON_R3, 0))
				Kind.MENU -> keys.add(Key(it, G_MENU, 0U, 0))
				Kind.EXTRA ->
				{
					val b = bitsOf(el.button)
					keys.add(Key(it, G_EXTRA, b.first, b.second))
				}
				Kind.DPAD -> dpad = it
				Kind.TOUCHPAD -> touchpad = it
				Kind.STICK -> if(el.id == "lstick") leftStick.item = it else rightStick.item = it
			}
		}
		relayout()
		pushState()
		invalidate()
	}

	private fun relayout()
	{
		val w = width.toFloat()
		val h = height.toFloat()
		if(w <= 0 || h <= 0)
			return
		val land = w > h
		if(profileLand != land)
		{
			landscape = land
			loadProfile()   // кличе rebuild(), а той — relayout() уже з новим профілем
			return
		}
		val d = resources.displayMetrics.density
		if(landscape)
		{
			area.set(safeLeft.toFloat(), 0f, w - safeRight, h - safeBottom)
			unit = d * (min(w, h) / d / 380f).coerceIn(0.85f, 1.35f)
		}
		else
		{
			area.set(0f, min(videoBottom.toFloat(), h * 0.6f), w, h - safeBottom)
			val byW = w / d / 380f * 1.1f
			val byH = area.height() / d / 450f   // 128: вертикально кнопки трохи більші (місця під картинкою досить)
			unit = d * min(byW, byH).coerceIn(0.7f, 1.4f)
		}
		for(it in items)
		{
			val s = unit * profile.scale * it.el.scale
			it.hw = baseW(it.kind) * s / 2
			it.hh = baseH(it.kind) * s / 2
			val x = area.left + it.el.x * area.width()
			val y = area.top + it.el.y * area.height()
			it.cx = if(area.width() > 2 * it.hw) x.coerceIn(area.left + it.hw, area.right - it.hw) else area.centerX()
			it.cy = if(area.height() > 2 * it.hh) y.coerceIn(area.top + it.hh, area.bottom - it.hh) else area.centerY()
			it.bounds.set(it.cx - it.hw, it.cy - it.hh, it.cx + it.hw, it.cy + it.hh)
		}
		for(k in keys)
		{
			val it = k.item
			if(it.kind == Kind.FACE)
			{
				val off = it.hw * 0.68f
				val r = it.hw * 0.33f
				val (x, y) = when(k.glyph)
				{
					G_PYRAMID -> it.cx to it.cy - off
					G_MOON -> it.cx + off to it.cy
					G_CROSS -> it.cx to it.cy + off
					else -> it.cx - off to it.cy
				}
				k.rect.set(x - r, y - r, x + r, y + r)
			}
			else
				k.rect.set(it.bounds)
		}
		for(s in sticks)
		{
			val it = s.item ?: continue
			val grow = it.hw * (if(landscape) 1.9f else 1.3f)
			s.zone.set(it.bounds.left - grow, it.bounds.top - grow, it.bounds.right + grow, it.bounds.bottom + grow)
			if(!s.zone.intersect(area))
				s.zone.set(it.bounds)
			if(s.pointer < 0) { s.cx = it.cx; s.cy = it.cy }
		}
		// зони двох стіків не налазять одна на одну: ділимо посередині
		val li = leftStick.item
		val ri = rightStick.item
		if(li != null && ri != null && RectF.intersects(leftStick.zone, rightStick.zone))
		{
			val mid = (li.cx + ri.cx) / 2
			if(li.cx <= ri.cx)
			{
				leftStick.zone.right = min(leftStick.zone.right, mid)
				rightStick.zone.left = max(rightStick.zone.left, mid)
			}
			else
			{
				leftStick.zone.left = max(leftStick.zone.left, mid)
				rightStick.zone.right = min(rightStick.zone.right, mid)
			}
		}
		edge.strokeWidth = max(dp(1f), unit * 0.9f)
		shade.strokeWidth = edge.strokeWidth * 2.6f
		glyph.strokeWidth = max(dp(1.5f), unit * 1.5f)
	}

	// ── малювання ──
	/** 128: вертикально кнопки стоять на власному тлі під картинкою — тож вони щільні й об'ємні, як на справжньому
	 *  геймпаді (кольорові символи як на DualShock 4), без прозорості. Горизонтально — скляні поверх гри, як були */
	private val solid get() = !landscape
	private fun al(a: Int) = if(solid) 255 else (a * opacity).toInt().coerceIn(0, 255)
	private val grad = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL }
	private val glow = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE }
	private val SOLID_HI = Color.rgb(78, 74, 98)
	private val SOLID_LO = Color.rgb(30, 27, 42)
	private val SOLID_PRESS_HI = Color.rgb(52, 48, 70)
	private val SOLID_PRESS_LO = Color.rgb(24, 21, 34)
	private val ACCENT = Color.rgb(143, 227, 255)
	private val SOLID_INK = Color.rgb(232, 229, 242)

	/** Тінь під кнопкою і об'ємне тіло (світло зверху ліворуч), натиснута — нижче й темніша, з кільцем підсвітки */
	private fun solidShape(canvas: Canvas, pressed: Boolean, draw: (Paint) -> Unit, bounds: RectF)
	{
		val lift = if(pressed) dp(0.6f) else dp(2.2f)
		canvas.save()
		canvas.translate(0f, lift)
		fill.color = Color.argb(if(pressed) 90 else 150, 0, 0, 0)
		draw(fill)
		canvas.restore()
		grad.shader = android.graphics.LinearGradient(bounds.left, bounds.top, bounds.left + bounds.width() * 0.35f, bounds.bottom,
			if(pressed) SOLID_PRESS_HI else SOLID_HI, if(pressed) SOLID_PRESS_LO else SOLID_LO, android.graphics.Shader.TileMode.CLAMP)
		draw(grad)
		grad.shader = null
		edge.color = if(pressed) ACCENT else Color.argb(46, 255, 255, 255)
		draw(edge)
		if(pressed)
		{
			glow.strokeWidth = edge.strokeWidth * 4f
			glow.color = Color.argb(70, 143, 227, 255)
			draw(glow)
		}
	}

	/** Колір символу кнопки, як на DualShock 4: трикутник зелений, коло червоне, хрестик синій, квадрат рожевий */
	private fun faceColor(g: Int): Int = when(g)
	{
		G_PYRAMID -> Color.rgb(64, 226, 170)
		G_MOON -> Color.rgb(255, 92, 108)
		G_CROSS -> Color.rgb(122, 170, 255)
		G_BOX -> Color.rgb(246, 140, 220)
		else -> SOLID_INK
	}
	private val idleFill get() = Color.argb(al(42), 255, 255, 255)
	private val pressedFill get() = Color.argb(al(135), 143, 227, 255)
	private val idleEdge get() = Color.argb(al(160), 255, 255, 255)
	private val pressedEdge get() = Color.argb(al(240), 143, 227, 255)
	private val ink get() = Color.argb(al(235), 255, 255, 255)

	override fun onDraw(canvas: Canvas)
	{
		if(!landscape)
		{
			// під картинкою — темне тло в кольорах AnyPlay
			// 128: тло як матовий корпус геймпада: трохи світліше вгорі, з тонкою світлою смугою під картинкою
			grad.shader = android.graphics.LinearGradient(0f, area.top, 0f, height.toFloat(), Color.rgb(40, 36, 58), Color.rgb(22, 20, 33), android.graphics.Shader.TileMode.CLAMP)
			canvas.drawRect(0f, area.top, width.toFloat(), height.toFloat(), grad)
			grad.shader = null
			fill.color = Color.argb(90, 143, 227, 255)
			canvas.drawRect(0f, area.top, width.toFloat(), area.top + dp(1.5f), fill)
		}
		shade.color = Color.argb(al(60), 0, 0, 0)
		glyph.color = ink
		text.color = ink
		for(it in items)
		{
			when(it.kind)
			{
				Kind.DPAD -> drawDpad(canvas, it)
				Kind.TOUCHPAD -> drawTouchpad(canvas, it)
				Kind.STICK -> drawStick(canvas, if(it === leftStick.item) leftStick else rightStick, it)
				else -> {}
			}
		}
		for(k in keys)
			drawKey(canvas, k)
		if(editMode)
			drawEditFrames(canvas)
	}

	private fun body(canvas: Canvas, rect: RectF, radius: Float, pressed: Boolean)
	{
		if(solid)
		{
			solidShape(canvas, pressed, { p -> canvas.drawRoundRect(rect, radius, radius, p) }, rect)
			return
		}
		fill.color = if(pressed) pressedFill else idleFill
		canvas.drawRoundRect(rect, radius, radius, fill)
		canvas.drawRoundRect(rect, radius, radius, shade)
		edge.color = if(pressed) pressedEdge else idleEdge
		canvas.drawRoundRect(rect, radius, radius, edge)
	}

	private fun circle(canvas: Canvas, cx: Float, cy: Float, r: Float, pressed: Boolean)
	{
		if(solid)
		{
			tmp.set(cx - r, cy - r, cx + r, cy + r)
			solidShape(canvas, pressed, { p -> canvas.drawCircle(cx, cy, r, p) }, RectF(tmp))
			return
		}
		fill.color = if(pressed) pressedFill else idleFill
		canvas.drawCircle(cx, cy, r, fill)
		canvas.drawCircle(cx, cy, r, shade)
		edge.color = if(pressed) pressedEdge else idleEdge
		canvas.drawCircle(cx, cy, r, edge)
	}

	private fun centeredText(canvas: Canvas, s: String, x: Float, y: Float)
	{
		canvas.drawText(s, x, y - (text.descent() + text.ascent()) / 2, text)
	}

	private fun drawKey(canvas: Canvas, k: Key)
	{
		val r = min(k.rect.width(), k.rect.height()) / 2
		val cx = k.cx
		val cy = k.cy
		// вертикально натиснута кнопка «просідає»
		val sunk = solid && k.pressed
		if(sunk)
		{
			canvas.save()
			canvas.translate(0f, dp(1.6f))
		}
		if(solid)
		{
			glyph.color = if(k.glyph in intArrayOf(G_CROSS, G_MOON, G_BOX, G_PYRAMID)) faceColor(k.glyph) else SOLID_INK
			text.color = SOLID_INK
		}
		drawKeyBody(canvas, k, r, cx, cy)
		if(sunk)
			canvas.restore()
		if(solid)
		{
			glyph.color = ink
			text.color = ink
		}
	}

	private fun drawKeyBody(canvas: Canvas, k: Key, r: Float, cx: Float, cy: Float)
	{
		when(k.glyph)
		{
			G_TEXT ->
			{
				body(canvas, k.rect, k.rect.height() * 0.45f, k.pressed)
				if(k.trigger != 0)
					drawTriggerExtras(canvas, k, k.rect)
				text.textSize = k.rect.height() * 0.46f
				centeredText(canvas, PadLayout.TITLES[k.item.el.id] ?: "", cx, cy)
			}
			G_CROSS, G_MOON, G_BOX, G_PYRAMID ->
			{
				circle(canvas, cx, cy, r, k.pressed)
				val g = r * 0.4f
				when(k.glyph)
				{
					G_CROSS ->
					{
						canvas.drawLine(cx - g, cy - g, cx + g, cy + g, glyph)
						canvas.drawLine(cx + g, cy - g, cx - g, cy + g, glyph)
					}
					G_MOON -> canvas.drawCircle(cx, cy, g * 1.1f, glyph)
					G_BOX -> canvas.drawRect(cx - g, cy - g, cx + g, cy + g, glyph)
					else ->
					{
						path.rewind()
						path.moveTo(cx, cy - g * 1.15f)
						path.lineTo(cx + g * 1.2f, cy + g * 0.85f)
						path.lineTo(cx - g * 1.2f, cy + g * 0.85f)
						path.close()
						canvas.drawPath(path, glyph)
					}
				}
			}
			G_PS ->
			{
				circle(canvas, cx, cy, r, k.pressed)
				text.textSize = r * 0.8f
				centeredText(canvas, "PS", cx, cy)
			}
			G_CLICK ->
			{
				// як ковпачок стіка: коло з кільцем усередині і підписом
				circle(canvas, cx, cy, r, k.pressed)
				val a = glyph.alpha
				glyph.alpha = if(solid) 80 else al(110)
				canvas.drawCircle(cx, cy, r * 0.72f, glyph)
				glyph.alpha = a
				text.textSize = r * 0.62f
				centeredText(canvas, if(k.item.el.id == "l3") "L3" else "R3", cx, cy)
			}
			G_MENU ->
			{
				circle(canvas, cx, cy, r, k.pressed)
				fill.color = ink
				for(i in -1..1)
					canvas.drawCircle(cx + i * r * 0.42f, cy, r * 0.11f, fill)
			}
			G_CREATE, G_OPTIONS ->
			{
				// «Створити» та «Параметри» на DualSense — вузькі овальні кнопки
				tmp.set(cx - k.rect.width() * 0.3f, k.rect.top, cx + k.rect.width() * 0.3f, k.rect.bottom)
				body(canvas, tmp, tmp.width() / 2, k.pressed)
				val gw = tmp.width() * 0.26f
				if(k.glyph == G_OPTIONS)
				{
					for(i in -1..1)
					{
						val y = cy + i * tmp.height() * 0.17f
						canvas.drawLine(cx - gw, y, cx + gw, y, glyph)
					}
				}
				else
				{
					val y = cy + tmp.height() * 0.12f
					canvas.drawLine(cx, y, cx, y - tmp.height() * 0.3f, glyph)
					canvas.drawLine(cx - gw * 0.6f, y, cx - gw * 1.1f, y - tmp.height() * 0.24f, glyph)
					canvas.drawLine(cx + gw * 0.6f, y, cx + gw * 1.1f, y - tmp.height() * 0.24f, glyph)
				}
			}
			G_EXTRA ->
			{
				circle(canvas, cx, cy, r, k.pressed)
				val label = k.item.el.label
				text.textSize = r * 0.34f
				val tw = text.measureText(label)
				if(tw > r * 1.7f)
					text.textSize *= r * 1.7f / tw
				centeredText(canvas, label, cx, cy - r * 0.12f)
				val markColor = text.color
				text.color = Color.argb(al(170), 255, 255, 255)
				text.textSize = r * 0.3f
				centeredText(canvas, PadLayout.buttonMark(k.item.el.button), cx, cy + r * 0.4f)
				text.color = markColor
			}
		}
	}

	/**
	 * 125: курок L2/R2 — заповнення знизу вгору, наскільки сильно натиснуто (аналоговий режим), і золота риска внизу,
	 * коли гра зробила курок тугим (ефект DualSense: опір, «постріл», вібрація)
	 */
	private fun drawTriggerExtras(canvas: Canvas, k: Key, r: RectF)
	{
		if(k.pressed && k.level < 0.999f)
		{
			canvas.save()
			tmp.set(r.left, r.bottom - r.height() * k.level, r.right, r.bottom)
			canvas.clipRect(tmp)
			fill.color = Color.argb(al(120), 143, 227, 255)
			canvas.drawRoundRect(r, r.height() * 0.45f, r.height() * 0.45f, fill)
			canvas.restore()
		}
		if(AnyPlayHaptics.triggerEffect(k.trigger) != AnyPlayHaptics.Trigger.NONE)
		{
			val w = r.width() * 0.34f
			fill.color = Color.argb(al(230), 255, 217, 160)
			tmp.set(r.centerX() - w / 2, r.bottom - dp(4f), r.centerX() + w / 2, r.bottom - dp(2f))
			canvas.drawRoundRect(tmp, dp(1f), dp(1f), fill)
		}
	}

	/** Де зараз стоять кнопки (для панелі статистики: вона стає туди, де кнопок немає) */
	fun occupied(): List<RectF> = items.map { RectF(it.bounds) }

	private fun drawTouchpad(canvas: Canvas, it: Item)
	{
		body(canvas, it.bounds, it.bounds.height() * 0.3f, touchpadPressed || touchpadPointer >= 0)
		val s = it.bounds.height() * 0.16f
		tmp.set(it.cx - s * 1.5f, it.cy - s, it.cx + s * 1.5f, it.cy + s)
		val a = glyph.alpha
		glyph.alpha = if(solid) 120 else al(150)
		canvas.drawRoundRect(tmp, s * 0.5f, s * 0.5f, glyph)
		glyph.alpha = a
	}

	private fun drawDpad(canvas: Canvas, it: Item)
	{
		val masks = arrayOf(ControllerState.BUTTON_DPAD_UP, ControllerState.BUTTON_DPAD_RIGHT, ControllerState.BUTTON_DPAD_DOWN, ControllerState.BUTTON_DPAD_LEFT)
		val r = it.hw
		val half = r * 0.27f        // половина ширини пелюстки
		val outer = r * 0.98f
		val inner = r * 0.44f
		val tip = r * 0.13f
		for(i in 0..3)
		{
			canvas.save()
			canvas.rotate(90f * i, it.cx, it.cy)
			path.rewind()
			val x0 = it.cx - half
			val x1 = it.cx + half
			val yo = it.cy - outer
			val yi = it.cy - inner
			val c = half * 0.7f
			path.moveTo(x0, yo + c)
			path.quadTo(x0, yo, x0 + c, yo)
			path.lineTo(x1 - c, yo)
			path.quadTo(x1, yo, x1, yo + c)
			path.lineTo(x1, yi)
			path.lineTo(it.cx, it.cy - tip)
			path.lineTo(x0, yi)
			path.close()
			val pressed = dpadMask and masks[i] != 0U
			if(solid)
			{
				val b = RectF()
				path.computeBounds(b, true)
				solidShape(canvas, pressed, { p -> canvas.drawPath(path, p) }, b)
				glyph.color = SOLID_INK
			}
			else
			{
				fill.color = if(pressed) pressedFill else idleFill
				canvas.drawPath(path, fill)
				canvas.drawPath(path, shade)
				edge.color = if(pressed) pressedEdge else idleEdge
				canvas.drawPath(path, edge)
			}
			// стрілка на пелюстці
			val ay = yo + (yi - yo) * 0.42f
			val aw = half * 0.42f
			canvas.drawLine(it.cx - aw, ay + aw * 0.6f, it.cx, ay - aw * 0.4f, glyph)
			canvas.drawLine(it.cx + aw, ay + aw * 0.6f, it.cx, ay - aw * 0.4f, glyph)
			canvas.restore()
		}
	}

	private fun drawStick(canvas: Canvas, s: Stick, it: Item)
	{
		val active = s.pointer >= 0
		val ring = it.hw
		val knob = ring * 0.55f
		if(solid)
		{
			drawSolidStick(canvas, s, ring, knob, active)
			return
		}
		fill.color = Color.argb(al(if(active) 46 else 26), 255, 255, 255)
		canvas.drawCircle(s.cx, s.cy, ring, fill)
		canvas.drawCircle(s.cx, s.cy, ring, shade)
		edge.color = Color.argb(al(if(active) 200 else 120), 255, 255, 255)
		canvas.drawCircle(s.cx, s.cy, ring, edge)
		val travel = ring - knob * 0.8f
		val hx = s.cx + s.dx * travel
		val hy = s.cy + s.dy * travel
		fill.color = if(s.click) pressedFill else Color.argb(al(if(active) 110 else 60), 255, 255, 255)
		canvas.drawCircle(hx, hy, knob, fill)
		canvas.drawCircle(hx, hy, knob, shade)
		edge.color = if(s.click) pressedEdge else idleEdge
		canvas.drawCircle(hx, hy, knob, edge)
	}

	/** 128: стік як на геймпаді — заглиблення в корпусі і гумовий ковпачок з увігнутим кільцем */
	private fun drawSolidStick(canvas: Canvas, s: Stick, ring: Float, knob: Float, active: Boolean)
	{
		// заглиблення: темніше до краю, світла риска знизу
		grad.shader = android.graphics.RadialGradient(s.cx, s.cy, ring, intArrayOf(Color.rgb(22, 19, 32), Color.rgb(14, 12, 22)), null, android.graphics.Shader.TileMode.CLAMP)
		canvas.drawCircle(s.cx, s.cy, ring, grad)
		grad.shader = null
		edge.color = if(active) Color.argb(150, 143, 227, 255) else Color.argb(36, 255, 255, 255)
		canvas.drawCircle(s.cx, s.cy, ring, edge)
		val travel = ring - knob * 0.8f
		val hx = s.cx + s.dx * travel
		val hy = s.cy + s.dy * travel
		// тінь ковпачка
		fill.color = Color.argb(160, 0, 0, 0)
		canvas.drawCircle(hx, hy + dp(if(s.click) 1f else 3f), knob, fill)
		grad.shader = android.graphics.RadialGradient(hx - knob * 0.3f, hy - knob * 0.4f, knob * 1.5f,
			intArrayOf(if(s.click) SOLID_PRESS_HI else Color.rgb(92, 88, 114), SOLID_LO), null, android.graphics.Shader.TileMode.CLAMP)
		canvas.drawCircle(hx, hy, knob, grad)
		// увігнута середина
		grad.shader = android.graphics.RadialGradient(hx, hy + knob * 0.15f, knob * 0.72f,
			intArrayOf(Color.rgb(34, 31, 46), Color.rgb(52, 48, 68)), null, android.graphics.Shader.TileMode.CLAMP)
		canvas.drawCircle(hx, hy, knob * 0.7f, grad)
		grad.shader = null
		edge.color = if(s.click || active) ACCENT else Color.argb(50, 255, 255, 255)
		canvas.drawCircle(hx, hy, knob, edge)
		edge.color = Color.argb(30, 255, 255, 255)
		canvas.drawCircle(hx, hy, knob * 0.7f, edge)
	}

	private fun drawEditFrames(canvas: Canvas)
	{
		// 125: напрямні, коли кнопка вирівнялась по центру чи з іншою кнопкою
		frame.strokeWidth = dp(1f)
		frame.color = Color.argb(200, 255, 217, 160)
		frame.pathEffect = dash
		if(!guideX.isNaN()) canvas.drawLine(guideX, area.top, guideX, area.bottom, frame)
		if(!guideY.isNaN()) canvas.drawLine(area.left, guideY, area.right, guideY, frame)
		for(it in items)
		{
			val sel = it.el.id == selectedId
			tmp.set(it.bounds)
			tmp.inset(-dp(4f), -dp(4f))
			frame.strokeWidth = if(sel) dp(2f) else dp(1f)
			frame.color = if(sel) Color.rgb(143, 227, 255) else Color.argb(110, 255, 255, 255)
			frame.pathEffect = if(sel) null else dash
			canvas.drawRoundRect(tmp, dp(4f), dp(4f), frame)
		}
	}

	// ── гра: дотики ──
	private fun keyAt(x: Float, y: Float): Key?
	{
		var best: Key? = null
		var bestD = Float.MAX_VALUE
		for(k in keys)
		{
			val pad = max(k.rect.width() * 0.18f, dp(6f))
			if(x < k.rect.left - pad || x > k.rect.right + pad || y < k.rect.top - pad || y > k.rect.bottom + pad)
				continue
			val d = hypot(x - k.cx, y - k.cy)
			if(d < bestD) { bestD = d; best = k }
		}
		return best
	}

	// ── 125: відгук і аналогові курки ──
	private val analog get() = AnyPlayHaptics.analogTriggers(context)

	private fun feelDown(k: Key)
	{
		when
		{
			k.trigger != 0 -> AnyPlayHaptics.tap(context, AnyPlayHaptics.Tap.TRIGGER_DOWN, k.trigger)
			k.glyph == G_TEXT || k.glyph == G_CREATE || k.glyph == G_OPTIONS || k.glyph == G_PS || k.glyph == G_CLICK -> AnyPlayHaptics.tap(context, AnyPlayHaptics.Tap.CLICK)
			k.glyph == G_MENU -> AnyPlayHaptics.tap(context, AnyPlayHaptics.Tap.UI)
			else -> AnyPlayHaptics.tap(context, AnyPlayHaptics.Tap.TICK)
		}
	}

	private fun feelUp(k: Key)
	{
		if(k.trigger != 0)
			AnyPlayHaptics.tap(context, AnyPlayHaptics.Tap.TRIGGER_UP, k.trigger)
	}

	/** Курок натиснули: повністю одразу або (аналоговий режим) з половини, далі тягнеш палець униз */
	private fun triggerStart(k: Key, y: Float)
	{
		k.downY = y
		k.full = false
		k.level = if(analog) ANALOG_START else 1f
		k.step = (k.level * 4).toInt()
	}

	private fun triggerMove(k: Key, y: Float)
	{
		if(!analog)
			return
		val lv = (ANALOG_START + (y - k.downY) / dp(ANALOG_PULL_DP) * (1f - ANALOG_START)).coerceIn(0.15f, 1f)
		k.level = lv
		val step = (lv * 4).toInt()
		if(step > k.step && lv < 0.98f)
			AnyPlayHaptics.tap(context, AnyPlayHaptics.Tap.DETENT)
		k.step = step
		if(lv >= 0.98f && !k.full) { k.full = true; AnyPlayHaptics.tap(context, AnyPlayHaptics.Tap.TRIGGER_FULL, k.trigger) }
		else if(lv < 0.9f) k.full = false
	}

	private fun dpadMaskAt(x: Float, y: Float): UInt
	{
		val it = dpad ?: return 0U
		val dx = x - it.cx
		val dy = y - it.cy
		if(hypot(dx, dy) < it.hw * 0.16f)
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
		val it = s.item ?: return
		val travel = it.hw * 0.56f
		var dx = (x - s.cx) / travel
		var dy = (y - s.cy) / travel
		val len = hypot(dx, dy)
		if(len > 1f) { dx /= len; dy /= len }
		s.dx = dx
		s.dy = dy
		// 125: упор на краю, як у справжнього стіка
		if(len >= 0.97f && !s.edge) { s.edge = true; AnyPlayHaptics.tap(context, AnyPlayHaptics.Tap.DETENT) }
		else if(len < 0.8f) s.edge = false
	}

	private fun touchpadPos(x: Float, y: Float): Pair<UShort, UShort>
	{
		val r = touchpad?.bounds ?: return Pair(0.toUShort(), 0.toUShort())
		val fx = ((x - r.left) / r.width()).coerceIn(0f, 1f)
		val fy = ((y - r.top) / r.height()).coerceIn(0f, 1f)
		return Pair((fx * (ControllerState.TOUCHPAD_WIDTH.toInt() - 1)).toInt().toUShort(),
			(fy * (ControllerState.TOUCHPAD_HEIGHT.toInt() - 1)).toInt().toUShort())
	}

	private fun pointerDown(id: Int, x: Float, y: Float)
	{
		val now = SystemClock.uptimeMillis()
		val k = keyAt(x, y)
		if(k != null)
		{
			keyPointers[id] = k
			k.downs++
			if(k.downs == 1)
			{
				if(k.trigger != 0)
					triggerStart(k, y)
				feelDown(k)
			}
			return
		}
		val pad = dpad
		if(pad != null && dpadPointer < 0 && hypot(x - pad.cx, y - pad.cy) <= pad.hw * 1.15f)
		{
			dpadPointer = id
			dpadMask = dpadMaskAt(x, y)
			AnyPlayHaptics.tap(context, AnyPlayHaptics.Tap.TICK)
			return
		}
		val tp = touchpad
		if(tp != null && touchpadPointer < 0 && tp.bounds.contains(x, y))
		{
			touchpadPointer = id
			touchpadDownAt = now
			touchpadDownX = x
			touchpadDownY = y
			val p = touchpadPos(x, y)
			touchpadTouchId = state.startTouch(p.first, p.second)
			return
		}
		// ближчий стік, у зоні якого дотик
		val s = sticks.filter { it.item != null && it.pointer < 0 && it.zone.contains(x, y) }
			.minByOrNull { hypot(x - it.item!!.cx, y - it.item!!.cy) } ?: return
		s.pointer = id
		// горизонтально стік з'являється там, де поставили палець; вертикально — стоїть на місці
		if(landscape) { s.cx = x; s.cy = y }
		else { val it = s.item!!; s.cx = it.cx; s.cy = it.cy; moveStick(s, x, y) }
		s.click = now - s.lastUp < 300
		s.edge = false
		if(s.click)
			AnyPlayHaptics.tap(context, AnyPlayHaptics.Tap.HEAVY)
	}

	private fun pointerMove(id: Int, x: Float, y: Float)
	{
		val held = keyPointers[id]
		if(held != null)
		{
			// аналоговий курок: палець тягне його вниз, на сусідні кнопки не перескакує
			if(held.trigger != 0 && analog)
			{
				triggerMove(held, y)
				return
			}
			// палець з'їхав на сусідню кнопку (наприклад з ✕ на ○) — перемикаємо без відривання
			val k = keyAt(x, y)
			if(k != null && k !== held && held.glyph != G_MENU && k.glyph != G_MENU)
			{
				held.downs = max(0, held.downs - 1)
				if(held.downs == 0)
					feelUp(held)
				keyPointers[id] = k
				k.downs++
				if(k.downs == 1)
				{
					if(k.trigger != 0)
						triggerStart(k, y)
					feelDown(k)
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
					AnyPlayHaptics.tap(context, AnyPlayHaptics.Tap.TICK)
			}
			return
		}
		if(id == touchpadPointer)
		{
			val p = touchpadPos(x, y)
			touchpadTouchId?.let { state.setTouchPos(it, p.first, p.second) }
			return
		}
		for(s in sticks)
			if(id == s.pointer)
				moveStick(s, x, y)
	}

	private fun pointerUp(id: Int, x: Float, y: Float, cancelled: Boolean)
	{
		val now = SystemClock.uptimeMillis()
		val k = keyPointers.remove(id)
		if(k != null)
		{
			k.downs = max(0, k.downs - 1)
			if(k.downs == 0)
			{
				feelUp(k)
				k.level = 1f
			}
			if(k.glyph == G_MENU && !cancelled)
			{
				tmp.set(k.rect)
				tmp.inset(-k.rect.width() * 0.3f, -k.rect.height() * 0.3f)
				if(tmp.contains(x, y))
					post { menuCallback?.invoke() }
			}
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
				AnyPlayHaptics.tap(context, AnyPlayHaptics.Tap.HEAVY)
				removeCallbacks(touchpadRelease)
				postDelayed(touchpadRelease, 110)
			}
			return
		}
		for(s in sticks)
		{
			if(id == s.pointer)
			{
				s.pointer = -1
				s.dx = 0f
				s.dy = 0f
				s.click = false
				s.item?.let { s.cx = it.cx; s.cy = it.cy }
				s.lastUp = now
			}
		}
	}

	override fun onTouchEvent(event: MotionEvent): Boolean
	{
		if(editMode)
		{
			editTouch(event)
			return true
		}
		when(event.actionMasked)
		{
			MotionEvent.ACTION_DOWN, MotionEvent.ACTION_POINTER_DOWN ->
			{
				val i = event.actionIndex
				val id = event.getPointerId(i)
				removeCallbacks(hideRunnable)
				if(!shown && autoHideSec > 0)
				{
					// кнопки були сховані: перший дотик лише показує їх
					swallowed.add(id)
					reveal()
				}
				else
				{
					// 123, режим «ховати одразу»: кнопки стоять на своїх місцях, тож дотик і показує їх, і одразу
					// натискає (інакше кожне перше натискання губилося б)
					if(!shown)
						reveal()
					pointerDown(id, event.getX(i), event.getY(i))
				}
			}
			MotionEvent.ACTION_MOVE ->
				for(i in 0 until event.pointerCount)
				{
					val id = event.getPointerId(i)
					if(id !in swallowed)
						pointerMove(id, event.getX(i), event.getY(i))
				}
			MotionEvent.ACTION_UP, MotionEvent.ACTION_POINTER_UP ->
			{
				val i = event.actionIndex
				val id = event.getPointerId(i)
				if(!swallowed.remove(id))
					pointerUp(id, event.getX(i), event.getY(i), false)
				if(event.actionMasked == MotionEvent.ACTION_UP)
				{
					swallowed.clear()
					scheduleHide()
				}
			}
			MotionEvent.ACTION_CANCEL ->
			{
				swallowed.clear()
				for(i in 0 until event.pointerCount)
					pointerUp(event.getPointerId(i), event.getX(i), event.getY(i), true)
				scheduleHide()
			}
		}
		pushState()
		invalidate()
		return true
	}

	private fun quantize(f: Float): Short = (Short.MAX_VALUE * f.coerceIn(-1f, 1f)).toInt().toShort()

	private fun pushState()
	{
		var mask = dpadMask
		var l2 = 0f
		var r2 = 0f
		for(k in keys)
		{
			if(!k.pressed)
				continue
			mask = mask or k.bits
			if(k.trigger == TRIGGER_L2) l2 = max(l2, k.level)
			if(k.trigger == TRIGGER_R2) r2 = max(r2, k.level)
		}
		if(leftStick.click) mask = mask or ControllerState.BUTTON_L3
		if(rightStick.click) mask = mask or ControllerState.BUTTON_R3
		if(touchpadPressed) mask = mask or ControllerState.BUTTON_TOUCHPAD
		state.buttons = mask
		state.l2State = (l2 * 255).roundToInt().coerceIn(0, 255).toUByte()
		state.r2State = (r2 * 255).roundToInt().coerceIn(0, 255).toUByte()
		state.leftX = quantize(leftStick.dx)
		state.leftY = quantize(leftStick.dy)
		state.rightX = quantize(rightStick.dx)
		state.rightY = quantize(rightStick.dy)
		// копія з окремими об'єктами дотиків: стан читає інший потік
		stateChangedCallback?.invoke(state.copy(touches = state.touches.map { it.copy() }.toTypedArray()))
	}

	private fun releasePointers()
	{
		keyPointers.clear()
		swallowed.clear()
		keys.forEach { it.downs = 0; it.level = 1f }
		dpadPointer = -1
		dpadMask = 0U
		touchpadPointer = -1
		touchpadTouchId?.let { state.stopTouch(it) }
		touchpadTouchId = null
		touchpadPressed = false
		removeCallbacks(touchpadRelease)
		for(s in sticks)
		{
			s.pointer = -1; s.dx = 0f; s.dy = 0f; s.click = false; s.edge = false
			s.item?.let { s.cx = it.cx; s.cy = it.cy }
		}
	}

	/** Відпустити все (екран згорнули, кнопки сховали, відкрили редактор) */
	fun releaseAll()
	{
		releasePointers()
		pushState()
		invalidate()
	}

	// ── автоховання ──
	private var shown = true
	private val hideRunnable = Runnable { hideNow() }

	private fun anyPointer() = keyPointers.isNotEmpty() || dpadPointer >= 0 || touchpadPointer >= 0 || sticks.any { it.pointer >= 0 }

	/** Без дотиків N секунд — сховати (лише горизонтально: вертикально кнопки не закривають гру) */
	private fun scheduleHide()
	{
		removeCallbacks(hideRunnable)
		if(!landscape || editMode || autoHideSec == 0)
			return
		if(autoHideSec < 0)
		{
			// 123: «ховати одразу» — щойно жоден палець не торкається екрана (коротка пауза, щоб кнопки не блимали
			// між швидкими натисканнями)
			if(!anyPointer())
				postDelayed(hideRunnable, PadLayout.INSTANT_HIDE_MS)
		}
		else
			postDelayed(hideRunnable, autoHideSec * 1000L)
	}

	private fun hideNow()
	{
		if(editMode || anyPointer() || !shown || autoHideSec == 0 || !landscape)
			return
		shown = false
		animate().cancel()
		// 125: м'яке згасання, повільне наприкінці (було 0,18 с різко)
		animate().alpha(0f).setDuration(550).setInterpolator(android.view.animation.AccelerateDecelerateInterpolator()).start()
	}

	/** Показати кнопки (дотик до екрана, відкрили редактор) */
	fun reveal()
	{
		if(!shown)
		{
			shown = true
			animate().cancel()
			// з'являються швидко, щоб натискання одразу було видно
			animate().alpha(1f).setDuration(110).setInterpolator(android.view.animation.DecelerateInterpolator()).start()
		}
		scheduleHide()
	}

	/** Натиснули справжній геймпад: кнопки на екрані одразу ховаються, доки не торкнуться екрана */
	fun physicalInput()
	{
		if(shown && landscape && !editMode && autoHideSec != 0 && !anyPointer())
		{
			removeCallbacks(hideRunnable)
			hideNow()
		}
	}

	override fun onDetachedFromWindow()
	{
		super.onDetachedFromWindow()
		removeCallbacks(hideRunnable)
		removeCallbacks(touchpadRelease)
	}

	// ── редактор розташування ──
	var editMode = false
		set(value)
		{
			if(field == value)
				return
			field = value
			releaseAll()
			selectedId = null
			if(!value)
			{
				// вийшли з редактора без збереження: повертаємо збережене
				profileLand = null
				relayout()
			}
			reveal()
			invalidate()
		}

	var selectedId: String? = null
		private set

	private var dragPointer = -1
	private var dragDX = 0f
	private var dragDY = 0f
	private var pinching = false
	private var pinchStart = 0f
	private var pinchScale = 1f

	val isLandscape get() = landscape

	private fun selectedItem() = items.firstOrNull { it.el.id == selectedId }

	private fun itemAt(x: Float, y: Float): Item?
	{
		var best: Item? = null
		var bestD = Float.MAX_VALUE
		val pad = dp(10f)
		for(it in items)
		{
			if(x < it.bounds.left - pad || x > it.bounds.right + pad || y < it.bounds.top - pad || y > it.bounds.bottom + pad)
				continue
			val d = hypot(x - it.cx, y - it.cy)
			if(d < bestD) { bestD = d; best = it }
		}
		return best
	}

	private fun spacing(e: MotionEvent): Float = if(e.pointerCount < 2) 0f else hypot(e.getX(0) - e.getX(1), e.getY(0) - e.getY(1))

	private fun editTouch(e: MotionEvent)
	{
		when(e.actionMasked)
		{
			MotionEvent.ACTION_DOWN ->
			{
				val x = e.x
				val y = e.y
				val it = itemAt(x, y)
				selectedId = it?.el?.id
				pinching = false
				if(it != null)
				{
					dragPointer = e.getPointerId(0)
					dragDX = x - it.cx
					dragDY = y - it.cy
					AnyPlayHaptics.tap(context, AnyPlayHaptics.Tap.TICK)
					editDragListener?.invoke(true)
				}
				else
					dragPointer = -1
				editListener?.invoke()
			}
			MotionEvent.ACTION_POINTER_DOWN ->
			{
				val sel = selectedItem()
				if(sel != null && e.pointerCount >= 2)
				{
					pinching = true
					pinchStart = spacing(e)
					pinchScale = sel.el.scale
				}
			}
			MotionEvent.ACTION_MOVE ->
			{
				val sel = selectedItem() ?: return
				if(pinching)
				{
					val d = spacing(e)
					if(e.pointerCount >= 2 && pinchStart > dp(12f))
					{
						sel.el.scale = (pinchScale * d / pinchStart).coerceIn(PadLayout.MIN_SCALE, PadLayout.MAX_SCALE)
						relayout()
						editListener?.invoke()
					}
				}
				else
				{
					val i = e.findPointerIndex(dragPointer)
					if(i >= 0)
						moveTo(sel, e.getX(i) - dragDX, e.getY(i) - dragDY)
				}
			}
			MotionEvent.ACTION_POINTER_UP ->
			{
				// після зміни розміру двома пальцями кнопка не стрибає за пальцем, що лишився
				if(pinching)
				{
					pinching = false
					dragPointer = -1
				}
				else if(e.getPointerId(e.actionIndex) == dragPointer)
					dragPointer = -1
			}
			MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL ->
			{
				dragPointer = -1
				pinching = false
				guideX = Float.NaN
				guideY = Float.NaN
				editDragListener?.invoke(false)
			}
		}
		invalidate()
	}

	// 125: прилипання до центру екрана й до інших кнопок (з тіком вібрації), щоб розкладка була рівною
	private var guideX = Float.NaN
	private var guideY = Float.NaN

	private fun moveTo(it: Item, cx0: Float, cy0: Float)
	{
		if(area.width() <= 0f || area.height() <= 0f)
			return
		val snap = dp(7f)
		var cx = cx0
		var cy = cy0
		var gx = Float.NaN
		var gy = Float.NaN
		if(abs(cx - area.centerX()) < snap) { cx = area.centerX(); gx = cx }
		for(o in items)
		{
			if(o === it) continue
			if(gx.isNaN() && abs(cx - o.cx) < snap) { cx = o.cx; gx = cx }
			if(gy.isNaN() && abs(cy - o.cy) < snap) { cy = o.cy; gy = cy }
			// дзеркально до кнопки з іншого боку (L2 ↔ R2, стік ↔ стік)
			val mx = area.left + area.right - o.cx
			if(gx.isNaN() && abs(cx - mx) < snap && abs(cy - o.cy) < snap * 3) { cx = mx; gx = cx }
		}
		val snapped = (!gx.isNaN() && guideX.isNaN()) || (!gy.isNaN() && guideY.isNaN())
		guideX = gx
		guideY = gy
		if(snapped)
			AnyPlayHaptics.tap(context, AnyPlayHaptics.Tap.DETENT)
		it.el.x = ((cx - area.left) / area.width()).coerceIn(0f, 1f)
		it.el.y = ((cy - area.top) / area.height()).coerceIn(0f, 1f)
		relayout()
	}

	/** Назва вибраної кнопки для редактора (null — нічого не вибрано) */
	fun selectedTitle(): String?
	{
		val el = selectedItem()?.el ?: return null
		return if(el.extra) el.label else PadLayout.TITLES[el.id]
	}

	fun selectedIsExtra() = selectedItem()?.el?.extra == true
	fun selectedIsMenu() = selectedId == "menu"

	/** Розмір вибраної кнопки, а якщо нічого не вибрано — усіх разом */
	fun currentScale(): Float = selectedItem()?.el?.scale ?: profile.scale

	fun setScale(s: Float)
	{
		val v = s.coerceIn(PadLayout.MIN_SCALE, PadLayout.MAX_SCALE)
		val sel = selectedItem()
		if(sel != null) sel.el.scale = v else profile.scale = v
		relayout()
		invalidate()
	}

	fun setOpacityPreview(o: Float)
	{
		opacity = o.coerceIn(0.2f, 1f)
		invalidate()
	}

	/** Прибрати вибрану: додаткову — видалити, стандартну — сховати (меню «⋯» прибрати не можна) */
	fun removeSelected()
	{
		val el = selectedItem()?.el ?: return
		if(el.id == "menu")
			return
		if(el.extra) profile.elements.remove(el) else el.on = false
		selectedId = null
		rebuild()
		editListener?.invoke()
	}

	fun setElementOn(id: String, on: Boolean)
	{
		val el = profile.find(id) ?: return
		if(el.on == on || id == "menu")
			return
		el.on = on
		if(!on && selectedId == id)
			selectedId = null
		rebuild()
	}

	fun extras(): List<PadElement> = profile.elements.filter { it.extra }

	/** Додати додаткову кнопку посередині (гравець перетягне її куди треба) */
	fun addExtra(id: String, label: String, button: String)
	{
		if(profile.find(id) != null)
			return
		val n = extras().size
		profile.elements.add(PadElement(id, 0.5f + ((n % 3) - 1) * 0.08f, 0.42f + (n / 3 % 3) * 0.12f, 1f, true, label.take(14), button))
		selectedId = id
		rebuild()
		editListener?.invoke()
	}

	fun removeElement(id: String)
	{
		val el = profile.find(id) ?: return
		if(!el.extra)
			return
		profile.elements.remove(el)
		if(selectedId == id)
			selectedId = null
		rebuild()
	}

	fun saveLayout()
	{
		profileLand?.let { PadLayout.save(context, it, profile) }
	}

	/** Типове розташування для поточної орієнтації (зберігається кнопкою «Готово») */
	fun resetLayout()
	{
		profile = PadLayout.defaults(landscape)
		selectedId = null
		rebuild()
		editListener?.invoke()
	}
}
