// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.touchcontrols

import android.content.Context
import com.metallic.chiaki.anyplay.AnyPlayHaptics

/** AnyPlay 125: відгук дотику йде через AnyPlayHaptics (сила з налаштування «Вібрація кнопок») */
class ButtonHaptics(val context: Context)
{
	fun trigger(harder: Boolean = false) = AnyPlayHaptics.tap(context, if(harder) AnyPlayHaptics.Tap.HEAVY else AnyPlayHaptics.Tap.UI)
}
