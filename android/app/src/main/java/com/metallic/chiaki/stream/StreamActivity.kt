// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.stream

import android.animation.Animator
import android.animation.AnimatorListenerAdapter
import android.app.AlertDialog
import android.graphics.Matrix
import android.graphics.drawable.GradientDrawable
import android.os.*
import android.view.*
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import com.metallic.chiaki.anyplay.AnyPlayHost
import com.metallic.chiaki.anyplay.AnyPlayStyle
import com.metallic.chiaki.anyplay.AnyPlayWebDialog
import com.metallic.chiaki.anyplay.GamepadView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.IntentCompat
import androidx.lifecycle.lifecycleScope
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.core.view.isGone
import androidx.core.view.isVisible
import androidx.fragment.app.Fragment
import androidx.lifecycle.*
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import com.metallic.chiaki.R
import com.metallic.chiaki.common.Preferences
import com.metallic.chiaki.common.ext.viewModelFactory
import com.metallic.chiaki.databinding.ActivityStreamBinding
import com.metallic.chiaki.lib.ConnectInfo
import com.metallic.chiaki.lib.ConnectVideoProfile
import com.metallic.chiaki.session.*
import com.metallic.chiaki.touchcontrols.DefaultTouchControlsFragment
import com.metallic.chiaki.touchcontrols.TouchControlsFragment
import com.metallic.chiaki.touchcontrols.TouchpadOnlyFragment
import com.metallic.chiaki.anyplay.AnyPlayCloud
import com.metallic.chiaki.anyplay.AnyPlayQuality
import com.metallic.chiaki.anyplay.PlayError
import com.metallic.chiaki.anyplay.PlayReady
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import org.json.JSONObject
import kotlin.math.min

private sealed class DialogContents
private object StreamQuitDialog: DialogContents()
private object CreateErrorDialog: DialogContents()
private object PinRequestDialog: DialogContents()
private object PsnFailedDialog: DialogContents()
private object AnyPlayEndDialog: DialogContents()

class StreamActivity : AppCompatActivity()
{
	companion object
	{
		const val EXTRA_CONNECT_INFO = "connect_info"
		const val EXTRA_ANYPLAY = "anyplay"   // гра через сервер AnyPlay: час броні контролює сервер
		const val EXTRA_ANYPLAY_ADMIN = "anyplay_admin"   // грає адмін: без нагадувань про кінець гри
		const val EXTRA_ANYPLAY_GUEST = "anyplay_guest"   // гостьовий доступ (К5): без «Продовжити бронювання»
		private const val INPUT_RECENT_MS = 20000L
		private const val ANYPLAY_BEAT_MS = 20000L
		private const val ANYPLAY_BANNER_MS = 20000L
		private const val HIDE_UI_TIMEOUT_MS = 2000L
	}

	private lateinit var viewModel: StreamViewModel
	private lateinit var binding: ActivityStreamBinding
	private lateinit var insetsController: WindowInsetsControllerCompat

	private val uiVisibilityHandler = Handler(Looper.getMainLooper())

	override fun onCreate(savedInstanceState: Bundle?)
	{
		super.onCreate(savedInstanceState)

		val connectInfo = IntentCompat.getParcelableExtra(intent, EXTRA_CONNECT_INFO, ConnectInfo::class.java)
		if(connectInfo == null)
		{
			finish()
			return
		}

		viewModel = ViewModelProvider(this, viewModelFactory {
			StreamViewModel(application, connectInfo)
		})[StreamViewModel::class.java]

		viewModel.input.observe(this)

		binding = ActivityStreamBinding.inflate(layoutInflater)
		setContentView(binding.root)

		WindowCompat.setDecorFitsSystemWindows(window, false)
		insetsController = WindowCompat.getInsetsController(window, window.decorView)
		insetsController.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE

		ViewCompat.setOnApplyWindowInsetsListener(window.decorView) { _, insets ->
			val systemBars = insets.isVisible(WindowInsetsCompat.Type.systemBars())
			if(systemBars)
				showOverlay()
			else
				hideOverlay()
			insets
		}

		viewModel.onScreenControlsEnabled.observe(this, Observer {
			if(binding.onScreenControlsSwitch.isChecked != it)
				binding.onScreenControlsSwitch.isChecked = it
			if(binding.onScreenControlsSwitch.isChecked)
				binding.touchpadOnlySwitch.isChecked = false
		})
		binding.onScreenControlsSwitch.setOnCheckedChangeListener { _, isChecked ->
			viewModel.setOnScreenControlsEnabled(isChecked)
			showOverlay()
		}

		viewModel.touchpadOnlyEnabled.observe(this, Observer {
			if(binding.touchpadOnlySwitch.isChecked != it)
				binding.touchpadOnlySwitch.isChecked = it
			if(binding.touchpadOnlySwitch.isChecked)
				binding.onScreenControlsSwitch.isChecked = false
		})
		binding.touchpadOnlySwitch.setOnCheckedChangeListener { _, isChecked ->
			viewModel.setTouchpadOnlyEnabled(isChecked)
			showOverlay()
		}

		binding.displayModeToggle.addOnButtonCheckedListener { _, _, _ ->
			adjustStreamViewAspect()
			showOverlay()
		}

		if(anyplay)
		{
			// AnyPlay: своє меню (кнопка «⋯» на джойстику або «Назад»), стара нижня панель не потрібна
			binding.overlay.isGone = true
			binding.root.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ -> arrangeForOrientation() }
			viewModel.onScreenControlsEnabled.observe(this, Observer {
				anyplayControls = it != false
				binding.root.post { arrangeForOrientation() }
			})
			binding.root.post {
				findViewById<GamepadView>(R.id.gamepadView)?.menuCallback = { showAnyPlayMenu() }
				arrangeForOrientation()
			}
		}

