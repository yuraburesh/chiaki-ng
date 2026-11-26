// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.session

import android.view.KeyEvent
import com.metallic.chiaki.lib.ControllerState
import org.junit.Assert.*
import org.junit.Test

/** AnyPlay 118.1: шлях вводу на Android — що саме йде в гру з геймпада, датчиків і екранних кнопок */
class StreamInputTest
{
	private val idle get() = ControllerState()

	@Test
	fun screenButtonsReachGame()
	{
		// екранний геймпад (✕ + лівий стік) і шар «лише тачпад» (порожній) — як у StreamActivity
		val pad = ControllerState(buttons = ControllerState.BUTTON_CROSS, leftX = 20000, leftY = -32767)
		val layers = listOf(pad, idle).reduce { a, b -> a or b }
		val out = StreamInput.merge(idle, idle, idle, layers, false)
		assertEquals(ControllerState.BUTTON_CROSS, out.buttons)
		assertEquals(20000, out.leftX.toInt())
		assertEquals(-32767, out.leftY.toInt())
	}

	@Test
	fun gamepadAndScreenTogether()
	{
		val key = ControllerState(buttons = ControllerState.BUTTON_R1)
		val motion = ControllerState(rightX = -12000, r2State = 200U)
		val touch = ControllerState(buttons = ControllerState.BUTTON_BOX)
		val out = StreamInput.merge(idle, key, motion, touch, false)
		assertEquals(ControllerState.BUTTON_R1 or ControllerState.BUTTON_BOX, out.buttons)
		assertEquals(-12000, out.rightX.toInt())
		assertEquals(200, out.r2State.toInt())
	}

	@Test
	fun analogTriggerWinsOverKey()
	{
		val key = ControllerState(l2State = 255U)
		val motion = ControllerState(l2State = 90U)
		assertEquals(90, StreamInput.merge(idle, key, motion, idle, false).l2State.toInt())
		// лише клавіша (цифровий курок) — повне натискання
		assertEquals(255, StreamInput.merge(idle, key, idle, idle, false).l2State.toInt())
	}

	@Test
	fun screenTouchpadKeepsTouch()
	{
		val touch = ControllerState()
		val id = touch.startTouch(100U, 200U)
		assertNotNull(id)
		val out = StreamInput.merge(idle, idle, idle, touch, false)
		assertEquals(100, out.touches[0].x.toInt())
		assertTrue(out.touches[0].id >= 0)
	}

	@Test
	fun rotationFlipsOnlyMotionSensors()
	{
		val sensor = ControllerState(gyroX = 1f, accelX = 0.5f)
		val touch = ControllerState(buttons = ControllerState.BUTTON_CROSS)
		val out = StreamInput.merge(sensor, idle, idle, touch, true)
		assertEquals(-1f, out.gyroX, 0f)
		assertEquals(-0.5f, out.accelX, 0f)
		assertEquals(ControllerState.BUTTON_CROSS, out.buttons)
	}

	@Test
	fun triggersFromBrakeAndGas()
	{
		assertEquals(255, StreamInput.triggerValue(0f, 1f).toInt())
		assertEquals(127, StreamInput.triggerValue(0.5f, 0f).toInt())
		assertEquals(0, StreamInput.triggerValue(-0.2f, 0f).toInt())
		assertEquals(255, StreamInput.triggerValue(1.4f, 0f).toInt())
	}

	@Test
	fun dpadKeys()
	{
		assertEquals(ControllerState.BUTTON_DPAD_UP, StreamInput.dpadKeyMask(KeyEvent.KEYCODE_DPAD_UP))
		assertEquals(ControllerState.BUTTON_DPAD_LEFT, StreamInput.dpadKeyMask(KeyEvent.KEYCODE_DPAD_LEFT))
		assertEquals(0U, StreamInput.dpadKeyMask(KeyEvent.KEYCODE_BUTTON_A))
	}

	@Test
	fun idleStaysIdle()
	{
		val out = StreamInput.merge(idle, idle, idle, idle, false)
		assertEquals(0U, out.buttons)
		assertEquals(0, out.leftX.toInt())
		assertEquals(0, out.l2State.toInt())
	}
}
