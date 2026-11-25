// AnyPlay: редактор «Розташування кнопок». Панель поверх екранного геймпада: перетягнути кнопку, змінити розмір
// (двома пальцями або повзунком), прозорість, автоховання, додаткові кнопки (постріл, перезарядка, сісти в машину тощо),
// сховати непотрібні, скинути до типових. Окремо для горизонтального й вертикального екрана.
// Працює і в грі (поверх картинки), і з головного екрана (PadEditorDialog, без гри).
package com.metallic.chiaki.anyplay

import android.annotation.SuppressLint
import android.app.Activity
import android.app.Dialog
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Bundle
import android.text.InputFilter
import android.view.Gravity
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.SeekBar
import android.widget.TextView
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import com.metallic.chiaki.R
import kotlin.math.roundToInt

class PadEditor(private val activity: Activity, private val parent: FrameLayout, private val pad: GamepadView,
	private val onClose: () -> Unit)
{
	private val density = activity.resources.displayMetrics.density
	private fun px(v: Float) = (v * density).roundToInt()

	private var panel: LinearLayout? = null
	private lateinit var orient: TextView
	private lateinit var sizeLabel: TextView
	private lateinit var sizeBar: SeekBar
	private lateinit var removeBtn: TextView
	private lateinit var opacityBar: SeekBar
	private lateinit var hideBtn: TextView
	private var opacity = PadLayout.opacity(activity)
	private var autoHide = PadLayout.autoHide(activity)
	private var refreshing = false

	val isOpen get() = panel != null

	fun open()
	{
		if(panel != null)
			return
		pad.editMode = true
		val p = build()
		panel = p
		val lp = FrameLayout.LayoutParams(px(330f).coerceAtMost(maxOf(px(240f), parent.width - px(24f))), ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.CENTER)
		parent.addView(p, lp)
		pad.editListener = { refresh() }
		refresh()
	}

	/** save: «Готово» або «Назад» — зберегти; «Скасувати» — повернути як було */
	fun close(save: Boolean)
	{
		val p = panel ?: return
		panel = null
		if(save)
		{
			pad.saveLayout()
			PadLayout.setOpacity(activity, opacity)
			PadLayout.setAutoHide(activity, autoHide)
		}
		pad.editListener = null
		pad.editMode = false   // перечитує збережене розташування
		pad.reloadSettings()
		parent.removeView(p)
		onClose()
	}

	private fun label(text: String, size: Float, color: Int, display: Boolean = false) = TextView(activity).apply {
		this.text = text
		textSize = size
		setTextColor(color)
		typeface = if(display) AnyPlayStyle.display(activity) else AnyPlayStyle.body(activity)
		if(display)
		{
			isAllCaps = true
			letterSpacing = 0.08f
		}
	}

	private fun smallButton(text: String, primary: Boolean, click: () -> Unit) = TextView(activity).apply {
		this.text = text
		gravity = Gravity.CENTER
		minHeight = px(38f)
		AnyPlayStyle.button(this, primary)
		textSize = 13f
		letterSpacing = 0.08f
		setPadding(px(10f), px(6f), px(10f), px(6f))
		setOnClickListener { click() }
	}

	private fun seekBar(max: Int, change: (Int) -> Unit) = SeekBar(activity).apply {
		this.max = max
		progressTintList = ColorStateList.valueOf(AnyPlayStyle.INK)
		thumbTintList = ColorStateList.valueOf(AnyPlayStyle.INK)
		progressBackgroundTintList = ColorStateList.valueOf(0x55FFFFFF)
		setOnSeekBarChangeListener(object: SeekBar.OnSeekBarChangeListener
		{
			override fun onProgressChanged(s: SeekBar, progress: Int, fromUser: Boolean) { if(fromUser && !refreshing) change(progress) }
			override fun onStartTrackingTouch(s: SeekBar) {}
			override fun onStopTrackingTouch(s: SeekBar) {}
		})
	}

	/** Рядок кнопок однакової ширини */
	private fun row(vararg views: View): LinearLayout = LinearLayout(activity).apply {
		orientation = LinearLayout.HORIZONTAL
		gravity = Gravity.CENTER_VERTICAL
		views.forEachIndexed { i, v ->
			val lp = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
			if(i > 0) lp.marginStart = px(8f)
			addView(v, lp)
		}
	}

	@SuppressLint("ClickableViewAccessibility")
	private fun build(): LinearLayout
	{
		val p = LinearLayout(activity).apply {
			orientation = LinearLayout.VERTICAL
			background = GradientDrawable().apply {
				setColor(AnyPlayStyle.DIALOG)
				cornerRadius = 3 * density
				setStroke(px(1f), AnyPlayStyle.EDGE)
			}
			setPadding(px(14f), px(10f), px(14f), px(12f))
			elevation = 8 * density
			isClickable = true   // дотики по панелі не йдуть до кнопок під нею
		}
		// заголовок: за нього панель можна перетягнути, якщо закриває кнопку
		val title = label("Розташування кнопок", 15f, AnyPlayStyle.INK, true)
		orient = label("", 12f, AnyPlayStyle.MUTE)
		val head = LinearLayout(activity).apply {
			orientation = LinearLayout.HORIZONTAL
			gravity = Gravity.CENTER_VERTICAL
			addView(title, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
			addView(orient)
		}
		var downX = 0f
		var downY = 0f
		var startTX = 0f
		var startTY = 0f
		head.setOnTouchListener { _, e ->
			when(e.actionMasked)
			{
				MotionEvent.ACTION_DOWN -> { downX = e.rawX; downY = e.rawY; startTX = p.translationX; startTY = p.translationY }
				MotionEvent.ACTION_MOVE ->
				{
					val maxX = maxOf(0f, (parent.width - p.width) / 2f)
					val maxY = maxOf(0f, (parent.height - p.height) / 2f)
					p.translationX = (startTX + e.rawX - downX).coerceIn(-maxX, maxX)
					p.translationY = (startTY + e.rawY - downY).coerceIn(-maxY, maxY)
				}
			}
			true
		}
		p.addView(head)
		p.addView(label("Перетягни кнопку пальцем. Розмір: двома пальцями або повзунком. Панель пересувається за заголовок.",
			12f, AnyPlayStyle.MUTE).apply { setPadding(0, px(2f), 0, px(8f)) })

		sizeLabel = label("", 13f, AnyPlayStyle.INK)
		removeBtn = smallButton("Сховати", false) { pad.removeSelected() }
		p.addView(LinearLayout(activity).apply {
			orientation = LinearLayout.HORIZONTAL
			gravity = Gravity.CENTER_VERTICAL
			addView(sizeLabel, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
			addView(removeBtn, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT))
		})
		sizeBar = seekBar(((PadLayout.MAX_SCALE - PadLayout.MIN_SCALE) * 100).roundToInt()) {
			pad.setScale(PadLayout.MIN_SCALE + it / 100f)
			sizeLabel.text = sizeText()
		}
		p.addView(sizeBar, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, px(36f)))

		p.addView(label("Прозорість кнопок", 13f, AnyPlayStyle.INK))
		opacityBar = seekBar(80) {
			opacity = 0.2f + it / 100f
			pad.setOpacityPreview(opacity)
		}
		p.addView(opacityBar, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, px(36f)))

		hideBtn = smallButton("", false) {
			val steps = PadLayout.AUTOHIDE_STEPS
			val i = steps.indexOf(autoHide)
			autoHide = steps[(i + 1) % steps.size]
			hideBtn.text = hideText()
		}
		p.addView(row(smallButton("Кнопки…", false) { chooseButtons() }, hideBtn))
		p.addView(label("Кнопки ховаються, коли граєш геймпадом або не торкаєшся екрана (лише горизонтально). Перший дотик показує їх і в гру не йде.",
			11f, AnyPlayStyle.MUTE).apply { setPadding(0, px(4f), 0, px(8f)) })
		p.addView(row(
			smallButton("Скинути", false) { confirmReset() },
			smallButton("Скасувати", false) { close(false) },
			smallButton("Готово", true) { close(true) }))
		return p
	}

	private fun hideText() = if(autoHide > 0) "Ховати: ${autoHide} с" else "Ховати: ніколи"

	private fun sizeText(): String
	{
		val pct = (pad.currentScale() * 100).roundToInt()
		val t = pad.selectedTitle()
		return if(t != null) "Розмір: $t, $pct%" else "Розмір усіх кнопок: $pct%"
	}

	private fun refresh()
	{
		if(panel == null)
			return
		refreshing = true
		orient.text = if(pad.isLandscape) "горизонтально" else "вертикально"
		sizeLabel.text = sizeText()
		sizeBar.progress = ((pad.currentScale() - PadLayout.MIN_SCALE) * 100).roundToInt()
		opacityBar.progress = ((opacity - 0.2f) * 100).roundToInt()
		removeBtn.visibility = if(pad.selectedTitle() != null && !pad.selectedIsMenu()) View.VISIBLE else View.GONE
		removeBtn.text = if(pad.selectedIsExtra()) "Прибрати" else "Сховати"
		hideBtn.text = hideText()
		refreshing = false
	}

	private fun confirmReset()
	{
		AnyPlayStyle.show(MaterialAlertDialogBuilder(activity)
			.setMessage("Повернути типове розташування й розмір кнопок для " + (if(pad.isLandscape) "горизонтального" else "вертикального")
				+ " екрана? Додаткові кнопки зникнуть.")
			.setPositiveButton("Скинути") { _, _ ->
				pad.resetLayout()
				opacity = 0.7f
				pad.setOpacityPreview(opacity)
				autoHide = 10
				refresh()
			}
			.setNegativeButton("Скасувати", null))
	}

	/** Які кнопки показувати: стандартні DualSense, готові додаткові для GTA і свої */
	private fun chooseButtons()
	{
		val standard = PadLayout.STANDARD.filter { it != "menu" }
		val customs = pad.extras().filter { e -> PadLayout.PRESETS.none { "x_" + it.id == e.id } }
		val titles = ArrayList<String>()
		val checked = ArrayList<Boolean>()
		for(id in standard)
		{
			titles.add(PadLayout.TITLES[id] ?: id)
			checked.add(pad.profile.find(id)?.on != false)
		}
		for(pr in PadLayout.PRESETS)
		{
			titles.add("Додаткова: " + pr.title)
			checked.add(pad.profile.find("x_" + pr.id) != null)
		}
		for(c in customs)
		{
			titles.add("Своя: " + c.label + " (" + PadLayout.buttonMark(c.button) + ")")
			checked.add(true)
		}
		val state = checked.toBooleanArray()
		AnyPlayStyle.show(MaterialAlertDialogBuilder(activity)
			.setTitle("Кнопки на екрані")
			.setMultiChoiceItems(titles.toTypedArray(), state) { _, which, isChecked -> state[which] = isChecked }
			.setPositiveButton("Готово") { _, _ ->
				var i = 0
				for(id in standard)
					pad.setElementOn(id, state[i++])
				for(pr in PadLayout.PRESETS)
				{
					val id = "x_" + pr.id
					if(state[i++]) pad.addExtra(id, pr.label, pr.button) else pad.removeElement(id)
				}
				for(c in customs)
					if(!state[i++])
						pad.removeElement(c.id)
				refresh()
			}
			.setNeutralButton("Своя кнопка…") { _, _ -> addCustom() }
			.setNegativeButton("Скасувати", null))
	}

	/** Своя кнопка: яку кнопку геймпада натискати і як її підписати */
	private fun addCustom()
	{
		val names = PadLayout.BUTTONS.map { it.second }.toTypedArray()
		AnyPlayStyle.show(MaterialAlertDialogBuilder(activity)
			.setTitle("Яку кнопку геймпада натискати?")
			.setItems(names) { _, which ->
				val code = PadLayout.BUTTONS[which].first
				val input = EditText(activity).apply {
					hint = "Наприклад: Фари"
					filters = arrayOf(InputFilter.LengthFilter(12))
					setSingleLine()
					setTextColor(AnyPlayStyle.INK)
					setHintTextColor(AnyPlayStyle.MUTE)
				}
				val box = FrameLayout(activity).apply {
					setPadding(px(22f), px(8f), px(22f), 0)
					addView(input)
				}
				AnyPlayStyle.show(MaterialAlertDialogBuilder(activity)
					.setTitle("Підпис на кнопці")
					.setView(box)
					.setPositiveButton("Додати") { _, _ ->
						val name = input.text.toString().trim().ifEmpty { PadLayout.buttonMark(code) }
						pad.addExtra(PadLayout.extraId(pad.profile, null), name, code)
						refresh()
					}
					.setNegativeButton("Скасувати", null))
			}
			.setNegativeButton("Скасувати", null))
	}
}