		//viewModel.session.attachToTextureView(textureView)
		viewModel.session.attachToSurfaceView(binding.surfaceView)
		viewModel.session.state.observe(this, Observer { this.stateChanged(it) })
		adjustStreamViewAspect()

		if(Preferences(this).rumbleEnabled)
		{
			val vibrator = getSystemService(VIBRATOR_SERVICE) as Vibrator
			viewModel.session.rumbleState.observe(this, Observer {
				val amplitude = min(255, (it.left.toInt() + it.right.toInt()) / 2)
				vibrator.cancel()
				if(amplitude == 0)
					return@Observer
				if(Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
					vibrator.vibrate(VibrationEffect.createOneShot(1000, amplitude))
				else
					vibrator.vibrate(1000)
			})
		}
	}

	private var controlsJob: Job? = null

	override fun onAttachFragment(fragment: Fragment)
	{
		super.onAttachFragment(fragment)
		if(fragment is TouchControlsFragment)
		{
			controlsJob?.cancel()
			controlsJob = fragment.controllerState
				.onEach {
					viewModel.input.touchControllerState = it
					anyplayTouchAt = SystemClock.elapsedRealtime()
				}
				.launchIn(lifecycleScope)
			fragment.onScreenControlsEnabled = viewModel.onScreenControlsEnabled
			if(fragment is TouchpadOnlyFragment)
				fragment.touchpadOnlyEnabled = viewModel.touchpadOnlyEnabled
		}
	}

	private val anyplay get() = intent.getBooleanExtra(EXTRA_ANYPLAY, false)
	private var anyplayFirstResume = true
	private var anyplayBeatJob: Job? = null
	private var anyplayResumeJob: Job? = null
	private var anyplayQualityJob: Job? = null
	private var anyplayRemindJob: Job? = null
	private val anyplayAdmin get() = intent.getBooleanExtra(EXTRA_ANYPLAY_ADMIN, false)
	// кінець гри (усієї, разом із бронями впритул) за SystemClock.elapsedRealtime(), 0 — ще не знаємо
	@Volatile private var anyplayEndAt = 0L
	@Volatile private var anyplayContinues = false   // після цієї броні одразу йде наступна: гра не закінчується
	@Volatile private var anyplayLoss = 0.0
	@Volatile private var anyplayControls = true
	@Volatile private var anyplayGuest = false        // гостьовий доступ: граємо, поки приставка вільна
	// телеметрія (К1): коли востаннє керували екранними кнопками, геймпадом, клавіатурою; лічильники відео з минулого сигналу
	@Volatile private var anyplayTouchAt = 0L
	@Volatile private var anyplayPadAt = 0L
	@Volatile private var anyplayKeysAt = 0L
	private var statSession: Any? = null
	private var statPrev: LongArray? = null
	private var statPrevAt = 0L
	@Volatile private var statLossSum = 0.0
	@Volatile private var statLossN = 0
	private var anyplayReminded = 0                  // 10 — уже нагадали перед цим кінцем (один раз, за 10 хв), 0 — ще ні
	private var anyplayBanner: View? = null
	private var anyplayMenu: AnyPlayWebDialog? = null

