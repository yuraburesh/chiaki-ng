package com.metallic.chiaki.session

import android.content.Context
import android.hardware.*
import android.view.*
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.OnLifecycleEvent
import com.metallic.chiaki.common.Preferences
import com.metallic.chiaki.lib.ControllerState

class StreamInput(val context: Context, val preferences: Preferences)
{
	var controllerStateChangedCallback: ((ControllerState) -> Unit)? = null

	companion object
	{
		/**
		 * Стан, що йде в гру: датчики, кнопки й осі справжнього геймпада, екранні кнопки (шари вже об'єднані).
		 * Окремою чистою функцією, щоб її можна було перевірити тестом без телефона.
		 */
		fun merge(sensor: ControllerState, key: ControllerState, motion: ControllerState, touch: ControllerState, rotated90: Boolean): ControllerState
		{
			val controllerState = sensor or key or motion
			if(rotated90)
			{
				controllerState.accelX *= -1.0f
				controllerState.accelZ *= -1.0f
				controllerState.gyroX *= -1.0f
				controllerState.gyroZ *= -1.0f
				controllerState.orientX *= -1.0f
				controllerState.orientZ *= -1.0f
			}
			// prioritize motion controller's l2 and r2 over key
			// (some controllers send only key, others both but key earlier than full press)
			if(motion.l2State > 0U)
				controllerState.l2State = motion.l2State
			if(motion.r2State > 0U)
				controllerState.r2State = motion.r2State
			return controllerState or touch
		}

		/** Курок 0..1 → 0..255. AnyPlay 118.1: частина геймпадів (Xbox, деякі 8BitDo) шле курки як «гальмо/газ» */
		fun triggerValue(trigger: Float, alt: Float): UByte =
			(maxOf(trigger, alt).coerceIn(0f, 1f) * UByte.MAX_VALUE.toFloat()).toUInt().toUByte()

		/** Кнопки хрестовини з клавіш (KEYCODE_DPAD_*): частина геймпадів шле хрестовину клавішами, а не віссю HAT */
		fun dpadKeyMask(keyCode: Int): UInt = when(keyCode)
		{
			KeyEvent.KEYCODE_DPAD_LEFT -> ControllerState.BUTTON_DPAD_LEFT
			KeyEvent.KEYCODE_DPAD_RIGHT -> ControllerState.BUTTON_DPAD_RIGHT
			KeyEvent.KEYCODE_DPAD_UP -> ControllerState.BUTTON_DPAD_UP
			KeyEvent.KEYCODE_DPAD_DOWN -> ControllerState.BUTTON_DPAD_DOWN
			else -> 0U
		}
	}

	// AnyPlay 121: поворот екрана — запам'ятований. До цього він запитувався в системи (виклик через Binder) на КОЖНУ
	// подію датчиків руху: 3 датчики по 250 разів на секунду, і на Galaxy S7 власника головний потік тонув у цих
	// викликах — екран завантаження завмирав («Крок 1/3 0:12»), далі чорний екран і система закривала застосунок
	// (журнал 121: головний потік стоїть у StreamInput.getControllerState → getDefaultDisplay)
	@Volatile private var rotated90 = false

	private fun readRotation()
	{
		try
		{
			val windowManager = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
			@Suppress("DEPRECATION")
			rotated90 = windowManager.defaultDisplay.rotation == Surface.ROTATION_90
		}
		catch(e: Exception) {}
	}

	private val displayListener = object: android.hardware.display.DisplayManager.DisplayListener {
		override fun onDisplayAdded(displayId: Int) {}
		override fun onDisplayRemoved(displayId: Int) {}
		override fun onDisplayChanged(displayId: Int) { readRotation() }
	}

	init
	{
		readRotation()
		try { (context.getSystemService(Context.DISPLAY_SERVICE) as android.hardware.display.DisplayManager).registerDisplayListener(displayListener, null) }
		catch(e: Exception) {}
	}

