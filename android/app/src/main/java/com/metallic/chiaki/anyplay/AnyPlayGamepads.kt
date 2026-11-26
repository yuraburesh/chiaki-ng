// AnyPlay 125: геймпади через Bluetooth. Android до 12 (і старі ядра) не має драйвера DualSense, а часто й DualShock 4:
// такий геймпад працює через загальний драйвер, і кнопки приходять просто за порядком у звіті HID —
// □ стає «A», ✕ стає «B», L1 стає «Y», курки й Create/Options зсуваються, PS читався як ○. Звідси «перемішані кнопки».
// Тут розпізнаємо такий геймпад Sony (курки на осях RX/RY замість LTRIGGER/RTRIGGER) і ставимо кнопки на свої місця.
package com.metallic.chiaki.anyplay

import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import com.metallic.chiaki.lib.ControllerState

object AnyPlayGamepads
{
	private const val SONY = 0x054C
	private val logged = HashSet<String>()
	private val generic = HashMap<Int, Boolean>()

	/** Геймпад Sony, що працює через загальний драйвер (кнопки за порядком HID) */
	fun genericSony(d: InputDevice?): Boolean
	{
		if(d == null) return false
		return generic.getOrPut(d.id) {
			val g = d.vendorId == SONY && d.getMotionRange(MotionEvent.AXIS_LTRIGGER) == null && d.getMotionRange(MotionEvent.AXIS_RX) != null
			describe(d, g)
			g
		}
	}

	/** Один раз на геймпад — у журнал: назва, коди, осі, чи є вібрація (щоб розібратися з незвичним геймпадом) */
	fun describe(d: InputDevice?, generic: Boolean? = null)
	{
		if(d == null || !logged.add(d.descriptor ?: d.name)) return
		val axes = d.motionRanges.joinToString(",") { MotionEvent.axisToString(it.axis).removePrefix("AXIS_") }
		val vib = try { d.vibrator?.hasVibrator() == true } catch(e: Exception) { false }
		AnyPlayDiag.i("Геймпад: «${d.name}» ${"%04x:%04x".format(d.vendorId, d.productId)}, осі $axes, вібрація ${if(vib) "є" else "немає"}"
			+ (if(generic == true) ", загальний драйвер: кнопки Sony переставлено на свої місця" else ""))
	}

	/** Що це за клавіша загального драйвера Sony: біти кнопки або курок (L2 = -1, R2 = -2), null — не наша */
	fun genericKey(keyCode: Int): Long? = when(keyCode)
	{
		KeyEvent.KEYCODE_BUTTON_A -> ControllerState.BUTTON_BOX.toLong()
		KeyEvent.KEYCODE_BUTTON_B -> ControllerState.BUTTON_CROSS.toLong()
		KeyEvent.KEYCODE_BUTTON_C -> ControllerState.BUTTON_MOON.toLong()
		KeyEvent.KEYCODE_BUTTON_X -> ControllerState.BUTTON_PYRAMID.toLong()
		KeyEvent.KEYCODE_BUTTON_Y -> ControllerState.BUTTON_L1.toLong()
		KeyEvent.KEYCODE_BUTTON_Z -> ControllerState.BUTTON_R1.toLong()
		KeyEvent.KEYCODE_BUTTON_L1 -> -1L
		KeyEvent.KEYCODE_BUTTON_R1 -> -2L
		KeyEvent.KEYCODE_BUTTON_L2 -> ControllerState.BUTTON_SHARE.toLong()
		KeyEvent.KEYCODE_BUTTON_R2 -> ControllerState.BUTTON_OPTIONS.toLong()
		KeyEvent.KEYCODE_BUTTON_SELECT -> ControllerState.BUTTON_L3.toLong()
		KeyEvent.KEYCODE_BUTTON_START -> ControllerState.BUTTON_R3.toLong()
		KeyEvent.KEYCODE_BUTTON_MODE -> ControllerState.BUTTON_PS.toLong()
		KeyEvent.KEYCODE_BUTTON_THUMBL -> ControllerState.BUTTON_TOUCHPAD.toLong()
		KeyEvent.KEYCODE_BUTTON_THUMBR -> 0L   // кнопка мікрофона: у гру не йде
		else -> null
	}

	/** Курок загального драйвера (вісь RX/RY від мінімуму до максимуму) → 0..1 */
	fun genericTrigger(e: MotionEvent, axis: Int): Float
	{
		val r = e.device?.getMotionRange(axis, e.source) ?: return 0f
		val span = r.max - r.min
		if(span <= 0f) return 0f
		return ((e.getAxisValue(axis) - r.min) / span).coerceIn(0f, 1f)
	}

	// ── віддача на сам геймпад ──
	@Volatile private var padVibrator: Vibrator? = null
	private var padId = -1

	/** Граємо цим геймпадом: вібрація гри піде й на нього (якщо драйвер телефона це вміє) */
	@Volatile var lastAt = 0L
		private set

	fun active(d: InputDevice?)
	{
		lastAt = android.os.SystemClock.uptimeMillis()
		if(d == null || d.id == padId) return
		padId = d.id
		val v = try { d.vibrator } catch(e: Exception) { null }
		padVibrator = if(v != null && v.hasVibrator()) v else null
		describe(d)
	}

	fun hasPadVibrator() = padVibrator != null

	/** Граємо геймпадом з моторчиками (останні 20 с): вібрація гри йде на нього, а не на телефон */
	fun rumbleToPad() = padVibrator != null && android.os.SystemClock.uptimeMillis() - lastAt < 20000

	/** Сила 0..1 на моторчики геймпада на len мс (0 — зупинити) */
	fun rumble(power: Float, len: Long)
	{
		val v = padVibrator ?: return
		try
		{
			if(power <= 0f) { v.cancel(); return }
			if(Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
				v.vibrate(VibrationEffect.createOneShot(len, (power.coerceIn(0f, 1f) * 255).toInt().coerceIn(1, 255)))
			else
				@Suppress("DEPRECATION") v.vibrate(len)
		}
		catch(e: Exception) {}
	}

	fun stop()
	{
		try { padVibrator?.cancel() } catch(e: Exception) {}
	}
}