	override fun onResume()
	{
		super.onResume()
		hideSystemUI()
		if(!anyplay)
		{
			viewModel.session.resume()
			return
		}
		if(anyplayFirstResume)
		{
			anyplayFirstResume = false
			anyplayGuest = intent.getBooleanExtra(EXTRA_ANYPLAY_GUEST, false)
			viewModel.session.resume()
		}
		else
			anyplayFreshConnect(0)   // після згортання — нове підключення зі свіжим ключем від сервера (старий діє недовго)
		anyplayQualityJob?.cancel()
		anyplayQualityJob = lifecycleScope.launch { anyplayWatchQuality() }
		anyplayBeatJob?.cancel()
		anyplayBeatJob = lifecycleScope.launch {
			while(isActive)
			{
				val stats = anyplayStats()
				val r = withContext(Dispatchers.IO) { AnyPlayCloud.heartbeat(this@StreamActivity, true, stats) }
				if(r.status == 200 && r.json.has("left"))
				{
					anyplayEndAt = SystemClock.elapsedRealtime() + r.json.optLong("left") * 1000
					anyplayContinues = r.json.optBoolean("continues")
					anyplayGuest = r.json.optBoolean("guest")
				}
				if(r.status == 200 && r.json.optBoolean("sendLog"))
					AnyPlayCloud.uploadLog(this@StreamActivity, "request", "Адміністратор попросив журнал")
				if(r.status == 401)
					anyplayEnd("Доступ скасовано адміністратором.")
				else if(r.status == 200 && !r.json.optBoolean("continue", true))
					anyplayEnd(if(r.json.optString("reason") == "kicked") "Сеанс завершив адміністратор AnyPlay."
						else "Час твоєї броні вийшов. Дякуємо за гру! Забронювати ще можна в боті.")
				delay(ANYPLAY_BEAT_MS)
			}
		}
		anyplayRemindJob?.cancel()
		anyplayRemindJob = lifecycleScope.launch {
			while(isActive)
			{
				anyplayCheckReminder()
				delay(2000)
			}
		}
	}

	/** Скільки секунд лишилось до кінця гри, -1 — ще не знаємо */
	private fun anyplayLeft(): Long = if(anyplayEndAt > 0) maxOf(0L, (anyplayEndAt - SystemClock.elapsedRealtime()) / 1000) else -1L

	/** Один раз, за 10 хвилин до кінця гри — банер угорі з кнопкою «Продовжити» (не для адміна і не коли далі ще бронь) */
	private fun anyplayCheckReminder()
	{
		val left = anyplayLeft()
		if(left < 0)
			return
		if(left > 11 * 60)
		{
			anyplayReminded = 0   // гру продовжили: нагадаємо знову перед новим кінцем
			return
		}
		if(anyplayAdmin || anyplayGuest || anyplayContinues || left <= 0)
			return
		val step = if(left <= 10 * 60) 10 else return
		if(anyplayReminded != 0 && anyplayReminded <= step)
			return
		// вікно з помилкою або картинка ще підключається — спробуємо за кілька секунд
		if(dialogContents != null || viewModel.session.state.value != StreamStateConnected)
			return
		anyplayReminded = step
		// у відкритому меню час і так видно вгорі
		if(anyplayMenu == null)
			anyplayShowBanner((left + 59) / 60)
	}

	private val anyplayHideBannerRunnable = Runnable { anyplayHideBanner() }

	private fun anyplayShowBanner(minutes: Long)
	{
		anyplayHideBanner()
		val c = this
		val dp = resources.displayMetrics.density
		fun px(v: Int) = (v * dp).toInt()
		val box = LinearLayout(c).apply {
			orientation = LinearLayout.HORIZONTAL
			gravity = Gravity.CENTER_VERTICAL
			background = GradientDrawable().apply {
				setColor(AnyPlayStyle.DIALOG)
				cornerRadius = 3 * dp
				setStroke(px(1), AnyPlayStyle.EDGE)
			}
			setPadding(px(16), px(10), px(6), px(10))
			elevation = 8 * dp
			isClickable = true   // дотики по банеру не йдуть у гру
		}
		val texts = LinearLayout(c).apply { orientation = LinearLayout.VERTICAL }
		texts.addView(TextView(c).apply {
			text = "Лишилось $minutes хв. Продовжити бронювання?"
			typeface = AnyPlayStyle.display(c)
			isAllCaps = true
			letterSpacing = 0.08f
			textSize = 16f
			setTextColor(AnyPlayStyle.GOLD)
		})
		texts.addView(TextView(c).apply {
			text = "Меню AnyPlay: кнопка ⋯ на екрані або «Назад» на телефоні"
			typeface = AnyPlayStyle.body(c)
			textSize = 12f
			setTextColor(AnyPlayStyle.MUTE)
		})
		box.addView(texts, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
		box.addView(TextView(c).apply {
			text = "Продовжити"
			gravity = Gravity.CENTER
			minHeight = px(40)
			AnyPlayStyle.button(this, true)
			setOnClickListener {
				anyplayHideBanner()
				showAnyPlayMenu("menu:extend")
			}
		}, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).also { it.marginStart = px(12) })
		box.addView(TextView(c).apply {
			text = "✕"
			contentDescription = "Закрити"
			textSize = 18f
			setTextColor(AnyPlayStyle.MUTE)
			setPadding(px(12), px(6), px(8), px(6))
			setOnClickListener { anyplayHideBanner() }
		})
		val cut = ViewCompat.getRootWindowInsets(binding.root)?.getInsets(WindowInsetsCompat.Type.displayCutout())
		val side = px(12) + maxOf(cut?.left ?: 0, cut?.right ?: 0)
		val lp = FrameLayout.LayoutParams(minOf(binding.root.width - 2 * side, px(560)), ViewGroup.LayoutParams.WRAP_CONTENT,
			Gravity.TOP or Gravity.CENTER_HORIZONTAL)
		lp.topMargin = (cut?.top ?: 0) + px(12)
		binding.root.addView(box, lp)
		box.alpha = 0f
		box.animate().alpha(1f).setDuration(200).start()
		anyplayBanner = box
		uiVisibilityHandler.removeCallbacks(anyplayHideBannerRunnable)
		uiVisibilityHandler.postDelayed(anyplayHideBannerRunnable, ANYPLAY_BANNER_MS)
	}