	fun release()
	{
		try { (context.getSystemService(Context.DISPLAY_SERVICE) as android.hardware.display.DisplayManager).unregisterDisplayListener(displayListener) }
		catch(e: Exception) {}
	}

	val controllerState: ControllerState get() =
		merge(sensorControllerState, keyControllerState, motionControllerState, touchControllerState, rotated90)

	// AnyPlay 121: стан з датчиків руху шлемо в гру не частіше ніж раз на 8 мс (кнопки й стіки — одразу)
	private var sensorSentAt = 0L

	private val sensorControllerState = ControllerState() // from Motion Sensors
	private val keyControllerState = ControllerState() // from KeyEvents
	private val motionControllerState = ControllerState() // from MotionEvents
	var touchControllerState = ControllerState()
		set(value)
		{
			field = value
			controllerStateUpdated()
		}

	private val swapCrossMoon = preferences.swapCrossMoon

	private val sensorEventListener = object: SensorEventListener {
		override fun onSensorChanged(event: SensorEvent)
		{
			when(event.sensor.type)
			{
				Sensor.TYPE_ACCELEROMETER -> {
					sensorControllerState.accelX = event.values[1] / SensorManager.GRAVITY_EARTH
					sensorControllerState.accelY = event.values[2] / SensorManager.GRAVITY_EARTH
					sensorControllerState.accelZ = event.values[0] / SensorManager.GRAVITY_EARTH
				}
				Sensor.TYPE_GYROSCOPE -> {
					sensorControllerState.gyroX = event.values[1]
					sensorControllerState.gyroY = event.values[2]
					sensorControllerState.gyroZ = event.values[0]
				}
				Sensor.TYPE_ROTATION_VECTOR -> {
					val q = floatArrayOf(0f, 0f, 0f, 0f)
					SensorManager.getQuaternionFromVector(q, event.values)
					sensorControllerState.orientX = q[2]
					sensorControllerState.orientY = q[3]
					sensorControllerState.orientZ = q[1]
					sensorControllerState.orientW = q[0]
				}
				else -> return
			}
			val now = android.os.SystemClock.uptimeMillis()
			if(now - sensorSentAt < 8)
				return
			sensorSentAt = now
			controllerStateUpdated()
		}

		override fun onAccuracyChanged(sensor: Sensor, accuracy: Int) {}
	}

	private val motionLifecycleObserver = object: LifecycleObserver {
		@OnLifecycleEvent(Lifecycle.Event.ON_RESUME)
		fun onResume()
		{
			// 121: 100 разів на секунду (було 250): для руху в грі досить, а старий телефон не захлинається
			val samplingPeriodUs = 10000
			readRotation()
			val sensorManager = context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
			listOfNotNull(
				sensorManager.getDefaultSensor(Sensor.TYPE_ACCELEROMETER),
				sensorManager.getDefaultSensor(Sensor.TYPE_GYROSCOPE),
				sensorManager.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR)
			).forEach {
				sensorManager.registerListener(sensorEventListener, it, samplingPeriodUs)
			}
		}

