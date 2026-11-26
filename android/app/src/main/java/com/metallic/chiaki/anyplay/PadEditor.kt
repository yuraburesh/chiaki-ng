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
	private var collapsed = false
	private lateinit var collapseBtn: TextView
	private lateinit var doneMini: TextView

	/** 123: панель згорнута до заголовка (з «Розгорнути» і «Готово»), щоб не закривала кнопки */
	private fun setCollapsed(c: Boolean)
	{
		val p = panel ?: return
		collapsed = c
		for(i in 1 until p.childCount)
			p.getChildAt(i).visibility = if(c) View.GONE else View.VISIBLE
		collapseBtn.text = if(c) "Розгорнути" else "Згорнути"
		orient.visibility = if(c) View.GONE else View.VISIBLE
	}

	val isOpen get() = panel != null

	fun open()
	{
		if(panel != null)
			return
		pad.editMode = true
		val p = build()
		panel = p
		// 123: вертикально — панель над картинкою гри (там кнопок немає), горизонтально — угорі по центру
		val portrait = parent.height > parent.width
		val lp = FrameLayout.LayoutParams(px(340f).coerceAtMost(maxOf(px(240f), parent.width - px(24f))), ViewGroup.LayoutParams.WRAP_CONTENT,
			Gravity.TOP or Gravity.CENTER_HORIZONTAL)
		lp.topMargin = px(if(portrait) 12f else 8f)
		parent.addView(p, lp)
		pad.editListener = { refresh() }
		// поки тягнеш кнопку чи змінюєш розмір, панель майже зникає й не заважає (дотики проходять крізь неї)
		pad.editDragListener = { dragging ->
			p.animate().cancel()
			p.animate().alpha(if(dragging) 0.12f else 1f).setDuration(if(dragging) 90 else 160).start()
		}
		// горизонтально кнопки по всьому екрану: панель одразу згорнута до рядка заголовка
		if(!portrait)
			setCollapsed(true)
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
		pad.editDragListener = null
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
		minHeight = px(36f)
		AnyPlayStyle.button(this, primary)
		textSize = 12.5f
		letterSpacing = 0.08f
		setPadding(px(10f), px(6f), px(10f), px(6f))
		setOnClickListener {
			AnyPlayHaptics.tap(activity, AnyPlayHaptics.Tap.UI)
			it.animate().cancel()
			it.scaleX = 0.94f; it.scaleY = 0.94f
			it.animate().scaleX(1f).scaleY(1f).setDuration(140).start()
			click()
		}
	}

	/** Чіп-перемикач (Одразу / 5 с / …): обраний — білий */
	private fun chip(text: String, on: Boolean, click: () -> Unit) = TextView(activity).apply {
		this.text = text
		gravity = Gravity.CENTER
		minHeight = px(30f)
		textSize = 12f
		typeface = AnyPlayStyle.bodyMedium(activity)
		setPadding(px(4f), px(4f), px(4f), px(4f))
		setTextColor(if(on) AnyPlayStyle.DARK else AnyPlayStyle.INK)
		background = GradientDrawable().apply {
			cornerRadius = 3 * density
			if(on) setColor(AnyPlayStyle.INK) else { setColor(0x0FFFFFFF); setStroke(px(1f), AnyPlayStyle.EDGE) }
		}
		setOnClickListener { AnyPlayHaptics.tap(activity, AnyPlayHaptics.Tap.TICK); click() }
	}

	private fun seekBar(max: Int, change: (Int) -> Unit) = SeekBar(activity).apply {
		this.max = max
		progressTintList = ColorStateList.valueOf(AnyPlayStyle.INK)
		thumbTintList = ColorStateList.valueOf(AnyPlayStyle.INK)
		progressBackgroundTintList = ColorStateList.valueOf(0x55FFFFFF)
		setPadding(px(10f), 0, px(10f), 0)
		var lastStep = -1
		setOnSeekBarChangeListener(object: SeekBar.OnSeekBarChangeListener
		{
			override fun onProgressChanged(s: SeekBar, progress: Int, fromUser: Boolean)
			{
				if(!fromUser || refreshing) return
				// легкий тік кожні 10%: повзунок відчувається, як коліщатко з клацанням
				val step = progress / 10
				if(step != lastStep) { lastStep = step; AnyPlayHaptics.tap(activity, AnyPlayHaptics.Tap.DETENT) }
				change(progress)
			}
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
			if(i > 0) lp.marginStart = px(6f)
			addView(v, lp)
		}
	}

	/** Підпис зліва, значення справа (над повзунком) */
	private fun valueRow(left: TextView, right: TextView): LinearLayout = LinearLayout(activity).apply {
		orientation = LinearLayout.HORIZONTAL
		gravity = Gravity.CENTER_VERTICAL
		addView(left, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
		addView(right)
		setPadding(0, px(8f), 0, 0)
	}

	private lateinit var sizeValue: TextView
	private lateinit var opacityValue: TextView
	private lateinit var hideChips: LinearLayout
	private lateinit var hideHint: TextView

	@SuppressLint("ClickableViewAccessibility")
	private fun build(): LinearLayout
	{
		val p = LinearLayout(activity).apply {
			orientation = LinearLayout.VERTICAL
			background = GradientDrawable().apply {
				setColor(AnyPlayStyle.DIALOG)
				cornerRadius = 6 * density
				setStroke(px(1f), AnyPlayStyle.EDGE)
			}
			setPadding(px(14f), px(10f), px(14f), px(12f))
			elevation = 10 * density
			isClickable = true   // дотики по панелі не йдуть до кнопок під нею
			layoutTransition = android.animation.LayoutTransition()   // плавно згортається й розгортається
		}
		// заголовок: за нього панель можна перетягнути, якщо закриває кнопку
		val title = label("Кнопки", 15f, AnyPlayStyle.INK, true)
		orient = label("", 11.5f, AnyPlayStyle.MUTE).apply { setPadding(px(8f), 0, 0, 0) }
		collapseBtn = smallButton("Згорнути", false) { setCollapsed(!collapsed) }.apply { minHeight = px(30f); textSize = 11.5f }
		doneMini = smallButton("Готово", true) { close(true) }.apply { minHeight = px(30f); textSize = 11.5f }
		val head = LinearLayout(activity).apply {
			orientation = LinearLayout.HORIZONTAL
			gravity = Gravity.CENTER_VERTICAL
			addView(title)
			addView(orient, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
			addView(collapseBtn, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { marginStart = px(8f) })
			addView(doneMini, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { marginStart = px(6f) })
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
					val maxY = maxOf(0f, (parent.height - p.height).toFloat())
					p.translationX = (startTX + e.rawX - downX).coerceIn(-maxX, maxX)
					p.translationY = (startTY + e.rawY - downY).coerceIn(-px(8f).toFloat(), maxY)
				}
			}
			true
		}
		p.addView(head)
		p.addView(label("Тягни пальцем, розмір двома пальцями.", 11.5f, AnyPlayStyle.MUTE)
			.apply { setPadding(0, px(4f), 0, 0) })

		// вибрана кнопка: розмір і «Сховати»
		sizeLabel = label("", 13f, AnyPlayStyle.INK).apply { typeface = AnyPlayStyle.bodyMedium(activity) }
		sizeValue = label("", 12f, AnyPlayStyle.MUTE)
		removeBtn = smallButton("Сховати", false) { pad.removeSelected() }.apply { minHeight = px(28f); textSize = 11f }
		p.addView(LinearLayout(activity).apply {
			orientation = LinearLayout.HORIZONTAL
			gravity = Gravity.CENTER_VERTICAL
			setPadding(0, px(8f), 0, 0)
			addView(sizeLabel, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
			addView(sizeValue)
			addView(removeBtn, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { marginStart = px(8f) })
		})
		sizeBar = seekBar(((PadLayout.MAX_SCALE - PadLayout.MIN_SCALE) * 100).roundToInt()) {
			pad.setScale(PadLayout.MIN_SCALE + it / 100f)
			sizeValue.text = "${(pad.currentScale() * 100).roundToInt()}%"
		}
		p.addView(sizeBar, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, px(30f)))

		opacityValue = label("", 12f, AnyPlayStyle.MUTE)
		p.addView(valueRow(label("Прозорість", 13f, AnyPlayStyle.INK).apply { typeface = AnyPlayStyle.bodyMedium(activity) }, opacityValue))
		opacityBar = seekBar(80) {
			opacity = 0.2f + it / 100f
			pad.setOpacityPreview(opacity)
			opacityValue.text = "${(opacity * 100).roundToInt()}%"
		}
		p.addView(opacityBar, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, px(30f)))

		// коли ховати: п'ять чіпів в один рядок
		p.addView(label("Ховати кнопки", 13f, AnyPlayStyle.INK).apply { typeface = AnyPlayStyle.bodyMedium(activity); setPadding(0, px(6f), 0, px(6f)) })
		hideChips = LinearLayout(activity).apply { orientation = LinearLayout.HORIZONTAL }
		p.addView(hideChips)
		hideHint = label("", 11f, AnyPlayStyle.MUTE).apply { setPadding(0, px(5f), 0, px(8f)) }
		p.addView(hideHint)
		hideBtn = TextView(activity)   // старе поле, текст рахує hideText()

		p.addView(row(
			smallButton("Джойстик…", true) { chooseButtons() },
			smallButton("Скинути", false) { confirmReset() },
			smallButton("Скасувати", false) { close(false) }))
		// повна панель: «Готово» угорі завжди видно
		return p
	}

	private fun renderHide()
	{
		hideChips.removeAllViews()
		PadLayout.AUTOHIDE_STEPS.forEachIndexed { i, v ->
			val t = when { v < 0 -> "Одразу"; v == 0 -> "Ніколи"; else -> "$v с" }
			val c = chip(t, v == autoHide) { autoHide = v; renderHide() }
			hideChips.addView(c, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f).apply { if(i > 0) marginStart = px(4f) })
		}
		hideHint.text = when
		{
			autoHide < 0 -> "Зникають, щойно відпускаєш екран."
			autoHide > 0 -> "Зникають через $autoHide с без дотиків."
			else -> "Завжди на екрані."
		} + " Лише горизонтально."
	}

	private fun hideText() = when
	{
		autoHide < 0 -> "Ховати: одразу"
		autoHide > 0 -> "Ховати: через ${autoHide} с"
		else -> "Ховати: ніколи"
	}

	private fun refresh()
	{
		if(panel == null)
			return
		refreshing = true
		orient.text = if(pad.isLandscape) "горизонтально" else "вертикально"
		val t = pad.selectedTitle()
		sizeLabel.text = t ?: "Розмір усіх кнопок"
		sizeValue.text = "${(pad.currentScale() * 100).roundToInt()}%"
		sizeBar.progress = ((pad.currentScale() - PadLayout.MIN_SCALE) * 100).roundToInt()
		opacityBar.progress = ((opacity - 0.2f) * 100).roundToInt()
		opacityValue.text = "${(opacity * 100).roundToInt()}%"
		removeBtn.visibility = if(t != null && !pad.selectedIsMenu()) View.VISIBLE else View.GONE
		removeBtn.text = if(pad.selectedIsExtra()) "Прибрати" else "Сховати"
		renderHide()
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
				autoHide = PadLayout.AUTOHIDE_INSTANT
				refresh()
			}
			.setNegativeButton("Скасувати", null))
	}

	/**
	 * 125: «Джойстик»: малюнок DualSense, де торкаєшся кнопки, щоб сховати чи показати її на екрані (як екран
	 * керування на комп'ютері), готові кнопки для GTA чіпами і своя кнопка (обрати кнопку на тому ж малюнку й підписати).
	 * Усе в одному аркуші поверх гри, без системних вікон (на Galaxy S7 вони обрізались).
	 */
	private fun chooseButtons()
	{
		val shown = HashMap<String, Boolean>()
		for(id in PadLayout.STANDARD)
			shown[id] = pad.profile.find(id)?.on != false
		val presetsOn = HashMap<String, Boolean>()
		for(pr in PadLayout.PRESETS)
			presetsOn[pr.id] = pad.profile.find("x_" + pr.id) != null
		val customs = pad.extras().filter { e -> PadLayout.PRESETS.none { "x_" + it.id == e.id } }.toMutableList()
		val removed = HashSet<String>()
		val added = ArrayList<Pair<String, String>>()   // підпис, код кнопки

		val landscape = parent.width > parent.height
		val dim = FrameLayout(activity).apply {
			setBackgroundColor(0xB3000000.toInt())
			isClickable = true   // дотики не йдуть до кнопок під аркушем
			elevation = 20 * density
			alpha = 0f
		}
		val sheet = LinearLayout(activity).apply {
			orientation = LinearLayout.VERTICAL
			background = GradientDrawable().apply {
				setColor(AnyPlayStyle.DIALOG)
				cornerRadius = 8 * density
				setStroke(px(1f), AnyPlayStyle.EDGE)
			}
			setPadding(px(14f), px(12f), px(14f), px(12f))
			isClickable = true
		}
		val title = label("Джойстик", 16f, AnyPlayStyle.INK, true)
		val sub = label("", 12f, AnyPlayStyle.MUTE).apply { setPadding(0, px(2f), 0, px(8f)) }
		sheet.addView(title)
		sheet.addView(sub)

		val map = PadMapView(activity).apply { this.shown = shown }
		val extrasBox = LinearLayout(activity).apply { orientation = LinearLayout.VERTICAL }
		val nameRow = LinearLayout(activity).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL; visibility = View.GONE }
		val nameInput = EditText(activity).apply {
			hint = "Підпис, наприклад Фари"
			filters = arrayOf(InputFilter.LengthFilter(12))
			setSingleLine()
			textSize = 14f
			setTextColor(AnyPlayStyle.INK)
			setHintTextColor(AnyPlayStyle.MUTE)
			background = GradientDrawable().apply { setColor(0x14FFFFFF); cornerRadius = 3 * density; setStroke(px(1f), AnyPlayStyle.EDGE) }
			setPadding(px(10f), px(8f), px(10f), px(8f))
		}
		var pickCode: String? = null
		lateinit var renderExtras: () -> Unit
		fun setSub()
		{
			sub.text = when
			{
				map.picking && pickCode == null -> "Своя кнопка: торкнись на джойстику кнопки, яку вона натискатиме."
				map.picking -> "Кнопка ${PadLayout.buttonMark(pickCode!!)}. Підпиши її і натисни «Додати»."
				else -> "Світяться кнопки, що є на екрані. Торкнись, щоб сховати чи показати."
			}
		}
		val addBtn = smallButton("Додати", true) {
			val code = pickCode ?: return@smallButton
			val name = nameInput.text.toString().trim().ifEmpty { PadLayout.buttonMark(code) }
			added.add(name to code)
			pickCode = null
			nameInput.setText("")
			map.picking = false
			nameRow.visibility = View.GONE
			setSub()
			renderExtras()
		}
		nameRow.addView(nameInput, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
		nameRow.addView(addBtn, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { marginStart = px(8f) })

		map.onToggle = { id ->
			if(id != "menu")
			{
				shown[id] = shown[id] == false
				map.invalidate()
			}
		}
		map.onPick = { code ->
			pickCode = code
			nameRow.visibility = View.VISIBLE
			setSub()
		}

		renderExtras = {
			extrasBox.removeAllViews()
			extrasBox.addView(label("Додаткові кнопки для GTA", 12f, AnyPlayStyle.MUTE, true).apply { setPadding(0, px(6f), 0, px(6f)) })
			val all = ArrayList<View>()
			for(pr in PadLayout.PRESETS)
				all.add(chip(pr.label + "  " + PadLayout.buttonMark(pr.button), presetsOn[pr.id] == true) {
					presetsOn[pr.id] = presetsOn[pr.id] != true
					renderExtras()
				})
			for(c in customs)
				if(c.id !in removed)
					all.add(chip(c.label + "  " + PadLayout.buttonMark(c.button) + "  ✕", true) { removed.add(c.id); renderExtras() })
			added.forEachIndexed { i, a -> all.add(chip(a.first + "  " + PadLayout.buttonMark(a.second) + "  ✕", true) { added.removeAt(i); renderExtras() }) }
			all.add(chip(if(map.picking) "Скасувати свою" else "+ Своя кнопка", false) {
				map.picking = !map.picking
				pickCode = null
				nameRow.visibility = View.GONE
				setSub()
				renderExtras()
			})
			// по три в рядок
			val perRow = if(landscape) 2 else 3
			var line: LinearLayout? = null
			all.forEachIndexed { i, v ->
				if(i % perRow == 0)
				{
					line = LinearLayout(activity).apply { orientation = LinearLayout.HORIZONTAL }
					extrasBox.addView(line, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { if(i > 0) topMargin = px(5f) })
				}
				line!!.addView(v, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f).apply { if(i % perRow > 0) marginStart = px(5f) })
			}
			for(j in 0 until (perRow - all.size % perRow) % perRow)
				line?.addView(View(activity), LinearLayout.LayoutParams(0, 1, 1f).apply { marginStart = px(5f) })
		}
		setSub()
		renderExtras()

		val close = {
			dim.animate().alpha(0f).setDuration(140).withEndAction { parent.removeView(dim) }.start()
			Unit
		}
		val apply = {
			for(id in PadLayout.STANDARD)
				if(id != "menu")
					pad.setElementOn(id, shown[id] != false)
			for(pr in PadLayout.PRESETS)
			{
				val id = "x_" + pr.id
				if(presetsOn[pr.id] == true) pad.addExtra(id, pr.label, pr.button) else pad.removeElement(id)
			}
			for(id in removed)
				pad.removeElement(id)
			for(a in added)
				pad.addExtra(PadLayout.extraId(pad.profile, null), a.first, a.second)
			refresh()
		}
		val buttons = row(smallButton("Скасувати", false) { close() }, smallButton("Готово", true) { apply(); close() })

		val scrollContent = LinearLayout(activity).apply { orientation = LinearLayout.VERTICAL }
		scrollContent.addView(nameRow, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { bottomMargin = px(6f) })
		scrollContent.addView(extrasBox)
		val scroll = android.widget.ScrollView(activity).apply { isVerticalScrollBarEnabled = false; addView(scrollContent) }

		val maxH = parent.height - px(24f)
		if(landscape)
		{
			// горизонтально: джойстик ліворуч, кнопки GTA праворуч
			val body = LinearLayout(activity).apply { orientation = LinearLayout.HORIZONTAL }
			body.addView(map, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, 1.35f))
			val right = LinearLayout(activity).apply { orientation = LinearLayout.VERTICAL }
			right.addView(scroll, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
			right.addView(buttons, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = px(8f) })
			body.addView(right, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, 1f).apply { marginStart = px(12f) })
			sheet.addView(body, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
			dim.addView(sheet, FrameLayout.LayoutParams(minOf(parent.width - px(24f), px(680f)), maxH, Gravity.CENTER))
		}
		else
		{
			val w = minOf(parent.width - px(24f), px(400f))
			sheet.addView(map, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ((w - px(28f)) * 733f / 1084f).toInt()))
			sheet.addView(scroll, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f).apply { topMargin = px(4f) })
			sheet.addView(buttons, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = px(10f) })
			dim.addView(sheet, FrameLayout.LayoutParams(w, maxH.coerceAtMost(px(620f)), Gravity.CENTER))
		}
		dim.setOnClickListener { close() }
		// телефон повернули: аркуш розмічено під іншу орієнтацію — відкриваємо його заново під нову (вибір не губиться лише для показу кнопок)
		val w0 = parent.width
		val h0 = parent.height
		val rot = object: View.OnLayoutChangeListener
		{
			override fun onLayoutChange(v: View, l: Int, t: Int, r: Int, b: Int, ol: Int, ot: Int, or: Int, ob: Int)
			{
				if((r - l == w0 && b - t == h0) || dim.parent == null)
					return
				parent.removeOnLayoutChangeListener(this)
				parent.removeView(dim)
				parent.post { if(panel != null) chooseButtons() }
			}
		}
		parent.addOnLayoutChangeListener(rot)
		dim.addOnAttachStateChangeListener(object: View.OnAttachStateChangeListener
		{
			override fun onViewAttachedToWindow(v: View) {}
			override fun onViewDetachedFromWindow(v: View) { parent.removeOnLayoutChangeListener(rot) }
		})
		parent.addView(dim, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
		sheet.scaleX = 0.96f; sheet.scaleY = 0.96f
		dim.animate().alpha(1f).setDuration(160).start()
		sheet.animate().scaleX(1f).scaleY(1f).setDuration(200).setInterpolator(android.view.animation.DecelerateInterpolator()).start()
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