	private fun anyplayHideBanner()
	{
		uiVisibilityHandler.removeCallbacks(anyplayHideBannerRunnable)
		anyplayBanner?.let { binding.root.removeView(it) }
		anyplayBanner = null
	}

	/** Нове підключення: свіжий ключ від сервера й поточна якість з налаштувань */
	private fun anyplayFreshConnect(waitMs: Long)
	{
		binding.progressBar.visibility = View.VISIBLE
		anyplayResumeJob?.cancel()
		anyplayResumeJob = lifecycleScope.launch {
			if(waitMs > 0)
				delay(waitMs)   // приставці треба мить, щоб закрити попередню трансляцію
			val target = withContext(Dispatchers.IO) {
				val r = AnyPlayCloud.session(this@StreamActivity)
				if(r.ok)
					anyplayGuest = r.json.optBoolean("guest")
				r.json.optJSONObject("booking")?.let { b ->
					if(b.optLong("end") > 0 && r.json.optLong("now") > 0)
					{
						anyplayEndAt = SystemClock.elapsedRealtime() + (b.optLong("end") - r.json.optLong("now")) * 1000
						anyplayContinues = b.optBoolean("continues")
					}
				}
				if(r.ok && r.json.optString("state") == "play")
					AnyPlayCloud.playTarget(this@StreamActivity, r.json)
				else if(r.ok)
					PlayError("Час твоєї броні вийшов. Дякуємо за гру!")
				else if(!AnyPlayCloud.online(this@StreamActivity))
					PlayError("Немає інтернету на телефоні. Увімкни Wi-Fi або мобільний інтернет і підключись знову з головного екрана.", "NET offline")
						.also { AnyPlayCloud.noteError(this@StreamActivity, it) }
				else
					PlayError("Немає зв'язку з сервером AnyPlay. Спробуй підключитись знову з головного екрана.", "AP-HTTP ${r.status}")
						.also { AnyPlayCloud.noteError(this@StreamActivity, it) }
			}
			when(target)
			{
				is PlayReady ->
				{
					viewModel.session.connectInfo = target.connectInfo
					viewModel.session.resume()
				}
				is PlayError -> anyplayEnd(target.text, target.code)
			}
		}
	}

	/**
	 * Автоякість: стежимо за втратами пакетів. Якщо інтернет довго не встигає за картинкою —
	 * рівень нижче і перепідключення. Якщо гра довго йде рівно — наступного разу пробуємо рівень вище.
	 */
	private suspend fun anyplayWatchQuality()
	{
		var ticks = 0
		var bad = 0
		var good = 0
		while(true)
		{
			var loss = 0.0
			for(i in 0 until 4)
			{
				delay(500)
				loss += (viewModel.session.session?.packetLoss() ?: 0.0) / 4
			}
			anyplayLoss = if(loss.isNaN()) 0.0 else loss
			if(viewModel.session.state.value == StreamStateConnected)
			{
				statLossSum += anyplayLoss
				statLossN++
			}
			if(viewModel.session.state.value != StreamStateConnected || !AnyPlayQuality.auto(this))
			{
				ticks = 0
				bad = 0
				continue
			}
			ticks++
			if(loss > 0.03)
			{
				bad += 2
				good = 0
			}
			else
			{
				if(bad > 0)
					bad--
				good++
			}
			if(good == 300)   // 10 хвилин без втрат
				AnyPlayQuality.good(this)
			if(ticks >= 8 && bad >= 12)
			{
				ticks = 0
				bad = 0
				good = 0
				val title = AnyPlayQuality.down(this) ?: continue
				Toast.makeText(this, "Інтернет не встигає за картинкою. Знижую якість до «$title» і підключаюсь заново…", Toast.LENGTH_LONG).show()
				viewModel.session.shutdown()
				anyplayFreshConnect(2500)
			}
		}
	}