/** Редактор кнопок з головного екрана, без гри: темне поле замість картинки */
class PadEditorDialog(private val activity: Activity): Dialog(activity, R.style.AnyPlayTheme)
{
	private var editor: PadEditor? = null

	override fun onCreate(savedInstanceState: Bundle?)
	{
		super.onCreate(savedInstanceState)
		val root = FrameLayout(activity)
		root.background = AnyPlayStyle.background()
		val pad = GamepadView(activity)
		root.addView(pad, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
		setContentView(root, ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
		window?.let { w ->
			w.setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
			w.setBackgroundDrawable(ColorDrawable(Color.BLACK))
			w.setFormat(PixelFormat.OPAQUE)
			WindowCompat.setDecorFitsSystemWindows(w, false)
			if(Build.VERSION.SDK_INT >= Build.VERSION_CODES.P)
				w.attributes = w.attributes.also { it.layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES }
			// як у грі: без системних панелей, щоб кнопки стояли там само
			WindowCompat.getInsetsController(w, w.decorView).let {
				it.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
				it.hide(WindowInsetsCompat.Type.systemBars())
			}
		}
		// як StreamActivity.arrangeForOrientation: вертикально картинка 16:9 зверху, кнопки під нею
		val arrange = {
			val cut = ViewCompat.getRootWindowInsets(root)?.getInsets(WindowInsetsCompat.Type.displayCutout())
			pad.safeLeft = cut?.left ?: 0
			pad.safeRight = cut?.right ?: 0
			pad.safeBottom = cut?.bottom ?: 0
			pad.videoBottom = if(root.height > root.width) (cut?.top ?: 0) + root.width * 9 / 16 else 0
			pad.refreshLayout()
		}
		root.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ -> root.post { arrange() } }
		root.post {
			arrange()
			editor = PadEditor(activity, root, pad) { dismiss() }.also { it.open() }
		}
	}

	override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean
	{
		if(keyCode == KeyEvent.KEYCODE_BACK)
		{
			val e = editor
			if(e != null && e.isOpen)
				e.close(true)
			else
				dismiss()
			return true
		}
		return super.onKeyDown(keyCode, event)
	}
}
