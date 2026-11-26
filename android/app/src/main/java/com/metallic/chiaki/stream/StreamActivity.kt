// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.stream

import com.metallic.chiaki.anyplay.AnyPlayDiag
import android.animation.Animator
import android.animation.AnimatorListenerAdapter
import android.app.AlertDialog
import android.graphics.Matrix
import android.graphics.drawable.GradientDrawable
import android.os.*
import android.util.Log
import android.view.*
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import com.metallic.chiaki.anyplay.AnyPlayHost
import com.metallic.chiaki.anyplay.AnyPlayLoading
import com.metallic.chiaki.anyplay.AnyPlayStyle
import com.metallic.chiaki.anyplay.AnyPlayWebDialog
import com.metallic.chiaki.anyplay.GamepadView
import com.metallic.chiaki.anyplay.AnyPlayPicture
import com.metallic.chiaki.anyplay.PadEditor
import com.metallic.chiaki.anyplay.PadLayout
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
import com.metallic.chiaki.anyplay.AnyPlayLive
import com.metallic.chiaki.anyplay.AnyPlayHaptics
import com.metallic.chiaki.anyplay.AnyPlayStatsHud
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
		// «Грати тут» (гру забрали з іншого пристрою): скільки мс ще пробувати, поки приставка каже «уже зайнята»
		const val EXTRA_ANYPLAY_TAKEOVER_MS = "anyplay_takeover_ms"
		// «Передати повністю» (етап 7): граємо в бронь друга — його ім'я (порожньо — своя гра)
		const val EXTRA_ANYPLAY_HELPER_OF = "anyplay_helper_of"
		private const val TAKEOVER_RETRY_MS = 3000L
		private const val HANDOFF_CHECK_MS = 3000L
		private const val QUIT_RP_IN_USE = 4   // CHIAKI_QUIT_REASON_SESSION_REQUEST_RP_IN_USE
		private const val INPUT_RECENT_MS = 20000L
		private const val ANYPLAY_BEAT_MS = 20000L
		private const val ANYPLAY_BANNER_MS = 20000L
		private const val HIDE_UI_TIMEOUT_MS = 2000L
		/** 118.2: у цьому процесі гру вже запускали (інакше екран гри відтворила система після смерті процесу) */
		@Volatile private var gameStartedInProcess = false
	}

	private lateinit var viewModel: StreamViewModel
	private lateinit var binding: ActivityStreamBinding
	private lateinit var insetsController: WindowInsetsControllerCompat

	private val uiVisibilityHandler = Handler(Looper.getMainLooper())

	override fun onCreate(savedInstanceState: Bundle?)
	{
		super.onCreate(savedInstanceState)
		AnyPlayDiag.install(this)

		val connectInfo = IntentCompat.getParcelableExtra(intent, EXTRA_CONNECT_INFO, ConnectInfo::class.java)
		if(connectInfo == null)
		{
			finish()
			return
		}
		// 118.2: процес загинув посеред гри, і Android сам відтворив екран гри зі старими даними (журнал Galaxy S7:
		// сесія підключалась сама, без поверхні, екран завантаження висів на кроці 1, потім чорний екран).
		// Такий екран одразу закриваємо: головний екран під ним покаже стан броні, а «Грати» почне гру як слід
		if(savedInstanceState != null && !gameStartedInProcess && intent.getBooleanExtra(EXTRA_ANYPLAY, false))
		{
			AnyPlayDiag.w("Екран гри відновлено після смерті процесу: закриваю, гравець почне гру знову з головного екрана")
			Toast.makeText(this, "Гру перервано: Android закрив програму. Натисни «Грати», щоб підключитись знову.", Toast.LENGTH_LONG).show()
			finish()
			return
		}
		gameStartedInProcess = true

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
			// у грі AnyPlay свій геймпад; старий шар «лише тачпад» (з chiaki) лежить поверх і забирав би всі дотики
			if(viewModel.touchpadOnlyEnabled.value == true)
				viewModel.setTouchpadOnlyEnabled(false)
			binding.root.post {
				gamepad()?.menuCallback = { showAnyPlayMenu() }
				arrangeForOrientation()
			}
			// кольори картинки (Зображення): обробка відеокартою, лише коли не на нулі
			viewModel.session.setColor(AnyPlayPicture.params(this))
			// 118: екран завантаження замість чорного екрана з колом (старе коло chiaki в грі AnyPlay не показуємо)
			binding.progressBar.isGone = true
			anyplayLoading = AnyPlayLoading(this, binding.root,
				onCancel = { anyplayCancelLoading() },
				onReconnect = { anyplayReconnect(false, "кнопка «Підключитись заново»") })
			val takeoverMs = intent.getLongExtra(EXTRA_ANYPLAY_TAKEOVER_MS, 0L)
			if(takeoverMs > 0)
				anyplayTakeoverUntil = SystemClock.elapsedRealtime() + takeoverMs
		}

		//viewModel.session.attachToTextureView(textureView)
		viewModel.session.attachToSurfaceView(binding.surfaceView)
		viewModel.session.state.observe(this, Observer { this.stateChanged(it) })
		adjustStreamViewAspect()

		if(anyplay)
		{
			// 125: вібрація гри з плавною силою (AnyPlayHaptics), налаштування «Вібрація гри»
			AnyPlayHaptics.resetTriggers()
			viewModel.session.rumbleState.observe(this, Observer {
				AnyPlayHaptics.rumble(this, it.left.toInt(), it.right.toInt())
			})
			hud = AnyPlayStatsHud(this).also {
				it.visibility = View.GONE
				binding.root.addView(it, FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.TOP or Gravity.START))
			}
		}
		else if(Preferences(this).rumbleEnabled)
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

	// Екранних шарів керування два (геймпад AnyPlay і «лише тачпад»). До 114 тут лишалась підписка лише на
	// останній приєднаний фрагмент («лише тачпад»), тож натискання екранного геймпада в гру не йшли зовсім.
	// Тепер стан кожного шару окремо, а в гру — їхнє об'єднання.
	private val controlsJobs = HashMap<String, Job>()
	private val controlsStates = HashMap<String, com.metallic.chiaki.lib.ControllerState>()

	override fun onAttachFragment(fragment: Fragment)
	{
		super.onAttachFragment(fragment)
		if(fragment is TouchControlsFragment)
		{
			val key = fragment.javaClass.name
			controlsJobs.remove(key)?.cancel()
			controlsJobs[key] = fragment.controllerState
				.onEach {
					controlsStates[key] = it
					viewModel.input.touchControllerState = controlsStates.values.reduce { a, b -> a or b }
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
	// 128: екран заблокували чи програму згорнули посеред гри — з'єднання з приставкою тримаємо (до BG_KEEP_MS),
	// і після розблокування гра йде далі одразу, без нового підключення
	private var anyplayBgSince = 0L
	private var anyplayBgLost = false
	private var anyplayBgJob: Job? = null
	private var anyplayBeatJob: Job? = null
	private var anyplayResumeJob: Job? = null
	private var anyplayQualityJob: Job? = null
	private var anyplayRemindJob: Job? = null
	private var anyplayHandoffJob: Job? = null
	private val anyplayAdmin get() = intent.getBooleanExtra(EXTRA_ANYPLAY_ADMIN, false)
	// кінець гри (усієї, разом із бронями впритул) за SystemClock.elapsedRealtime(), 0 — ще не знаємо
	@Volatile private var anyplayEndAt = 0L
	@Volatile private var anyplayContinues = false   // після цієї броні одразу йде наступна: гра не закінчується
	@Volatile private var anyplayLoss = 0.0
	@Volatile private var anyplayControls = true
	@Volatile private var anyplayGuest = false        // гостьовий доступ: граємо, поки приставка вільна
	@Volatile private var anyplayHelperOf = ""        // граємо в бронь друга (він передав гру повністю): його ім'я
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
	private var padEditor: PadEditor? = null
	/** «Грати тут»: до цього часу (elapsedRealtime) «приставка вже зайнята» означає, що інший пристрій ще її відпускає */
	private var anyplayTakeoverUntil = 0L
	private var anyplayTakeoverJob: Job? = null
	/** 118: те саме вікно повторів після власного перепідключення (повернення в застосунок, зміна якості) — приставка
	 * ще закриває попереднє підключення цього ж телефона; тоді без підказки «на іншому пристрої» */
	private var anyplayRetrySelf = false

	// ── 118: екран завантаження і сторож картинки ──
	private var anyplayLoading: AnyPlayLoading? = null
	private var anyplayWatchJob: Job? = null
	@Volatile private var anyplayConnecting = false   // сервер дає ключ і шукаємо приставку (anyplayFreshConnect)
	private var loadSince = 0L          // з якого моменту чекаємо картинку (0 — картинка йде)
	private var everShown = false       // у цьому екрані гри картинка вже була (далі завантаження — напівпрозоре)
	private var wSession: Any? = null   // сесія, за якою стежимо
	private var wConnectedAt = 0L
	private var wIn = 0L
	private var wInAt = 0L
	private var wOut = 0L
	private var wOutAt = 0L
	private var wDecOut = 0L
	private var wDecOutAt = 0L
	private var wShown = false          // ця сесія вже показала кадр
	private var wStep = 0               // скільки кроків відновлення вже зроблено в поточній біді
	private var wTrouble = ""           // яка біда зараз: start_no_video, start_no_picture, stall_net, stall_decoder
	private var wAutoReconnects = 0     // автоматичних перепідключень підряд без картинки
	private var wDecoderReset = false   // декодер уже створювали заново в цій біді
	private var wHevcMarked = false     // уже записали «H.265 тут не тягне»
	private var wNoSurfaceSession: Any? = null   // для якої сесії вже записали «кадри є, поверхні немає»
	private var wSnapSession: Any? = null        // 121: для якої сесії вже надіслали журнал «довго немає картинки»

	// 125: статистика під час гри (AnyPlayStatsHud): свої лічильники за останню секунду
	private var hud: AnyPlayStatsHud? = null
	private var hudSession: Any? = null
	private var hudPrev: LongArray? = null
	private var hudPrevAt = 0L
	private var hudTickN = 0

	private fun hudTick()
	{
		val h = hud ?: return
		val mode = AnyPlayStatsHud.mode(this)
		val s = viewModel.session.session
		val v = s?.videoStats()
		val now = SystemClock.elapsedRealtime()
		val loadingShown = loadSince != 0L
		if(mode == AnyPlayStatsHud.OFF || s == null || v == null || v.size < 4 || anyplayMenu != null || padEditor?.isOpen == true || loadingShown
			|| viewModel.session.state.value != StreamStateConnected)
		{
			if(h.visibility != View.GONE)
				h.animate().cancel()
			h.visibility = View.GONE
			h.update(null)
			if(s !== hudSession) { hudSession = s; hudPrev = null }
			return
		}
		val prev = hudPrev
		if(s !== hudSession || prev == null || v[0] < prev[0])
		{
			hudSession = s; hudPrev = v; hudPrevAt = now
			return
		}
		val dt = (now - hudPrevAt) / 1000.0
		if(dt < 0.8)
			return
		hudPrev = v; hudPrevAt = now
		val profile = viewModel.session.connectInfo.videoProfile
		val net = s.netStats()
		val stats = AnyPlayStatsHud.Stats(
			fpsShown = (v[1] - prev[1]) / dt, fpsStream = (v[0] - prev[0]) / dt, target = if(profile.maxFPS > 0) profile.maxFPS else 60,
			mbps = (v[3] - prev[3]) * 8.0 / dt / 1e6, pingMs = if(net != null && net.isNotEmpty() && net[0] > 0) (net[0] + 500) / 1000 else 0L,
			lossPct = anyplayLoss * 100.0, dropped = v[2] - prev[2],
			codec = if(profile.codec == com.metallic.chiaki.lib.Codec.CODEC_H264) "H.264" else "H.265",
			width = profile.width, height = profile.height, quality = AnyPlayQuality.name(this))
		h.mode = mode
		h.update(stats)
		placeHud(h)
		if(h.visibility != View.VISIBLE)
		{
			h.visibility = View.VISIBLE
			h.alpha = 0f
			h.animate().alpha(1f).setDuration(220).start()
		}
	}

	/** 128: статистика — тонкий рядок угорі: по центру, а якщо там кнопки — ліворуч чи праворуч угорі */
	private fun placeHud(h: AnyPlayStatsHud)
	{
		val w = binding.root.width
		val ht = binding.root.height
		if(w == 0)
			return
		val dp = resources.displayMetrics.density
		val m = (6 * dp).toInt()
		// відступи системи (виріз камери, заокруглені кути) — свої на кожному телефоні
		val ins = ViewCompat.getRootWindowInsets(binding.root)?.getInsets(WindowInsetsCompat.Type.displayCutout() or WindowInsetsCompat.Type.systemBars())
		val cl = ins?.left ?: 0
		val cr = ins?.right ?: 0
		val ct = ins?.top ?: 0
		h.maxW = w - cl - cr - 2 * m
		val hw = h.wantWidth()
		val hh = h.wantHeight()
		if(hw == 0)
			return
		val portrait = ht > w
		val top = ct + m
		val center = (cl + (w - cl - cr - hw) / 2) to top
		val (x, y) = if(portrait || !anyplayControls) center
		else
		{
			val busy = gamepad()?.occupied() ?: emptyList()
			val cands = listOf(center, (m + cl) to top, (w - hw - m - cr) to top)
			val pad = 4 * dp
			cands.firstOrNull { (cx, cy) ->
				val r = android.graphics.RectF(cx - pad, cy - pad, cx + hw + pad, cy + hh + pad)
				busy.none { android.graphics.RectF.intersects(it, r) }
			} ?: center
		}
		if(h.translationX != x.toFloat() || h.translationY != y.toFloat())
		{
			if(h.visibility == View.VISIBLE && h.translationX != 0f)
				h.animate().translationX(x.toFloat()).translationY(y.toFloat()).setDuration(180).start()
			else { h.translationX = x.toFloat(); h.translationY = y.toFloat() }
		}
	}

	// 123: чіткість (AnyPlayPicture) не встигає на цьому телефоні — декодер дає кадри, а на екран доходить помітно менше
	private var sharpWinAt = 0L
	private var sharpWinDec = 0L
	private var sharpWinShown = 0L

	private fun sharpCheck(now: Long, dec: Long, shown: Long, colorOn: Boolean)
	{
		val pr = AnyPlayPicture.params(this)
		if(!colorOn || pr == null || pr.size < 5 || pr[4] <= 0f)
		{
			sharpWinAt = 0L
			return
		}
		if(sharpWinAt == 0L || dec < sharpWinDec || shown < sharpWinShown)
		{
			sharpWinAt = now; sharpWinDec = dec; sharpWinShown = shown
			return
		}
		if(now - sharpWinAt < 10000)
			return
		val d = dec - sharpWinDec
		val sh = shown - sharpWinShown
		sharpWinAt = now; sharpWinDec = dec; sharpWinShown = shown
		if(d >= 150 && sh < d * 0.85)
		{
			AnyPlayDiag.w("Чіткість не встигає: за 10 с декодер дав $d кадрів, на екран дійшло $sh — вимикаю до наступної версії")
			AnyPlayPicture.markSharpSlow(this)
			viewModel.session.setColor(AnyPlayPicture.params(this))
			Toast.makeText(this, "Чіткість вимкнено: цей телефон не встигає з нею показувати всі кадри.", Toast.LENGTH_LONG).show()
		}
	}

	/** 121: картинки довго немає — журнал на сервер сам (раз на сесію), щоб гравцю нічого не пересилати */
	private fun wSnapshot(s: Any?, why: String)
	{
		if(s == null || wSnapSession === s)
			return
		wSnapSession = s
		AnyPlayDiag.w("Сторож: $why, надсилаю журнал")
		AnyPlayCloud.uploadLog(this, "error", "Довго немає картинки: $why", force = true)
	}

	/** Екранний геймпад AnyPlay (у фрагменті з розмітки; id фрагмента дістається обгортці, тому шукаємо за id самого геймпада) */
	private fun gamepad(): GamepadView? = findViewById(R.id.gamepadView)

	/** 128: скільки тримати з'єднання, поки екран заблоковано чи програму згорнуто */
	private val BG_KEEP_MS = 10 * 60 * 1000L

	override fun onResume()
	{
		super.onResume()
		hideSystemUI()
		if(!anyplay)
		{
			viewModel.session.resume()
			return
		}
		if(loadSince == 0L)
			loadSince = SystemClock.elapsedRealtime()
		AnyPlayLive.onMessage = liveToast
		if(anyplayFirstResume)
		{
			anyplayFirstResume = false
			anyplayGuest = intent.getBooleanExtra(EXTRA_ANYPLAY_GUEST, false)
			anyplayHelperOf = intent.getStringExtra(EXTRA_ANYPLAY_HELPER_OF) ?: ""
			viewModel.session.resume()
		}
		else if(anyplayBgSince != 0L && !anyplayBgLost && viewModel.session.session != null && viewModel.session.state.value == StreamStateConnected)
		{
			// 128: з'єднання пережило блокування екрана — гра одразу далі; декодер отримав нову поверхню, просимо ключовий кадр
			AnyPlayDiag.i("Повернулись у гру через ${(SystemClock.elapsedRealtime() - anyplayBgSince) / 1000} с: з'єднання збережене, без нового підключення")
			anyplayBgJob?.cancel()
			anyplayBgSince = 0L
			loadSince = 0L
			viewModel.session.requestKeyFrame("повернення в гру")
		}
		else
		{
			if(anyplayBgSince != 0L)
			{
				// тримали з'єднання, але воно обірвалось у фоні (телефон приспав Wi-Fi тощо): тихо підключаємось знову
				AnyPlayDiag.i("Повернулись у гру: з'єднання у фоні обірвалось, підключаємось знову")
				anyplayBgJob?.cancel()
				anyplayBgSince = 0L
				anyplayBgLost = false
				viewModel.session.shutdown()
				Thread { AnyPlayCloud.heartbeat(applicationContext, false) }.start()
			}
			// після згортання — нове підключення зі свіжим ключем від сервера (старий діє недовго). Приставка може ще
			// кілька секунд закривати попереднє підключення: «уже зайнята» в цей час — не помилка, а повтор
			anyplaySelfRetryWindow()
			anyplayFreshConnect(0)
		}
		anyplayWatchJob?.cancel()
		anyplayWatchJob = lifecycleScope.launch {
			var n = 0
			while(isActive)
			{
				anyplayWatchTick()
				if(n++ % 2 == 0)
				{
					anyplayLoading?.tick()
					hudTick()
				}
				delay(500)
			}
		}
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
					anyplayHelperOf = r.json.optJSONObject("handoff")?.optString("owner") ?: ""
				}
				if(r.status == 200 && r.json.optBoolean("sendLog"))
					AnyPlayCloud.uploadLog(this@StreamActivity, "request", "Адміністратор попросив журнал")
				if(r.status == 401)
					anyplayEnd("Доступ скасовано адміністратором.")
				else if(r.status == 200 && !r.json.optBoolean("continue", true))
					anyplayEnd(when(r.json.optString("reason"))
					{
						"kicked" -> "Сеанс завершив адміністратор AnyPlay."
						// гру забрали кнопкою «Грати тут» на іншому пристрої клієнта
						"other_device" -> r.json.optString("text").ifEmpty { "Гра продовжилась на іншому пристрої." }
						// етап 7 «Допомога друга»: власник броні повернув гру собі або передав іншому (текст дає сервер)
						"handoff" -> r.json.optString("text").ifEmpty { "Гру передано другу. Повернути її собі можна будь-коли на головному екрані." }
						"handoff_return" -> r.json.optString("text").ifEmpty { "Власник броні повернув гру собі. Дякуємо за допомогу!" }
						else -> r.json.optString("text").ifEmpty { "Час твоєї броні вийшов. Дякуємо за гру! Забронювати ще можна в боті." }
					})
				delay(ANYPLAY_BEAT_MS)
			}
		}
		// гра друга («Передати повністю»): раз на 3 с питаємо, чи власник не повернув її собі — зупиняємось одразу,
		// а не на наступному сигналі (до 20 с), щоб не заважати йому підключитись
		anyplayHandoffJob?.cancel()
		anyplayHandoffJob = lifecycleScope.launch {
			while(isActive)
			{
				delay(HANDOFF_CHECK_MS)
				val owner = anyplayHelperOf
				if(owner.isEmpty())
					continue
				val r = withContext(Dispatchers.IO) { AnyPlayCloud.request(this@StreamActivity, "GET", "/api/live/handoff") }
				if(r.status != 200 || !r.json.optBoolean("ok"))
					continue
				val h = r.json.optJSONObject("handoff")
				if(h != null && h.optString("role") == "friend" && h.optString("state") == "active")
					continue
				val who = h?.optJSONObject("owner")?.optString("name")?.ifEmpty { null } ?: owner
				anyplayEnd(if(h?.optString("endReason") == "time_over") "Бронь $who закінчилась. Дякуємо за гру!"
					else "$who повернув гру собі. Дякуємо за допомогу!")
				break
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

	private var bannerMinutes = 0L
	private var lastPortrait: Boolean? = null

	private fun anyplayShowBanner(minutes: Long)
	{
		anyplayHideBanner()
		bannerMinutes = minutes
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
		anyplayConnecting = true
		if(loadSince == 0L)
			loadSince = SystemClock.elapsedRealtime()
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
			anyplayConnecting = false
			when(target)
			{
				is PlayReady ->
				{
					viewModel.session.connectInfo = target.connectInfo
					adjustStreamViewAspect()   // інший формат кадру (якість) — інші пропорції
					viewModel.session.resume()
				}
				is PlayError -> anyplayEnd(target.text, target.code)
			}
		}
	}

	/** Власне перепідключення: 15 с «приставка зайнята» означає, що вона ще відпускає попереднє підключення */
	private fun anyplaySelfRetryWindow()
	{
		val until = SystemClock.elapsedRealtime() + 15000
		if(anyplayTakeoverUntil < until)
		{
			anyplayTakeoverUntil = until
			anyplayRetrySelf = true
		}
	}

	/** Підключитись заново (кнопка на екрані завантаження або сторож картинки) */
	private fun anyplayReconnect(auto: Boolean, why: String)
	{
		if(isFinishing || dialogContents == AnyPlayEndDialog)
			return
		AnyPlayDiag.i("Підключаюсь заново: $why")
		if(!auto)
			wAutoReconnects = 0
		dialog?.dismiss()
		dialog = null
		loadSince = SystemClock.elapsedRealtime()
		viewModel.session.shutdown()
		anyplaySelfRetryWindow()
		anyplayFreshConnect(1500)
	}

	/** «Скасувати» на екрані завантаження: вийти з гри на головний екран */
	private fun anyplayCancelLoading()
	{
		AnyPlayDiag.i("Завантаження гри скасовано кнопкою")
		anyplayLoading?.hide(false)
		finish()
	}

	private fun psnStepText(step: Int): String = when(step)
	{
		0, 1 -> "Готую з'єднання через інтернет."
		2 -> "Зв'язуюсь із серверами Sony."
		3 -> "Шукаю шлях до приставки через твою мережу."
		4 -> "Приставка приймає підключення."
		5 -> "Встановлюю пряме з'єднання з приставкою."
		else -> "Приставка на зв'язку, запускаю гру."
	}

	/** Крок відновлення, якщо час біди перейшов поріг (кожен крок — один раз) */
	private fun wDue(elapsed: Long, vararg at: Long): Int
	{
		if(wStep < at.size && elapsed >= at[wStep])
			return wStep++
		return -1
	}

	private fun wNewTrouble(kind: String)
	{
		if(wTrouble == kind)
			return
		AnyPlayDiag.i("Сторож картинки: $kind")
		wTrouble = kind
		wStep = 0
		wDecoderReset = false
	}

	/** Картинки так і не було: автоматично підключаємось заново (двічі), потім пояснюємо й чекаємо рішення гравця */
	private fun wGiveUpOrReconnect(why: String, decoderProblem: Boolean)
	{
		val s = viewModel.session
		val hevc = s.connectInfo.videoProfile.codec == com.metallic.chiaki.lib.Codec.CODEC_H265
		if(decoderProblem && hevc)
		{
			// кадри приходили, а декодер H.265 так нічого й не показав: далі цей телефон грає в H.264
			AnyPlayQuality.hevcFailed(this)
			Toast.makeText(this, "Перемикаю відео на сумісний формат і підключаюсь заново…", Toast.LENGTH_LONG).show()
		}
		// після кожної такої спроби (сам журнал не частіше ніж раз на 2 хв)
		AnyPlayCloud.uploadLog(this, "error", "Немає картинки: $why")
		if(wAutoReconnects < 2 || (decoderProblem && hevc))
		{
			wAutoReconnects++
			anyplayReconnect(true, why)
		}
		else
			wTrouble = "stuck"
	}

	/** Раз на пів секунди: що показати на екрані завантаження і чи не час рятувати картинку */
	private fun anyplayWatchTick()
	{
		val l = anyplayLoading ?: return
		val now = SystemClock.elapsedRealtime()
		if(isFinishing || dialogContents != null || padEditor?.isOpen == true)
		{
			l.hide(false)
			return
		}
		val vs = viewModel.session
		val st = vs.state.value
		val s = vs.session
		if(s !== wSession)
		{
			wSession = s
			wConnectedAt = 0L
			wIn = 0L; wInAt = now
			wOut = 0L; wOutAt = now
			wDecOut = 0L; wDecOutAt = now
			wShown = false
			wTrouble = ""
			wStep = 0
		}
		// 118.2: стан беремо і з самої сесії: якщо кадри вже йдуть, екран завантаження не стоїть на кроці 1,
		// навіть коли подія «підключено» до екрана не дійшла
		val v = s?.videoStats()
		val connectedLike = st == StreamStateConnected || (v != null && v.isNotEmpty() && v[0] > 0)
		if(!connectedLike || v == null || v.size < 4)
		{
			// ще підключаємось (ключ від сервера, PSN, рукостискання з приставкою)
			if(loadSince == 0L)
				loadSince = now
			val busyRetry = anyplayTakeoverJob?.isActive == true
			var detail = when
			{
				busyRetry && anyplayRetrySelf -> "Приставка ще закриває попереднє підключення. Пробую ще раз, це кілька секунд."
				busyRetry -> "Приставка ще зайнята на іншому пристрої. Вона звільниться за кілька секунд."
				s == null || anyplayConnecting -> "Отримую доступ до приставки від сервера AnyPlay."
				vs.connectInfo.psnToken == null -> "Приставка поруч, у твоїй мережі: підключаюсь напряму."
				else -> psnStepText(s.psnStep())
			}
			val waited = now - loadSince
			if(waited > 20000)
				wSnapshot(s, "підключення триває ${waited / 1000} с (крок ${s?.psnStep() ?: 0})")
			if(waited > 25000)
				detail += "\n\nДовше, ніж звичайно. Перевір інтернет на телефоні або натисни «Підключитись заново»."
			l.show(AnyPlayLoading.Stage.CONNECT, detail, true, loadSince, waited > 25000, if(everShown) "Вийти з гри" else "Скасувати")
			return
		}
		if(wConnectedAt == 0L)
		{
			wConnectedAt = now
			wInAt = now
			wOutAt = now
			wDecOutAt = now
		}
		val vin = v[0]
		val dec = v[1]
		val hasCodec = v.size < 5 || v[4] != 0L
		if(vin != wIn) { wIn = vin; wInAt = now }
		if(dec > wDecOut || dec < wDecOut) { if(dec > wDecOut) wDecOutAt = now; wDecOut = dec }
		// що справді на екрані: з обробкою кольорів — кадри, які вона намалювала, інакше — кадри декодера
		val colorOn = vs.colorActive
		val p = if(colorOn) vs.colorFrames() else dec
		if(p < wOut)
			wOut = p
		if(p > wOut)
		{
			wOut = p
			wOutAt = now
			if(!wShown)
			{
				wShown = true
				AnyPlayDiag.i("Перша картинка через ${now - loadSince} мс від початку підключення" +
					(if(colorOn) " (з обробкою кольорів)" else "") + ", формат " + vs.connectInfo.videoProfile.codec)
			}
			everShown = true
			loadSince = 0L
			wAutoReconnects = 0
			if(wTrouble != "")
				AnyPlayDiag.i("Сторож картинки: картинка повернулась ($wTrouble, кроків ${wStep})")
			wTrouble = ""
			wStep = 0
			l.hide()
			return
		}
		// 118.1: декодер довелось створювати заново — з обробкою кольорів вона перша підозрювана (декодер пише в її
		// SurfaceTexture і стоїть, якщо та не встигає забирати кадри); у H.265 двічі заново — далі цей телефон грає в H.264
		val recreated = if(v.size > 5) v[5] else 0L
		if(colorOn && recreated >= 1)
		{
			AnyPlayDiag.w("Сторож: декодер створювали заново ($recreated) з обробкою кольорів — вимикаю її")
			vs.blockColor()
		}
		if(recreated >= 2 && vs.connectInfo.videoProfile.codec == com.metallic.chiaki.lib.Codec.CODEC_H265 && !wHevcMarked)
		{
			wHevcMarked = true
			AnyPlayQuality.hevcFailed(this)
		}
		// обробка кольорів: декодер видає кадри, а на екран нічого не потрапляє — вимикаємо її до кінця гри
		if(colorOn && now - wDecOutAt < 1000 && now - wOutAt > 2000)
		{
			vs.blockColor()
			wOutAt = now
			return
		}
		if(!wShown)
		{
			// підключились, а першої картинки ще немає
			if(loadSince == 0L)
				loadSince = now
			val t = now - wConnectedAt
			if(t > 10000)
				wSnapshot(s, "з приставкою з'єднано ${t / 1000} с, кадрів прийшло $vin, декодер показав $dec, поверхня ${if(vs.hasSurface) "є" else "немає"}, обробка кольорів ${if(colorOn) "увімк." else "вимк."}")
			val stage: AnyPlayLoading.Stage
			val detail: String
			if(wTrouble == "stuck")
			{
				stage = AnyPlayLoading.Stage.STUCK
				detail = "Зв'язок з приставкою є, але картинка так і не з'явилась. Натисни «Підключитись заново». " +
					"Якщо повториться, вибери в меню «Зображення» нижчу якість або напиши в підтримку: журнал ми вже отримали."
			}
			else if(vin == 0L)
			{
				wNewTrouble("start_no_video")
				stage = AnyPlayLoading.Stage.PICTURE
				detail = "Приставка на зв'язку, чекаю перший кадр картинки."
				when(wDue(t, 3000, 8000, 16000))
				{
					0, 1 -> vs.requestKeyFrame("android_start_no_video")
					2 -> wGiveUpOrReconnect("після підключення ${t / 1000} с не прийшло жодного кадру", false)
				}
			}
			else
			{
				wNewTrouble("start_no_picture")
				stage = AnyPlayLoading.Stage.ALMOST
				detail = if(!hasCodec) "Картинка вже йде, запускаю відео на телефоні." else "Картинка вже йде, ще мить."
				if(!vs.hasSurface && t > 4000 && wNoSurfaceSession !== s)
				{
					wNoSurfaceSession = s
					AnyPlayDiag.w("Сторож: кадри йдуть (${vin}), а поверхні екрана немає вже ${t / 1000} с")
				}
				when(wDue(t, 2500, 5000, 7500, 11000))
				{
					0 -> vs.requestKeyFrame("android_start_no_picture")
					1 -> { wDecoderReset = true; AnyPlayDiag.i("Сторож: декодер заново (кадрів прийшло $vin, показано $dec)"); vs.resetDecoder() }
					2 -> if(colorOn) vs.blockColor() else vs.requestKeyFrame("android_start_no_picture")
					3 -> wGiveUpOrReconnect("кадри приходять ($vin), а на екрані нічого${if(!hasCodec) ", декодер не створився" else ""}", true)
				}
			}
			l.show(stage, detail, true, loadSince, wTrouble == "stuck" || t > 8000, if(everShown) "Вийти з гри" else "Скасувати")
			return
		}
		sharpCheck(now, dec, p, colorOn)
		// картинка була, а тепер стоїть
		val outStall = now - wOutAt
		if(outStall < 2500)
		{
			if(l.isShown)
				l.hide()
			return
		}
		val netStall = now - wInAt >= 2000
		var detail = ""
		if(wTrouble == "stuck")
		{
			// уже зробили все, що могли: чекаємо рішення гравця
		}
		else if(netStall)
		{
			wNewTrouble("stall_net")
			detail = "Картинка не приходить від приставки: схоже, інтернет пригальмовує. Чекаю, гра не зупиняється."
			when(wDue(outStall, 3000, 9000, 20000))
			{
				0, 1 -> vs.requestKeyFrame("android_video_stalled")
				2 -> wGiveUpOrReconnect("відео не приходить ${outStall / 1000} с (звук і керування могли йти)", false)
			}
		}
		else
		{
			wNewTrouble("stall_decoder")
			detail = "Кадри приходять, але екран їх не показує. Перезапускаю відео, це кілька секунд."
			when(wDue(outStall, 2500, 5000, 7500, 11000))
			{
				0 -> vs.requestKeyFrame("android_picture_stalled")
				1 -> { wDecoderReset = true; AnyPlayDiag.i("Сторож: декодер заново посеред гри"); vs.resetDecoder() }
				2 -> if(colorOn) vs.blockColor() else vs.requestKeyFrame("android_picture_stalled")
				3 -> wGiveUpOrReconnect("картинка зависла посеред гри ${outStall / 1000} с, кадри приходять", false)
			}
		}
		if(wTrouble == "stuck")
			l.show(AnyPlayLoading.Stage.STUCK, "Картинка не відновилась. Натисни «Підключитись заново» або вийди з гри й зайди знову.",
				false, wOutAt, true, "Вийти з гри")
		else
			l.show(AnyPlayLoading.Stage.RECOVER, detail, false, wOutAt, outStall > 6000, "Вийти з гри")
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
				anyplaySelfRetryWindow()
				loadSince = SystemClock.elapsedRealtime()
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
		anyplayHandoffJob?.cancel()
		anyplayWatchJob?.cancel()
		anyplayLoading?.hide(false)
		anyplayHideBanner()
		anyplayMenu?.dismiss()
		viewModel.session.shutdown()
		dialog?.dismiss()
		if(code.isNotEmpty())
			AnyPlayCloud.uploadLog(this, "error", "Гру зупинено: $code")
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
		// 128: гра йде, екран заблокували або згорнули — з'єднання не рвемо (якщо не виходимо з гри)
		if(anyplay && !isFinishing && !isChangingConfigurations && dialogContents == null
			&& viewModel.session.session != null && viewModel.session.state.value == StreamStateConnected)
		{
			anyplayKeepInBackground()
			return
		}
		anyplayStopStream()
	}

	/** Зупинити стрім тут і сказати серверу (згорнули надовго, вийшли з гри) */
	private fun anyplayStopStream()
	{
		anyplayBgJob?.cancel()
		anyplayBgSince = 0L
		anyplayBeatJob?.cancel()
		anyplayResumeJob?.cancel()
		anyplayQualityJob?.cancel()
		anyplayRemindJob?.cancel()
		anyplayHandoffJob?.cancel()
		anyplayWatchJob?.cancel()
		viewModel.session.pause()
		anyplayTakeoverJob?.cancel()
		if(anyplay)
			AnyPlayHaptics.stopRumble()
		padEditor?.close(true)
		if(anyplay)
			AnyPlayCloud.markLive(this, false)
		// згорнули чи вийшли з гри: стрім тут зупинено (pause), одразу кажемо це серверу — тоді на іншому пристрої
		// клієнта одразу з'явиться «Грати» (інакше він чекав би, доки застаріє останній сигнал, до 90 с).
		// До 115 сигнал ішов лише при виході з гри, і після згортання ноутбук друга кілька хвилин бачив «гра вже йде»
		if(anyplay)
		{
			val ctx = applicationContext
			Thread { AnyPlayCloud.heartbeat(ctx, false) }.start()
		}
	}

	/**
	 * 128: екран заблоковано (або програму згорнули) посеред гри. Сесію з приставкою не закриваємо: сигнал серверу
	 * йде далі, кнопки відпущено, вібрація стоп. Повернувся до BG_KEEP_MS — гра одразу далі. Довше — зупиняємо стрім,
	 * як раніше, а після повернення буде нове підключення.
	 */
	private fun anyplayKeepInBackground()
	{
		anyplayBgSince = SystemClock.elapsedRealtime()
		anyplayBgLost = false
		anyplayResumeJob?.cancel()
		anyplayQualityJob?.cancel()
		anyplayWatchJob?.cancel()
		anyplayTakeoverJob?.cancel()
		AnyPlayHaptics.stopRumble()
		padEditor?.close(true)
		gamepad()?.releaseAll()
		AnyPlayDiag.i("Екран вимкнено або програму згорнуто: з'єднання з приставкою тримаємо до ${BG_KEEP_MS / 60000} хв")
		anyplayBgJob?.cancel()
		anyplayBgJob = lifecycleScope.launch {
			delay(BG_KEEP_MS)
			AnyPlayDiag.i("Програма у фоні понад ${BG_KEEP_MS / 60000} хв: стрім зупинено, після повернення — нове підключення")
			anyplayStopStream()
		}
	}

	private val liveToast: (String) -> Unit = { m -> if(!isFinishing) Toast.makeText(this, m, Toast.LENGTH_LONG).show() }

	override fun onTrimMemory(level: Int)
	{
		super.onTrimMemory(level)
		AnyPlayDiag.trimMemory(this, level)
	}

	override fun onDestroy()
	{
		super.onDestroy()
		// 124: гру закрито — трансляція з телефона теж закривається (кімнату на сервері закриваємо одразу)
		if(isFinishing)
			AnyPlayLive.gameEnded()
		if(AnyPlayLive.onMessage === liveToast)
			AnyPlayLive.onMessage = null
		controlsJobs.values.forEach { it.cancel() }
		controlsJobs.clear()
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
		// 125: повернули телефон — банер «Лишилось N хв» перебудовуємо під нову ширину (інакше вилазив за край)
		if(lastPortrait != null && lastPortrait != portrait && anyplayBanner != null)
			binding.root.post { if(anyplayBanner != null) anyplayShowBanner(bannerMinutes) }
		lastPortrait = portrait
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
		gamepad()?.let {
			it.safeLeft = cut?.left ?: 0
			it.safeRight = cut?.right ?: 0
			it.safeBottom = cut?.bottom ?: 0
			it.videoBottom = videoBottom
			it.refreshLayout()
		}
	}

	/** Редактор «Розташування кнопок» поверх гри: поки він відкритий, екранні кнопки в гру не йдуть */
	private fun openPadEditor(map: Boolean = false)
	{
		if(padEditor?.isOpen == true)
			return
		if(!anyplayControls)
			viewModel.setOnScreenControlsEnabled(true)
		binding.root.post {
			val pad = gamepad() ?: return@post
			anyplayHideBanner()
			padEditor = PadEditor(this, binding.root, pad) {
				padEditor = null
				hideSystemUI()
			}.also { it.open(map) }
		}
	}

	/** Меню AnyPlay під час гри (кнопка «⋯» на джойстику, «Назад», банер «Продовжити»): сторінка в стилі паузи GTA */
	private fun showAnyPlayMenu(page: String = "menu")
	{
		if(dialogContents != null || anyplayMenu != null || padEditor?.isOpen == true)
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
			.put("helperOf", anyplayHelperOf)
			.put("quality", AnyPlayQuality.name(this@StreamActivity))
			.put("autoHide", PadLayout.autoHide(this@StreamActivity))
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
				// «Передати повністю» (етап 7): гру віддали другу або повернули власнику — м'яко зупиняємо свою
				// трансляцію (приставку не присипляємо: на ній зараз почне грати інший) і йдемо на головний екран
				"handedOff", "handedBack" ->
				{
					anyplayMenu?.dismiss()
					anyplayBeatJob?.cancel()
					viewModel.session.shutdown()
					Toast.makeText(this@StreamActivity, if(name == "handedOff") "Гру передано другу. Повернути її собі можна на головному екрані."
						else "Гру повернуто власнику броні. Дякуємо за допомогу!", Toast.LENGTH_LONG).show()
					finish()
				}
				// 123: коли ховати екранні кнопки (-1 одразу, N с, 0 ніколи)
				"autohide" ->
				{
					PadLayout.setAutoHide(this@StreamActivity, arg.toIntOrNull() ?: PadLayout.AUTOHIDE_INSTANT)
					gamepad()?.reloadSettings()
				}
				// «Розташування кнопок»: редактор поверх гри
				"layout" ->
				{
					anyplayMenu?.dismiss()
					openPadEditor(arg == "map")
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

		override fun pictureChanged()
		{
			// кольори змінюються одразу, без перепідключення
			viewModel.session.setColor(AnyPlayPicture.params(this@StreamActivity))
		}

		override fun qualityChanged()
		{
			// нова якість діє з нового підключення
			Toast.makeText(this@StreamActivity, "Якість: ${AnyPlayQuality.name(this@StreamActivity)}. Підключаюсь заново…", Toast.LENGTH_LONG).show()
			anyplayMenu?.dismiss()
			viewModel.session.shutdown()
			anyplaySelfRetryWindow()
			loadSince = SystemClock.elapsedRealtime()
			anyplayFreshConnect(2500)
		}
	}

	@Deprecated("Deprecated in Java")
	override fun onBackPressed()
	{
		val editor = padEditor
		if(editor != null && editor.isOpen)
			editor.close(true)
		else if(anyplay)
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
		// у грі AnyPlay замість кола — екран завантаження (anyplayWatchTick)
		binding.progressBar.visibility = if(state == StreamStateConnecting && !anyplay) View.VISIBLE else View.GONE
		if(anyplay && state == StreamStateConnected)
		{
			AnyPlayCloud.markLive(this, true)
			anyplayTakeoverUntil = 0L
			anyplayRetrySelf = false
		}
		// «Грати тут»: інший пристрій ще тримає приставку (відпустить за кілька секунд) — пробуємо знову раз на 3 с
		if(anyplay && anyplayTakeoverUntil > SystemClock.elapsedRealtime() && !isFinishing &&
			((state is StreamStateQuit && state.reason.value == QUIT_RP_IN_USE) || state is StreamStatePsnFailed))
		{
			if(anyplayTakeoverJob?.isActive != true)
			{
				// пояснення — на екрані завантаження («приставка ще зайнята…»), окреме спливне вікно не потрібне
				AnyPlayDiag.i("Приставка ще зайнята (${if(anyplayRetrySelf) "попереднє підключення цього телефона" else "інший пристрій"}), повтор за 3 с")
				anyplayTakeoverJob = lifecycleScope.launch {
					delay(TAKEOVER_RETRY_MS)
					viewModel.session.shutdown()
					viewModel.session.resume()
				}
			}
			return
		}
		// 128: сесія обірвалась, поки екран був заблокований: без вікна помилки, після повернення підключимось знову самі
		if(anyplay && anyplayBgSince != 0L && (state is StreamStateQuit || state is StreamStatePsnFailed))
		{
			anyplayBgLost = true
			AnyPlayDiag.i("Поки екран був вимкнений, з'єднання обірвалось (${if(state is StreamStateQuit) "QUIT ${state.reason.value}" else "PSN"})")
			return
		}
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
							loadSince = SystemClock.elapsedRealtime()
							anyplaySelfRetryWindow()
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
								loadSince = SystemClock.elapsedRealtime()
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
		{
			anyplayPadAt = SystemClock.elapsedRealtime()
			com.metallic.chiaki.anyplay.AnyPlayGamepads.active(event.device)
			if(anyplay && event.keyCode != KeyEvent.KEYCODE_BACK)
				gamepad()?.physicalInput()   // грають геймпадом: кнопки на екрані ховаються до першого дотику
		}
		else if(event.device?.isVirtual == false && event.device?.keyboardType == InputDevice.KEYBOARD_TYPE_ALPHABETIC)
			anyplayKeysAt = SystemClock.elapsedRealtime()
		return viewModel.input.dispatchKeyEvent(event) || super.dispatchKeyEvent(event)
	}

	/**
	 * AnyPlay 118.1: стіки й курки геймпада забираємо ще до вікон і View. onGenericMotionEvent активності отримує подію
	 * лише тоді, коли жоден View її не взяв, а з екраном завантаження, банерами й сторінками поверх гри це не гарантовано.
	 */
	override fun dispatchGenericMotionEvent(event: MotionEvent): Boolean
	{
		if(event.source and InputDevice.SOURCE_CLASS_JOYSTICK == InputDevice.SOURCE_CLASS_JOYSTICK && anyplayMenu == null && padEditor?.isOpen != true)
			return onGenericMotionEvent(event)
		return super.dispatchGenericMotionEvent(event)
	}

	override fun onGenericMotionEvent(event: MotionEvent): Boolean
	{
		if(event.source and InputDevice.SOURCE_CLASS_JOYSTICK == InputDevice.SOURCE_CLASS_JOYSTICK)
		{
			anyplayPadAt = SystemClock.elapsedRealtime()
			com.metallic.chiaki.anyplay.AnyPlayGamepads.active(event.device)
			if(anyplay && padMoved(event))
				gamepad()?.physicalInput()
		}
		return viewModel.input.onGenericMotionEvent(event) || super.onGenericMotionEvent(event)
	}
}

/** Стік чи курок справді зрушили (а не шум біля нуля): тоді це гра геймпадом */
private fun padMoved(e: MotionEvent): Boolean
{
	for(axis in intArrayOf(MotionEvent.AXIS_X, MotionEvent.AXIS_Y, MotionEvent.AXIS_Z, MotionEvent.AXIS_RZ,
		MotionEvent.AXIS_LTRIGGER, MotionEvent.AXIS_RTRIGGER, MotionEvent.AXIS_HAT_X, MotionEvent.AXIS_HAT_Y))
		if(kotlin.math.abs(e.getAxisValue(axis)) > 0.35f)
			return true
	return false
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