	/**
	 * Телеметрія для heartbeat (К1) за проміжок з минулого сигналу. null — картинки ще немає
	 * (перший сигнал нової трансляції лише запам'ятовує лічильники).
	 */
	private fun anyplayStats(): JSONObject?
	{
		val session = viewModel.session.session
		val v = session?.videoStats()
		val now = SystemClock.elapsedRealtime()
		if(session == null || v == null || v.size < 4 || viewModel.session.state.value != StreamStateConnected)
		{
			statSession = null
			statPrev = null
			return null
		}
		val prev = statPrev
		val fresh = statSession !== session || prev == null || v[0] < prev[0]
		statSession = session
		statPrev = v
		val dt = (now - statPrevAt) / 1000.0
		statPrevAt = now
		val lossN = statLossN
		val loss = if(lossN > 0) statLossSum / lossN else anyplayLoss
		statLossSum = 0.0
		statLossN = 0
		if(fresh || prev == null || dt < 1.0)
			return null
		val profile = viewModel.session.connectInfo.videoProfile
		fun round(x: Double, d: Int): Double { val m = Math.pow(10.0, d.toDouble()); return Math.round(x * m) / m }
		return JSONObject()
			.put("platform", "android")
			.put("build", AnyPlayCloud.BUILD)
			.put("input", anyplayInput())
			.put("layout", "universal")   // на телефоні одна розкладка: кнопки як на геймпаді PS5
			.put("mode", "")
			.put("quality", AnyPlayQuality.level(this))
			.put("auto", AnyPlayQuality.auto(this))
			.put("width", profile.width)
			.put("height", profile.height)
			.put("codec", if(profile.codec == com.metallic.chiaki.lib.Codec.CODEC_H264) "h264" else "h265")
			.put("fpsStream", round((v[0] - prev[0]) / dt, 1))
			.put("fpsShown", round((v[1] - prev[1]) / dt, 1))
			.put("bitrate", round((v[3] - prev[3]) * 8.0 / dt / 1e6, 2))
			.put("loss", round(loss * 100.0, 2))
			.put("dropped", v[2] - prev[2])
			.put("local", false)
	}

	/** Чим керували останні 20 с: справжній геймпад, клавіатура чи кнопки на екрані */
	private fun anyplayInput(): String
	{
		val now = SystemClock.elapsedRealtime()
		val recent = listOf("gamepad" to anyplayPadAt, "keyboard" to anyplayKeysAt, "touch" to anyplayTouchAt)
			.filter { it.second > 0 && now - it.second <= INPUT_RECENT_MS }
			.maxByOrNull { it.second }
		return recent?.first ?: if(anyplayControls) "touch" else "gamepad"
	}

	/** Сервер AnyPlay завершив гру: зупиняємо стрім і пояснюємо чому */
	private fun anyplayEnd(text: String, code: String = "")
	{
		if(dialogContents == AnyPlayEndDialog || isFinishing)
			return
		anyplayBeatJob?.cancel()
		anyplayQualityJob?.cancel()
		anyplayResumeJob?.cancel()
		anyplayRemindJob?.cancel()
		anyplayHideBanner()
		anyplayMenu?.dismiss()
		viewModel.session.shutdown()
		dialog?.dismiss()
		val d = MaterialAlertDialogBuilder(this)
			.setMessage(AnyPlayStyle.errorMessage(text, code))
			.setCancelable(false)
			.setPositiveButton("Зрозуміло") { _, _ ->
				dialog = null
				finish()
			}
			.create()
		dialogContents = AnyPlayEndDialog
		d.show()
		AnyPlayStyle.style(d)
	}

	override fun onPause()
	{
		super.onPause()
		anyplayBeatJob?.cancel()
		anyplayResumeJob?.cancel()
		anyplayQualityJob?.cancel()
		anyplayRemindJob?.cancel()
		viewModel.session.pause()
		if(anyplay)
			AnyPlayCloud.markLive(this, false)
		// вийшли з гри: одразу кажемо серверу, що стріму тут більше немає — тоді на іншому пристрої клієнта
		// одразу з'явиться «Грати» (інакше він чекав би, доки застаріє останній сигнал, до 90 с)
		if(anyplay && isFinishing)
		{
			val ctx = applicationContext
			Thread { AnyPlayCloud.heartbeat(ctx, false) }.start()
		}
	}

	override fun onDestroy()
	{
		super.onDestroy()
		controlsJob?.cancel()
	}

	private fun reconnect()
	{
		viewModel.session.shutdown()
		viewModel.session.resume()
	}

	private val hideSystemUIRunnable = Runnable { hideSystemUI() }