		@OnLifecycleEvent(Lifecycle.Event.ON_PAUSE)
		fun onPause()
		{
			val sensorManager = context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
			sensorManager.unregisterListener(sensorEventListener)
		}
	}

	fun observe(lifecycleOwner: LifecycleOwner)
	{
		if(preferences.motionEnabled)
			lifecycleOwner.lifecycle.addObserver(motionLifecycleObserver)
	}

	private fun controllerStateUpdated()
	{
		controllerStateChangedCallback?.let { it(controllerState) }
	}

	fun dispatchKeyEvent(event: KeyEvent): Boolean
	{
		//Log.i("StreamSession", "key event $event")
		if(event.action != KeyEvent.ACTION_DOWN && event.action != KeyEvent.ACTION_UP)
			return false

		// AnyPlay 118.1: хрестовина клавішами (лише з геймпада: стрілки клавіатури телефона/планшета не чіпаємо)
		val dpad = dpadKeyMask(event.keyCode)
		val fromPad = event.device?.let { d -> !d.isVirtual &&
			(d.sources and InputDevice.SOURCE_GAMEPAD == InputDevice.SOURCE_GAMEPAD || d.sources and InputDevice.SOURCE_JOYSTICK == InputDevice.SOURCE_JOYSTICK) } == true
		if(dpad != 0U && fromPad)
		{
			keyControllerState.buttons = if(event.action == KeyEvent.ACTION_DOWN) keyControllerState.buttons or dpad
				else keyControllerState.buttons and dpad.inv()
			controllerStateUpdated()
			return true
		}

		// AnyPlay 125: DualSense / DualShock 4 через загальний драйвер — кнопки за порядком HID, ставимо на свої місця
		if(fromPad && com.metallic.chiaki.anyplay.AnyPlayGamepads.genericSony(event.device))
		{
			val g = com.metallic.chiaki.anyplay.AnyPlayGamepads.genericKey(event.keyCode)
			if(g != null)
			{
				val down = event.action == KeyEvent.ACTION_DOWN
				when
				{
					g == -1L -> keyControllerState.l2State = if(down) UByte.MAX_VALUE else 0U
					g == -2L -> keyControllerState.r2State = if(down) UByte.MAX_VALUE else 0U
					g > 0L -> keyControllerState.buttons = if(down) keyControllerState.buttons or g.toUInt() else keyControllerState.buttons and g.toUInt().inv()
				}
				controllerStateUpdated()
				return true
			}
		}

		when(event.keyCode)
		{
			KeyEvent.KEYCODE_BUTTON_L2 -> {
				keyControllerState.l2State = if(event.action == KeyEvent.ACTION_DOWN) UByte.MAX_VALUE else 0U
				controllerStateUpdated()   // 118.1: раніше цифровий курок не відправлявся, доки не зміниться щось інше
				return true
			}
			KeyEvent.KEYCODE_BUTTON_R2 -> {
				keyControllerState.r2State = if(event.action == KeyEvent.ACTION_DOWN) UByte.MAX_VALUE else 0U
				controllerStateUpdated()
				return true
			}
		}

		val buttonMask: UInt = when(event.keyCode)
		{
			// dpad handled by MotionEvents
			//KeyEvent.KEYCODE_DPAD_LEFT -> ControllerState.BUTTON_DPAD_LEFT
			//KeyEvent.KEYCODE_DPAD_RIGHT -> ControllerState.BUTTON_DPAD_RIGHT
			//KeyEvent.KEYCODE_DPAD_UP -> ControllerState.BUTTON_DPAD_UP
			//KeyEvent.KEYCODE_DPAD_DOWN -> ControllerState.BUTTON_DPAD_DOWN
			KeyEvent.KEYCODE_BUTTON_A -> if(swapCrossMoon) ControllerState.BUTTON_MOON else ControllerState.BUTTON_CROSS
			KeyEvent.KEYCODE_BUTTON_B -> if(swapCrossMoon) ControllerState.BUTTON_CROSS else ControllerState.BUTTON_MOON
			KeyEvent.KEYCODE_BUTTON_X -> if(swapCrossMoon) ControllerState.BUTTON_PYRAMID else ControllerState.BUTTON_BOX
			KeyEvent.KEYCODE_BUTTON_Y -> if(swapCrossMoon) ControllerState.BUTTON_BOX else ControllerState.BUTTON_PYRAMID
			KeyEvent.KEYCODE_BUTTON_L1 -> ControllerState.BUTTON_L1
			KeyEvent.KEYCODE_BUTTON_R1 -> ControllerState.BUTTON_R1
			KeyEvent.KEYCODE_BUTTON_THUMBL -> ControllerState.BUTTON_L3
			KeyEvent.KEYCODE_BUTTON_THUMBR -> ControllerState.BUTTON_R3
			KeyEvent.KEYCODE_BUTTON_SELECT -> ControllerState.BUTTON_SHARE
			KeyEvent.KEYCODE_BUTTON_START -> ControllerState.BUTTON_OPTIONS
			KeyEvent.KEYCODE_BUTTON_C -> ControllerState.BUTTON_PS
			KeyEvent.KEYCODE_BUTTON_MODE -> ControllerState.BUTTON_PS
			else -> return false
		}

		keyControllerState.buttons = keyControllerState.buttons.run {
			when(event.action)
			{
				KeyEvent.ACTION_DOWN -> this or buttonMask
				KeyEvent.ACTION_UP -> this and buttonMask.inv()
				else -> this
			}
		}

		controllerStateUpdated()
		return true
	}

	fun onGenericMotionEvent(event: MotionEvent): Boolean
	{
		if(event.source and InputDevice.SOURCE_CLASS_JOYSTICK != InputDevice.SOURCE_CLASS_JOYSTICK)
			return false
		fun Float.signedAxis() = (this * Short.MAX_VALUE).toInt().toShort()
		// AnyPlay 138: мертва зона й чутливість стіків з налаштувань
		val (lx, ly) = com.metallic.chiaki.anyplay.AnyPlaySticks.shape(event.getAxisValue(MotionEvent.AXIS_X), event.getAxisValue(MotionEvent.AXIS_Y))
		val (rx, ry) = com.metallic.chiaki.anyplay.AnyPlaySticks.shape(event.getAxisValue(MotionEvent.AXIS_Z), event.getAxisValue(MotionEvent.AXIS_RZ))
		motionControllerState.leftX = lx.signedAxis()
		motionControllerState.leftY = ly.signedAxis()
		motionControllerState.rightX = rx.signedAxis()
		motionControllerState.rightY = ry.signedAxis()
		if(com.metallic.chiaki.anyplay.AnyPlayGamepads.genericSony(event.device))
		{
			// загальний драйвер Sony: курки на осях RX/RY (від мінімуму до максимуму), правий стік на Z/RZ
			motionControllerState.l2State = triggerValue(com.metallic.chiaki.anyplay.AnyPlayGamepads.genericTrigger(event, MotionEvent.AXIS_RX), 0f)
			motionControllerState.r2State = triggerValue(com.metallic.chiaki.anyplay.AnyPlayGamepads.genericTrigger(event, MotionEvent.AXIS_RY), 0f)
		}
		else
		{
			motionControllerState.l2State = triggerValue(event.getAxisValue(MotionEvent.AXIS_LTRIGGER), event.getAxisValue(MotionEvent.AXIS_BRAKE))
			motionControllerState.r2State = triggerValue(event.getAxisValue(MotionEvent.AXIS_RTRIGGER), event.getAxisValue(MotionEvent.AXIS_GAS))
		}
		motionControllerState.buttons = motionControllerState.buttons.let {
			val dpadX = event.getAxisValue(MotionEvent.AXIS_HAT_X)
			val dpadY = event.getAxisValue(MotionEvent.AXIS_HAT_Y)
			val dpadButtons =
				(if(dpadX > 0.5f) ControllerState.BUTTON_DPAD_RIGHT else 0U) or
						(if(dpadX < -0.5f) ControllerState.BUTTON_DPAD_LEFT else 0U) or
						(if(dpadY > 0.5f) ControllerState.BUTTON_DPAD_DOWN else 0U) or
						(if(dpadY < -0.5f) ControllerState.BUTTON_DPAD_UP else 0U)
			it and (ControllerState.BUTTON_DPAD_RIGHT or
					ControllerState.BUTTON_DPAD_LEFT or
					ControllerState.BUTTON_DPAD_DOWN or
					ControllerState.BUTTON_DPAD_UP).inv() or
					dpadButtons
		}
		//Log.i("StreamSession", "motionEvent => $motionControllerState")
		controllerStateUpdated()
		return true
	}
}