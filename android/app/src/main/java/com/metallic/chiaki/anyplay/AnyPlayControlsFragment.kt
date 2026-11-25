// AnyPlay: екранний джойстик DualSense як джерело стану контролера для стріму.
package com.metallic.chiaki.anyplay

import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.lifecycle.Observer
import com.metallic.chiaki.R
import com.metallic.chiaki.touchcontrols.TouchControlsFragment

class AnyPlayControlsFragment: TouchControlsFragment()
{
	/** Сам геймпад. Фрагмент стоїть у розмітці тегом <fragment>, а той замінює id кореня фрагмента своїм
	 *  (R.id.controlsFragment). Тому геймпад лежить в обгортці й зберігає свій R.id.gamepadView — до 114
	 *  findViewById(R.id.gamepadView) повертав null, і кнопка меню «⋯» нічого не робила. */
	var pad: GamepadView? = null
		private set

	override fun onCreateView(inflater: LayoutInflater, container: ViewGroup?, savedInstanceState: Bundle?): View
	{
		val frame = FrameLayout(requireContext())
		val gamepad = GamepadView(requireContext()).apply { id = R.id.gamepadView }
		frame.addView(gamepad, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
		pad = gamepad
		return frame
	}

	override fun onViewCreated(view: View, savedInstanceState: Bundle?)
	{
		super.onViewCreated(view, savedInstanceState)
		val gamepad = pad ?: return
		gamepad.stateChangedCallback = { ownControllerState = it }
		onScreenControlsEnabled?.observe(viewLifecycleOwner, Observer {
			if(!it)
				gamepad.releaseAll()
			view.visibility = if(it) View.VISIBLE else View.GONE
		})
	}

	override fun onPause()
	{
		super.onPause()
		pad?.releaseAll()
	}

	override fun onDestroyView()
	{
		super.onDestroyView()
		pad = null
	}
}
