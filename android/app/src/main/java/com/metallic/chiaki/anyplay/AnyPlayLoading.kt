// AnyPlay 118: екран завантаження гри поверх картинки — щоб ніколи не було чорного екрана без пояснення.
// Етапи: «Підключаюсь до приставки» → «Чекаю картинку» → «Майже готово», таймер від початку, «Скасувати»;
// якщо довго — «Підключитись заново». Посеред гри (картинка зависла) — той самий екран, але напівпрозорий,
// і дотики крім кнопок ідуть у гру (екранні кнопки під ним працюють).
package com.metallic.chiaki.anyplay

import android.animation.ValueAnimator
import android.app.Activity
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.drawable.ColorDrawable
import android.os.SystemClock
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.animation.LinearInterpolator
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import kotlin.math.roundToInt

class AnyPlayLoading(private val activity: Activity, private val parent: FrameLayout,
	private val onCancel: () -> Unit, private val onReconnect: () -> Unit)
{
	enum class Stage(val step: Int, val title: String)
	{
		CONNECT(1, "Підключаюсь до приставки"),
		PICTURE(2, "Чекаю картинку"),
		ALMOST(3, "Майже готово"),
		RECOVER(3, "Відновлюю картинку"),
		STUCK(3, "Картинка не з'явилась")
	}

	companion object
	{
		const val ACCENT = 0xFF8FE3FF.toInt()   // блакитний «йде гра», як на сторінці
	}

	private val density = activity.resources.displayMetrics.density
	private fun px(v: Float) = (v * density).roundToInt()

	private var root: FrameLayout? = null
	private lateinit var eyebrow: TextView
	private lateinit var title: TextView
	private lateinit var detail: TextView
	private lateinit var timer: TextView
	private lateinit var steps: LinearLayout
	private lateinit var reconnect: TextView
	private lateinit var cancel: TextView
	private lateinit var line: SweepLine
	private var full = true
	private var since = 0L
	private var stage: Stage? = null

	val isShown get() = root != null

	/**
	 * Показати або оновити.
	 * @param full true — на весь екран з тлом AnyPlay (початок гри); false — напівпрозоро поверх зависшої картинки
	 * @param since elapsedRealtime, від якого рахує таймер
	 * @param canReconnect показати «Підключитись заново»
	 */
	fun show(stage: Stage, detailText: String, full: Boolean, since: Long, canReconnect: Boolean, cancelText: String = "Скасувати")
	{
		if(root == null || this.full != full)
		{
			hide(false)
			build(full)
		}
		this.since = since
		if(this.stage != stage)
		{
			this.stage = stage
			title.text = stage.title
			for(i in 0 until steps.childCount)
				steps.getChildAt(i).alpha = if(i < stage.step) 1f else 0.25f
			eyebrow.text = when(stage)
			{
				Stage.RECOVER -> "Гра триває"
				Stage.STUCK -> "Щось пішло не так"
				else -> "Крок ${stage.step} з 3"
			}
			title.setTextColor(if(stage == Stage.STUCK) AnyPlayStyle.BAD else AnyPlayStyle.INK)
		}
		if(detail.text.toString() != detailText)
			detail.text = detailText
		reconnect.visibility = if(canReconnect) View.VISIBLE else View.GONE
		if(cancel.text.toString() != cancelText)
			cancel.text = cancelText
		tick()
	}

	/** Раз на секунду: таймер */
	fun tick()
	{
		if(root == null)
			return
		val s = ((SystemClock.elapsedRealtime() - since) / 1000).coerceAtLeast(0)
		timer.text = "${s / 60}:${(s % 60).toString().padStart(2, '0')}"
	}

	fun hide(animate: Boolean = true)
	{
		val r = root ?: return
		root = null
		stage = null
		line.stop()
		if(animate)
			r.animate().alpha(0f).setDuration(220).withEndAction { parent.removeView(r) }.start()
		else
			parent.removeView(r)
	}

	private fun build(full: Boolean)
	{
		this.full = full
		val c = activity
		val r = FrameLayout(c)
		if(full)
		{
			r.background = AnyPlayStyle.background()
			r.isClickable = true   // на початку дотики в гру не йдуть: картинки ще немає
		}
		else
			r.background = ColorDrawable(0x99120F1A.toInt())

		val col = LinearLayout(c).apply {
			orientation = LinearLayout.VERTICAL
			gravity = Gravity.CENTER_HORIZONTAL
			setPadding(px(24f), px(20f), px(24f), px(20f))
			if(!full)
			{
				background = android.graphics.drawable.GradientDrawable().apply {
					setColor(AnyPlayStyle.DIALOG)
					cornerRadius = 3 * density
					setStroke(px(1f), AnyPlayStyle.EDGE)
				}
				isClickable = true
			}
		}
		eyebrow = TextView(c).apply {
			typeface = AnyPlayStyle.display(c)
			isAllCaps = true
			letterSpacing = 0.18f
			setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
			setTextColor(AnyPlayStyle.MUTE)
		}
		col.addView(eyebrow)
		title = TextView(c).apply {
			typeface = AnyPlayStyle.display(c)
			isAllCaps = true
			letterSpacing = 0.06f
			gravity = Gravity.CENTER
			setTextSize(TypedValue.COMPLEX_UNIT_SP, if(full) 26f else 20f)
			setTextColor(AnyPlayStyle.INK)
		}
		col.addView(title, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).also { it.topMargin = px(6f) })
		steps = LinearLayout(c).apply { orientation = LinearLayout.HORIZONTAL }
		for(i in 0 until 3)
			steps.addView(View(c).apply { setBackgroundColor(ACCENT) },
				LinearLayout.LayoutParams(px(34f), px(3f)).also { if(i > 0) it.marginStart = px(6f) })
		col.addView(steps, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).also { it.topMargin = px(14f) })
		detail = TextView(c).apply {
			typeface = AnyPlayStyle.body(c)
			gravity = Gravity.CENTER
			setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
			setTextColor(0xD9FFFFFF.toInt())
			setLineSpacing(3 * density, 1f)
			maxWidth = px(420f)
		}
		col.addView(detail, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).also { it.topMargin = px(14f) })
		timer = TextView(c).apply {
			typeface = AnyPlayStyle.displayMedium(c)
			letterSpacing = 0.08f
			setTextSize(TypedValue.COMPLEX_UNIT_SP, 22f)
			setTextColor(ACCENT)
		}
		col.addView(timer, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).also { it.topMargin = px(12f) })
		line = SweepLine(c)
		col.addView(line, LinearLayout.LayoutParams(px(180f), px(2f)).also { it.topMargin = px(10f) })
		val buttons = LinearLayout(c).apply {
			orientation = LinearLayout.HORIZONTAL
			gravity = Gravity.CENTER
		}
		reconnect = TextView(c).apply {
			text = "Підключитись заново"
			gravity = Gravity.CENTER
			minHeight = px(42f)
			AnyPlayStyle.button(this, true)
			setOnClickListener { onReconnect() }
		}
		buttons.addView(reconnect, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).also { it.marginEnd = px(10f) })
		cancel = TextView(c).apply {
			text = "Скасувати"
			gravity = Gravity.CENTER
			minHeight = px(42f)
			AnyPlayStyle.button(this, false)
			setOnClickListener { onCancel() }
		}
		buttons.addView(cancel)
		col.addView(buttons, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).also { it.topMargin = px(20f) })

		val lp = FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.CENTER)
		lp.leftMargin = px(16f)
		lp.rightMargin = px(16f)
		r.addView(col, lp)
		r.elevation = 30 * density   // над екранними кнопками і банером
		r.alpha = 0f
		parent.addView(r, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
		r.animate().alpha(1f).setDuration(180).start()
		line.start()
		root = r
	}

	/** Тонка лінія з відблиском, що бігає зліва направо: «працюю», без кола-спінера */
	private class SweepLine(context: Activity): View(context)
	{
		private val base = Paint().apply { color = 0x33FFFFFF }
		private val glow = Paint().apply { color = ACCENT }
		private var phase = 0f
		private var anim: ValueAnimator? = null

		fun start()
		{
			anim?.cancel()
			anim = ValueAnimator.ofFloat(0f, 1f).apply {
				duration = 1400
				repeatCount = ValueAnimator.INFINITE
				interpolator = LinearInterpolator()
				addUpdateListener { phase = it.animatedValue as Float; invalidate() }
				start()
			}
		}

		fun stop()
		{
			anim?.cancel()
			anim = null
		}

		override fun onDetachedFromWindow()
		{
			super.onDetachedFromWindow()
			stop()
		}

		override fun onDraw(canvas: Canvas)
		{
			val w = width.toFloat()
			val h = height.toFloat()
			canvas.drawRect(0f, 0f, w, h, base)
			val seg = w * 0.3f
			val x = -seg + (w + seg) * phase
			canvas.drawRect(x.coerceAtLeast(0f), 0f, (x + seg).coerceAtMost(w), h, glow)
		}
	}
}
