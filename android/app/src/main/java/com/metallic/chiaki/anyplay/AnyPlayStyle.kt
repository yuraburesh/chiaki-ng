// AnyPlay: новий дизайн у рідних вікнах програми. Кольори й шрифти ті самі, що на сторінці assets/anyplay/app.html
// і в AnyPlayStyle.qml на комп'ютері: вечірній градієнт, Oswald великими літерами для заголовків і кнопок, Inter для тексту,
// білі суцільні кнопки з ледь заокругленими кутами.
package com.metallic.chiaki.anyplay

import android.content.Context
import android.content.DialogInterface
import android.content.res.ColorStateList
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.style.ForegroundColorSpan
import android.text.style.RelativeSizeSpan
import android.util.TypedValue
import android.widget.TextView
import androidx.appcompat.app.AlertDialog
import com.google.android.material.button.MaterialButton
import com.google.android.material.dialog.MaterialAlertDialogBuilder

object AnyPlayStyle
{
	const val BG1 = 0xFF2B2740.toInt()
	const val BG2 = 0xFF4A3558.toInt()
	const val BG3 = 0xFF7A4A63.toInt()
	const val INK = 0xFFF5F3F7.toInt()      // основний текст, білі кнопки
	const val MUTE = 0xA6FFFFFF.toInt()     // другорядний текст
	const val EDGE = 0x40FFFFFF             // рамки другорядних кнопок
	const val DARK = 0xFF221D2E.toInt()     // текст на білих кнопках
	const val DIALOG = 0xF22A2639.toInt()   // вікна й панелі поверх гри
	const val GOLD = 0xFFFFD9A0.toInt()     // час гри
	const val BAD = 0xFFFF9A9A.toInt()

	private val fonts = HashMap<String, Typeface>()

	/** Шрифт з assets/anyplay/fonts (той самий файл, що й для сторінки) */
	fun font(context: Context, name: String): Typeface = synchronized(fonts) {
		fonts.getOrPut(name) {
			try { Typeface.createFromAsset(context.applicationContext.assets, "anyplay/fonts/$name.ttf") }
			catch(e: Exception) { Typeface.DEFAULT }
		}
	}

	/** Заголовки, кнопки, підписи великими літерами */
	fun display(context: Context) = font(context, "Oswald-SemiBold")
	fun displayMedium(context: Context) = font(context, "Oswald-Medium")
	/** Звичайний текст */
	fun body(context: Context) = font(context, "Inter-Regular")
	fun bodyMedium(context: Context) = font(context, "Inter-Medium")

	fun dp(context: Context, v: Float) = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, context.resources.displayMetrics)

	/** Тло екранів: градієнт згори вниз */
	fun background(): GradientDrawable =
		GradientDrawable(GradientDrawable.Orientation.TL_BR, intArrayOf(BG1, BG2, BG3))

	/** Кнопка в стилі AnyPlay: біла суцільна (головна) або прозора з тонкою рамкою */
	fun button(b: TextView, primary: Boolean)
	{
		val c = b.context
		b.typeface = display(c)
		b.isAllCaps = true
		b.letterSpacing = 0.12f
		b.setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
		val padH = dp(c, 16f).toInt()
		b.setPadding(padH, b.paddingTop, padH, b.paddingBottom)
		// 129: усі кнопки однакової висоти й в один рядок (у вікнах «Вийти» і «Спробувати ще раз» стояли на різній висоті)
		b.isSingleLine = true
		b.gravity = android.view.Gravity.CENTER
		b.minHeight = dp(c, 44f).toInt()
		b.minimumHeight = dp(c, 44f).toInt()
		if(b is MaterialButton)
		{
			b.insetTop = 0
			b.insetBottom = 0
			b.cornerRadius = dp(c, 2f).toInt()
			b.backgroundTintList = ColorStateList.valueOf(if(primary) INK else 0)
			b.strokeColor = ColorStateList.valueOf(EDGE)
			b.strokeWidth = if(primary) 0 else dp(c, 1f).toInt()
			b.rippleColor = ColorStateList.valueOf(if(primary) 0x33221D2E else 0x33FFFFFF)
			b.setTextColor(if(primary) DARK else INK)
		}
		else
		{
			b.background = GradientDrawable().apply {
				cornerRadius = dp(c, 2f)
				if(primary) setColor(INK) else setStroke(dp(c, 1f).toInt(), EDGE)
			}
			b.setTextColor(if(primary) DARK else INK)
		}
	}

	/** Оформити вікно-повідомлення (після show): заголовок Oswald, текст Inter, кнопки як на сторінці */
	fun style(d: AlertDialog)
	{
		val c = d.context
		d.findViewById<TextView>(androidx.appcompat.R.id.alertTitle)?.let {
			it.typeface = display(c)
			it.isAllCaps = true
			it.letterSpacing = 0.08f
			it.setTextColor(INK)
			it.setTextSize(TypedValue.COMPLEX_UNIT_SP, 20f)
		}
		d.findViewById<TextView>(android.R.id.message)?.let {
			it.typeface = body(c)
			it.setTextColor(0xD9FFFFFF.toInt())
			it.setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
			it.setLineSpacing(dp(c, 3f), 1f)
		}
		d.getButton(DialogInterface.BUTTON_POSITIVE)?.let { button(it, true) }
		d.getButton(DialogInterface.BUTTON_NEGATIVE)?.let { button(it, false) }
		d.getButton(DialogInterface.BUTTON_NEUTRAL)?.let { button(it, false) }
		// 129: кнопки вікна — по центру по вертикалі, з однаковим проміжком, у тексті трохи менші літери
		for(w in intArrayOf(DialogInterface.BUTTON_POSITIVE, DialogInterface.BUTTON_NEGATIVE, DialogInterface.BUTTON_NEUTRAL))
			d.getButton(w)?.let { b ->
				b.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
				b.letterSpacing = 0.1f
				(b.layoutParams as? android.view.ViewGroup.MarginLayoutParams)?.let { lp ->
					lp.topMargin = 0; lp.bottomMargin = 0
					lp.marginStart = dp(c, 8f).toInt()
					b.layoutParams = lp
				}
				(b.layoutParams as? android.widget.LinearLayout.LayoutParams)?.gravity = android.view.Gravity.CENTER_VERTICAL
			}
	}

	/** Текст вікна з помилкою: пояснення, а нижче дрібним блідим рядком технічний код для підтримки (якщо є) */
	fun errorMessage(text: String, code: String): CharSequence
	{
		if(code.isEmpty())
			return text
		val b = SpannableStringBuilder(text).append("\n\n")
		val from = b.length
		b.append("Код для підтримки: ").append(code)
		b.setSpan(RelativeSizeSpan(0.78f), from, b.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
		b.setSpan(ForegroundColorSpan(MUTE), from, b.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
		return b
	}

	/** Показати вікно-повідомлення одразу в стилі AnyPlay */
	fun show(b: MaterialAlertDialogBuilder): AlertDialog = b.show().also { style(it) }
}
