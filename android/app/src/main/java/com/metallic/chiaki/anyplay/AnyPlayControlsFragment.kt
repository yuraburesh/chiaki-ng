// AnyPlay: екранний джойстик DualSense як джерело стану контролера для стріму.
package com.metallic.chiaki.anyplay

import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import androidx.lifecycle.Observer
import com.metallic.chiaki.R
import com.metallic.chiaki.touchcontrols.TouchControlsFragment

class AnyPlayControlsFragment: TouchControlsFragment()
{
	override fun onCreateView(inflater: LayoutInflater, container: ViewGroup?, savedInstanceState: Bundle?): View =
		GamepadView(requireContext()).apply {
			id = R.id.gamepadView
			layoutParams = ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
		}

	override fun onViewCreated(view: View, savedInstanceState: Bundle?)
	{
		super.onViewCreated(view, savedInstanceState)
		val pad = view as GamepadView
		pad.stateChangedCallback = { ownControllerState = it }
		onScreenControlsEnabled?.observe(viewLifecycleOwner, Observer {
			if(!it)
				pad.releaseAll()
			view.visibility = if(it) View.VISIBLE else View.GONE
		})
	}

	override fun onPause()
	{
		super.onPause()
		(view as? GamepadView)?.releaseAll()
	}
}