	/** AnyPlay: вертикально — картинка зверху, джойстик під нею; горизонтально — картинка на весь екран */
	private fun arrangeForOrientation()
	{
		val w = binding.root.width
		val h = binding.root.height
		if(w == 0 || h == 0)
			return
		val cut = ViewCompat.getRootWindowInsets(binding.root)?.getInsets(WindowInsetsCompat.Type.displayCutout())
		val controls = viewModel.onScreenControlsEnabled.value != false
		val portrait = h > w
		val lp = binding.aspectRatioLayout.layoutParams as FrameLayout.LayoutParams
		var videoBottom = 0
		val wantHeight: Int
		val wantGravity: Int
		val wantTop: Int
		if(portrait && controls)
		{
			wantTop = cut?.top ?: 0
			wantHeight = w * 9 / 16
			wantGravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
			videoBottom = wantTop + wantHeight
		}
		else
		{
			wantTop = 0
			wantHeight = ViewGroup.LayoutParams.MATCH_PARENT
			wantGravity = Gravity.CENTER
		}
		if(lp.height != wantHeight || lp.gravity != wantGravity || lp.topMargin != wantTop)
		{
			lp.height = wantHeight
			lp.gravity = wantGravity
			lp.topMargin = wantTop
			binding.aspectRatioLayout.layoutParams = lp
		}
		findViewById<GamepadView>(R.id.gamepadView)?.let {
			it.safeLeft = cut?.left ?: 0
			it.safeRight = cut?.right ?: 0
			it.safeBottom = cut?.bottom ?: 0
			it.videoBottom = videoBottom
			it.refreshLayout()
		}
	}

	/** Меню AnyPlay під час гри (кнопка «⋯» на джойстику, «Назад», банер «Продовжити»): сторінка в стилі паузи GTA */
	private fun showAnyPlayMenu(page: String = "menu")
	{
		if(dialogContents != null || anyplayMenu != null)
			return
		anyplayHideBanner()
		val d = AnyPlayWebDialog(this, page, anyplayHost, overGame = true) {
			anyplayMenu = null
			hideSystemUI()
		}
		anyplayMenu = d
		d.show()
	}

	/** Дані й команди для меню під час гри */
	private val anyplayHost = object: AnyPlayHost
	{
		override fun info(): String = JSONObject()
			.put("left", anyplayLeft())
			.put("loss", anyplayLoss)
			.put("controls", anyplayControls)
			.put("admin", anyplayAdmin)
			.put("guest", anyplayGuest)
			.put("quality", AnyPlayQuality.name(this@StreamActivity))
			.toString()

		override fun action(name: String, arg: String)
		{
			when(name)
			{
				"controls" ->
				{
					viewModel.setOnScreenControlsEnabled(!anyplayControls)
					anyplayMenu?.dismiss()
				}
				"exit" ->
				{
					anyplayMenu?.dismiss()
					finish()
				}
				// гру продовжили й оплатили: новий кінець гри — одразу, не чекаючи наступного сигналу серверу
				"refresh" -> lifecycleScope.launch {
					val r = withContext(Dispatchers.IO) { AnyPlayCloud.heartbeat(this@StreamActivity, true) }
					if(r.status == 200 && r.json.has("left"))
					{
						anyplayEndAt = SystemClock.elapsedRealtime() + r.json.optLong("left") * 1000
						anyplayContinues = r.json.optBoolean("continues")
					}
				}
			}
		}

		override fun qualityChanged()
		{
			// нова якість діє з нового підключення
			Toast.makeText(this@StreamActivity, "Якість: ${AnyPlayQuality.name(this@StreamActivity)}. Підключаюсь заново…", Toast.LENGTH_LONG).show()
			anyplayMenu?.dismiss()
			viewModel.session.shutdown()
			anyplayFreshConnect(2500)
		}
	}

	@Deprecated("Deprecated in Java")
	override fun onBackPressed()
	{
		if(anyplay)
			showAnyPlayMenu()
		else
			super.onBackPressed()
	}

	private fun showOverlay()
	{
		if(anyplay)
			return
		binding.overlay.isVisible = true
		binding.overlay.animate()
			.alpha(1.0f)
			.setListener(object: AnimatorListenerAdapter()
			{
				override fun onAnimationEnd(animation: Animator)
				{
					binding.overlay.alpha = 1.0f
				}
			})
		uiVisibilityHandler.removeCallbacks(hideSystemUIRunnable)
		uiVisibilityHandler.postDelayed(hideSystemUIRunnable, HIDE_UI_TIMEOUT_MS)
	}

	private fun hideOverlay()
	{
		binding.overlay.animate()
			.alpha(0.0f)
			.setListener(object: AnimatorListenerAdapter()
			{
				override fun onAnimationEnd(animation: Animator)
				{
					binding.overlay.isGone = true
				}
			})
	}

	override fun onWindowFocusChanged(hasFocus: Boolean)
	{
		super.onWindowFocusChanged(hasFocus)
		if(hasFocus)
			hideSystemUI()
	}

	private fun hideSystemUI()
	{
		insetsController.hide(WindowInsetsCompat.Type.systemBars())
	}

	private var dialogContents: DialogContents? = null
	private var dialog: AlertDialog? = null
		set(value)
		{
			field = value
			if(value == null)
				dialogContents = null
		}

	private fun stateChanged(state: StreamState)
	{
		binding.progressBar.visibility = if(state == StreamStateConnecting) View.VISIBLE else View.GONE
		if(anyplay && state == StreamStateConnected)
			AnyPlayCloud.markLive(this, true)
		if(anyplay && (state is StreamStateQuit || state is StreamStatePsnFailed))
			AnyPlayCloud.markLive(this, false)

		when(state)
		{
			is StreamStateQuit ->
			{
				if(dialogContents != StreamQuitDialog && dialogContents != AnyPlayEndDialog && anyplay && !isFinishing)
				{
					// AnyPlay: трансляція обірвалась не з нашої волі (приставка закрила її, вийшла з мережі тощо).
					// Раніше без помилки екран гри просто закривався. Тепер кажемо, що сталось, і пропонуємо підключитись знову.
					val reasonStr = state.reasonString?.takeIf { it.isNotBlank() }
					val code = "QUIT ${state.reason.value}" + (reasonStr?.let { ": ${it.take(60)}" } ?: "")
					val text = if(state.reason.isError)
						"Зв'язок з приставкою обірвався. Спробуй підключитись знову. Якщо повториться, напиши в підтримку."
					else
						"Приставка завершила трансляцію. Так буває, коли PS5 перезапускається або до неї підключився інший пристрій. Можна підключитись знову."
					AnyPlayCloud.noteError(this, PlayError(text, code))
					AnyPlayCloud.uploadLog(this, "error", "Трансляція закрилась: $code")
					dialog?.dismiss()
					val d = MaterialAlertDialogBuilder(this)
						.setMessage(AnyPlayStyle.errorMessage(text, code))
						.setCancelable(false)
						.setPositiveButton("Підключитись знову") { _, _ ->
							dialog = null
							dialogContents = null
							viewModel.session.shutdown()
							anyplayFreshConnect(1500)
						}
						.setNegativeButton("Вийти") { _, _ ->
							dialog = null
							finish()
						}
						.create()
					dialogContents = StreamQuitDialog
					d.show()
					AnyPlayStyle.style(d)
				}
				else if(dialogContents != StreamQuitDialog && dialogContents != AnyPlayEndDialog)
				{
					if(state.reason.isError)
					{
						dialog?.dismiss()
						val reasonStr = state.reasonString
						val dialog = MaterialAlertDialogBuilder(this)
							.setMessage(getString(R.string.alert_message_session_quit, state.reason.toString())
									+ (if(reasonStr != null) "\n$reasonStr" else ""))
							.setPositiveButton(R.string.action_reconnect) { _, _ ->
								dialog = null
								reconnect()
							}
							.setOnCancelListener {
								dialog = null
								finish()
							}
							.setNegativeButton(R.string.action_quit_session) { _, _ ->
								dialog = null
								finish()
							}
							.create()
						dialogContents = StreamQuitDialog
						dialog.show()
						AnyPlayStyle.style(dialog)
					}
					else
						finish()
				}
			}

			is StreamStatePsnFailed ->
			{
				if(dialogContents != PsnFailedDialog && dialogContents != AnyPlayEndDialog)
				{
					dialog?.dismiss()
					val e = AnyPlayCloud.connectError(this, state.step, state.error.value, state.diag)
					if(anyplay)
						AnyPlayCloud.uploadLog(this, "error", "Не вдалося з'єднатись через PSN: ${e.code}")
					val dialog = MaterialAlertDialogBuilder(this)
						.setMessage(AnyPlayStyle.errorMessage(e.text, e.code))
						.setPositiveButton("Спробувати ще раз") { _, _ ->
							dialog = null
							if(anyplay)
							{
								viewModel.session.shutdown()
								anyplayFreshConnect(0)   // свіжий ключ від сервера: старий міг уже не діяти
							}
							else
								reconnect()
						}
						.setOnCancelListener {
							dialog = null
							finish()
						}
						.setNegativeButton("Вийти") { _, _ ->
							dialog = null
							finish()
						}
						.create()
					dialogContents = PsnFailedDialog
					dialog.show()
					AnyPlayStyle.style(dialog)
				}
			}

			is StreamStateCreateError ->
			{
				if(dialogContents != CreateErrorDialog)
				{
					dialog?.dismiss()
					val dialog = MaterialAlertDialogBuilder(this)
						.setMessage(getString(R.string.alert_message_session_create_error, state.error.errorCode.toString()))
						.setOnDismissListener {
							dialog = null
							finish()
						}
						.setNegativeButton(R.string.action_quit_session) { _, _ -> }
						.create()
					dialogContents = CreateErrorDialog
					dialog.show()
				}
			}

			is StreamStateLoginPinRequest ->
			{
				if(dialogContents != PinRequestDialog)
				{
					dialog?.dismiss()

					val view = layoutInflater.inflate(R.layout.dialog_login_pin, null)
					val pinEditText = view.findViewById<EditText>(R.id.pinEditText)

					val dialog = MaterialAlertDialogBuilder(this)
						.setMessage(
							if(state.pinIncorrect)
								R.string.alert_message_login_pin_request_incorrect
							else
								R.string.alert_message_login_pin_request)
						.setView(view)
						.setPositiveButton(R.string.action_login_pin_connect) { _, _ ->
							dialog = null
							viewModel.session.setLoginPin(pinEditText.text.toString())
						}
						.setOnCancelListener {
							dialog = null
							finish()
						}
						.setNegativeButton(R.string.action_quit_session) { _, _ ->
							dialog = null
							finish()
						}
						.create()
					dialogContents = PinRequestDialog
					dialog.show()
				}
			}
			else ->{}
		}
	}

	private fun adjustTextureViewAspect(textureView: TextureView)
	{
		val trans = TextureViewTransform(viewModel.session.connectInfo.videoProfile, textureView)
		val resolution = trans.resolutionFor(TransformMode.fromButton(binding.displayModeToggle.checkedButtonId))
		Matrix().also {
			textureView.getTransform(it)
			it.setScale(resolution.width / trans.viewWidth, resolution.height / trans.viewHeight)
			it.postTranslate((trans.viewWidth - resolution.width) * 0.5f, (trans.viewHeight - resolution.height) * 0.5f)
			textureView.setTransform(it)
		}
	}

	private fun adjustSurfaceViewAspect()
	{
		val videoProfile = viewModel.session.connectInfo.videoProfile
		binding.aspectRatioLayout.aspectRatio = videoProfile.width.toFloat() / videoProfile.height.toFloat()
		binding.aspectRatioLayout.mode = TransformMode.fromButton(binding.displayModeToggle.checkedButtonId)
	}

	private fun adjustStreamViewAspect() = adjustSurfaceViewAspect()

	override fun dispatchKeyEvent(event: KeyEvent): Boolean
	{
		// телеметрія: геймпад чи клавіатура (системні кнопки телефона, як «Назад», не рахуємо)
		val src = event.source
		if(src and InputDevice.SOURCE_GAMEPAD == InputDevice.SOURCE_GAMEPAD || src and InputDevice.SOURCE_JOYSTICK == InputDevice.SOURCE_JOYSTICK)
			anyplayPadAt = SystemClock.elapsedRealtime()
		else if(event.device?.isVirtual == false && event.device?.keyboardType == InputDevice.KEYBOARD_TYPE_ALPHABETIC)
			anyplayKeysAt = SystemClock.elapsedRealtime()
		return viewModel.input.dispatchKeyEvent(event) || super.dispatchKeyEvent(event)
	}

	override fun onGenericMotionEvent(event: MotionEvent): Boolean
	{
		if(event.source and InputDevice.SOURCE_CLASS_JOYSTICK == InputDevice.SOURCE_CLASS_JOYSTICK)
			anyplayPadAt = SystemClock.elapsedRealtime()
		return viewModel.input.onGenericMotionEvent(event) || super.onGenericMotionEvent(event)
	}
}

enum class TransformMode
{
	FIT,
	STRETCH,
	ZOOM;

	companion object
	{
		fun fromButton(displayModeButtonId: Int)
			= when (displayModeButtonId)
			{
				R.id.display_mode_stretch_button -> STRETCH
				R.id.display_mode_zoom_button -> ZOOM
				else -> FIT
			}
	}
}

class TextureViewTransform(private val videoProfile: ConnectVideoProfile, private val textureView: TextureView)
{
	private val contentWidth : Float get() = videoProfile.width.toFloat()
	private val contentHeight : Float get() = videoProfile.height.toFloat()
	val viewWidth : Float get() = textureView.width.toFloat()
	val viewHeight : Float get() = textureView.height.toFloat()
	private val contentAspect : Float get() =  contentHeight / contentWidth

	fun resolutionFor(mode: TransformMode): Resolution
		= when(mode)
		{
			TransformMode.STRETCH -> strechedResolution
			TransformMode.ZOOM -> zoomedResolution
			TransformMode.FIT -> normalResolution
		}

	private val strechedResolution get() = Resolution(viewWidth, viewHeight)

	private val zoomedResolution get() =
		if(viewHeight > viewWidth * contentAspect)
		{
			val zoomFactor = viewHeight / contentHeight
			Resolution(contentWidth * zoomFactor, viewHeight)
		}
		else
		{
			val zoomFactor = viewWidth / contentWidth
			Resolution(viewWidth, contentHeight * zoomFactor)
		}

	private val normalResolution get() =
		if(viewHeight > viewWidth * contentAspect)
			Resolution(viewWidth, viewWidth * contentAspect)
		else
			Resolution(viewHeight / contentAspect, viewHeight)
}


data class Resolution(val width: Float, val height: Float)
