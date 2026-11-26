// AnyPlay: головний екран — вхід через Telegram, стан броні, кнопка «Грати».
// Вигляд — сторінка assets/anyplay/app.html з вкладками «Гра», «Бронювання», «Баланс», «Якість», «Мій PSN», «Як керувати»;
// тут лише стан і дії: сервер, вхід, гра, панель адміна, оновлення.
package com.metallic.chiaki.anyplay

import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.res.Configuration
import android.graphics.Color
import android.net.Uri
import android.os.Bundle
import android.webkit.WebView
import android.widget.Toast
import androidx.activity.OnBackPressedCallback
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.lifecycle.lifecycleScope
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import com.metallic.chiaki.BuildConfig
import com.metallic.chiaki.stream.StreamActivity
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

class AnyPlayActivity: AppCompatActivity(), AnyPlayHost
{
	companion object
	{
		private const val POLL_MS = 8000L
		private const val PAIR_MS = 2000L
		private const val PAIR_MAX_TRIES = 150
		private const val HANDOFF_POLL_MS = 1500L
		private const val HANDOFF_TARGET_MS = 4 * 60_000L   // ключі PSN для передачі оновлюємо, якщо їм більше 4 хв
		/** Команда з іншого екрана (сторінка сервера): play — грати (друг передав гру), home — просто головний екран */
		const val EXTRA_ACTION = "anyplay_action"
	}

	private lateinit var web: WebView
	@Volatile private var homeJson = "{}"   // останній стан для сторінки (сторінка читає його не з головного потоку)
	private var state = "login"          // login | pairing | wait | play | no_console | update | offline | other_device
	private var session = JSONObject()
	private var skew = 0L                // час сервера мінус час телефона, секунди
	private var pairJob: Job? = null
	private var pairShort = ""   // шість цифр для бота, якщо Telegram на іншому пристрої
	private var pairBot = ""
	private var pollJob: Job? = null
	private var busy = false             // шукаємо приставку перед грою
	private var adminInfo: JSONObject? = null   // лише для адміна: хто грає, наступні броні, заявки
	// оновлення програми: вікна лише на цьому екрані й не під час пошуку приставки чи входу
	// 118: знайдена нова версія видна й на головному екрані (рядок «Доступна версія …»), тож про зміну кажемо сторінці
	private val updater = AnyPlayUpdater(this, { !busy && state != "pairing" }) { render() }

	private val isAdmin get() = loggedIn && session.optBoolean("admin")

	override fun onCreate(savedInstanceState: Bundle?)
	{
		super.onCreate(savedInstanceState)
		AnyPlayDiag.install(this)   // 118.2: журнал програми, записи падінь і зависань
		state = if(loggedIn) "wait" else "login"
		// сторінка на весь екран, під системними панелями видно тло AnyPlay; відступи рахує anyplayFrame
		WindowCompat.setDecorFitsSystemWindows(window, false)
		window.statusBarColor = Color.TRANSPARENT
		window.navigationBarColor = Color.TRANSPARENT
		web = anyplayWebView(this, false)
		web.addJavascriptInterface(AnyPlayBridge(this, web, { !isFinishing && !isDestroyed }, this) {}, "AnyPlay")
		setContentView(anyplayFrame(this, web, AnyPlayStyle.background()))
		render()
		web.loadUrl("$ANYPLAY_PAGE#home")
		applyOrientation(resources.configuration)
		// «Назад»: спершу сторінка (закрити оплату, повернутись на вкладку «Гра»), потім як завжди
		onBackPressedDispatcher.addCallback(this, object: OnBackPressedCallback(true)
		{
			override fun handleOnBackPressed()
			{
				web.evaluateJavascript("window.__anyplayBack ? window.__anyplayBack() : false") {
					if(it != "true" && !isFinishing)
					{
						isEnabled = false
						onBackPressedDispatcher.onBackPressed()
						isEnabled = true
					}
				}
			}
		})
		updater.onCreate()
		// відкрили зі сторінки сервера з командою «грати» (друг передав гру, а цього екрана вже не було)
		if(savedInstanceState == null && intent.getStringExtra(EXTRA_ACTION) == "play" && loggedIn)
		{
			intent.removeExtra(EXTRA_ACTION)
			play()
		}
		// минулого разу гра обірвалась падінням — журнал для підтримки. 118.2: і тоді, коли система відновлює екран
		// після смерті процесу (savedInstanceState не порожній) — саме так було на Galaxy S7, і звіт не йшов
		AnyPlayCloud.reportCrashIfAny(this)
	}

	/** Повернулись зі сторінки сервера (AnyPlayPageActivity) з командою */
	override fun onNewIntent(intent: Intent)
	{
		super.onNewIntent(intent)
		setIntent(intent)
		val a = intent.getStringExtra(EXTRA_ACTION) ?: return
		intent.removeExtra(EXTRA_ACTION)
		if(a == "play" && loggedIn)
			play()
	}

	override fun onTrimMemory(level: Int)
	{
		super.onTrimMemory(level)
		AnyPlayDiag.trimMemory(this, level)
	}

	override fun onDestroy()
	{
		updater.onDestroy()
		web.removeJavascriptInterface("AnyPlay")
		web.destroy()
		super.onDestroy()
	}

	/** Екран повернули: сторінка сама перебудовується під ширину й висоту, стан програми лишається */
	override fun onConfigurationChanged(newConfig: Configuration)
	{
		super.onConfigurationChanged(newConfig)
		applyOrientation(newConfig)
	}

	/** Телефон горизонтально: ховаємо рядок стану, щоб головний екран вмістився без прокрутки */
	private fun applyOrientation(config: Configuration)
	{
		val c = WindowCompat.getInsetsController(window, window.decorView)
		c.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
		if(config.orientation == Configuration.ORIENTATION_LANDSCAPE && config.smallestScreenWidthDp < 600)
			c.hide(WindowInsetsCompat.Type.statusBars())
		else
			c.show(WindowInsetsCompat.Type.statusBars())
	}

	private val loggedIn get() = AnyPlayCloud.token(this).isNotEmpty()

	override fun onResume()
	{
		super.onResume()
		web.onResume()
		applyOrientation(resources.configuration)
		busy = false
		render()
		pollJob?.cancel()
		pollJob = lifecycleScope.launch {
			while(isActive)
			{
				if(loggedIn && state != "pairing")
					refresh()
				updater.poll(state)
				delay(POLL_MS)
			}
		}
		updater.onResume()
	}

	override fun onPause()
	{
		super.onPause()
		web.onPause()
		pollJob?.cancel()
		handoffJob?.cancel()
		updater.onPause()
	}

	// ── сторінка ──

	override fun info(): String = homeJson

	/** Команди сторінки головного екрана */
	override fun action(name: String, arg: String)
	{
		when(name)
		{
			"login" -> if(state == "login") login(true)
			"loginCode" -> if(state == "login") login(false)
			"openTg" -> if(state == "pairing" && pairLink.isNotEmpty()) openLink(pairLink)
			"cancelLogin" -> cancelLogin()
			"play" -> if(isAdmin && adminInfo != null) adminPlay() else play()
			// «Грати тут»: забрати гру з іншого пристрою клієнта (той сам зупинить стрім)
			"takeover" -> if(!isAdmin) play(true)
			// «Кнопки на екрані»: редактор розташування без гри
			"layout" -> PadEditorDialog(this, arg == "map").show()
			"retry", "refresh" -> if(loggedIn && state != "pairing") lifecycleScope.launch { refresh() }
			"update" -> updater.updateNow {
				openBot()
				toast("Нову версію можна завантажити в боті: кнопка «Програма».")
			}
			"bot" -> openBot()
			"logout" -> AnyPlayStyle.show(MaterialAlertDialogBuilder(this)
				.setMessage("Вийти з AnyPlay на цьому телефоні?")
				.setPositiveButton("Вийти") { _, _ -> logout() }
				.setNegativeButton("Скасувати", null))
			// 129: CRM у самій програмі (та сама сторінка, що в боті й на комп'ютері)
			"crm" -> if(isAdmin) AnyPlayPageActivity.open(this, "/app/admin.html")
			"adminPsn" -> showPsnClients()
			"adminShared" -> showSharedPsn()
			// 129: адмінка на телефоні — прив'язка PS5 кодом для клієнта зі своїм PSN і для спільного акаунта
			"adminState" -> adminEvent(JSONObject().put("kind", "state").put("online", AnyPlayAdminLink.sharedOnline(this)))
			"adminPsnLogin" -> if(isAdmin) PsnLoginDialog(this, false, admin = true) { err ->
				val online = AnyPlayAdminLink.sharedOnline(this)
				adminEvent(JSONObject().put("kind", "login").put("ok", err == null).put("online", online)
					.put("text", err ?: "Вхід виконано: $online. Тепер крок 2."))
			}.show()
			"adminLink", "adminSharedLink" -> if(isAdmin && !adminLinking)
			{
				adminLinking = true
				val o = try { JSONObject(arg) } catch(e: Exception) { JSONObject() }
				lifecycleScope.launch {
					val err = withContext(Dispatchers.IO) {
						if(name == "adminLink") AnyPlayAdminLink.linkClient(this@AnyPlayActivity, o.optLong("userId"), o.optString("accountId"), o.optString("pin"))
						else AnyPlayAdminLink.linkShared(this@AnyPlayActivity, o.optString("pin"))
					}
					adminLinking = false
					val ok = err == null
					adminEvent(JSONObject().put("kind", name).put("ok", ok).put("userId", o.optLong("userId")).put("text", err ?: if(name == "adminLink")
						"Готово! Клієнт тепер грає на своєму акаунті, і наступного разу теж. Йому прийшло повідомлення."
						else "Готово! Спільний акаунт «${AnyPlayAdminLink.sharedOnline(this@AnyPlayActivity)}» передано на сервер, клієнти гратимуть через нього."))
					refresh()
				}
			}
			"adminKick" -> adminKick()
			"adminToggle" -> adminToggleClosed()
			// «Передати повністю» (етап 7): друг відмовився від гри або повернув її власнику — оновити стан
			"handoffChanged" -> lifecycleScope.launch { handoffInfo = null; refresh() }
		}
	}

	override fun qualityChanged() = render()

	private var adminLinking = false

	/** 129: результат дії адміна — на сторінку (вона показує його в розділі «Свої PSN» чи «Спільний PSN») */
	private fun adminEvent(o: JSONObject)
	{
		if(::web.isInitialized)
			web.evaluateJavascript("window.__anyplayAdmin && window.__anyplayAdmin(${JSONObject.quote(o.toString())})", null)
	}

	private suspend fun refresh()
	{
		val r = withContext(Dispatchers.IO) { AnyPlayCloud.session(this@AnyPlayActivity) }
		if(r.status == 401)
		{
			logout()
			toast("Доступ цього телефона скасовано. Увійди через Telegram знову.")
			return
		}
		if(!r.ok)
		{
			if(state != "pairing")
			{
				state = "offline"
				render()
			}
			return
		}
		session = r.json
		skew = r.json.optLong("now") - System.currentTimeMillis() / 1000
		// 118.1: адмін попросив журнал — надсилаємо й з головного екрана, не лише з гри
		if(r.json.optBoolean("sendLog"))
			AnyPlayCloud.uploadLog(this, "request", "Адміністратор попросив журнал (головний екран)")
		if(r.json.optBoolean("admin"))
		{
			val a = withContext(Dispatchers.IO) { AnyPlayCloud.admin(this@AnyPlayActivity) }
			if(a.ok)
				adminInfo = a.json
		}
		else
			adminInfo = null
		// друг готує передати нам свою гру: стежимо частіше, ключі готуємо заздалегідь, щоб почати одразу
		if(!r.json.optBoolean("admin") && (r.json.has("handoffOffer") || handoffInfo != null))
			watchHandoff()
		state = when(r.json.optString("state"))
		{
			"play" -> "play"
			"no_console" -> "no_console"
			"update" -> "update"
			"other_device" -> "other_device"   // гра вже йде на іншому пристрої клієнта: приставка тримає одне підключення
			else -> "wait"
		}
		render()
	}

	private fun logout()
	{
		pairJob?.cancel()
		AnyPlayCloud.setToken(this, "")
		session = JSONObject()
		adminInfo = null
		state = "login"
		render()
	}

	// ── вхід через Telegram ──
	private var pairLink = ""

	/** openTg: одразу відкрити Telegram на цьому телефоні; інакше показати код, який надсилають боту з іншого пристрою */
	private fun login(openTg: Boolean)
	{
		state = "pairing"
		pairShort = ""
		pairBot = ""
		pairLink = ""
		render()
		pairJob?.cancel()
		pairJob = lifecycleScope.launch {
			val start = withContext(Dispatchers.IO) { AnyPlayCloud.pairStart(this@AnyPlayActivity) }
			val code = start.json.optString("code")
			val link = start.json.optString("link")
			if(!start.ok || code.isEmpty() || link.isEmpty())
			{
				state = "login"
				render()
				toast("Сервер AnyPlay недоступний. Перевір інтернет і спробуй ще раз.")
				return@launch
			}
			pairShort = start.json.optString("short")
			pairBot = start.json.optString("bot")
			pairLink = link
			render()
			if(openTg || pairShort.isEmpty())
				openLink(link)
			var tries = 0
			while(isActive && tries++ < PAIR_MAX_TRIES)
			{
				delay(PAIR_MS)
				val r = withContext(Dispatchers.IO) { AnyPlayCloud.pairPoll(this@AnyPlayActivity, code) }
				val token = r.json.optString("token")
				if(token.isNotEmpty())
				{
					AnyPlayCloud.setToken(this@AnyPlayActivity, token)
					state = "wait"
					render()
					toast("Вхід виконано ✓")
					refresh()
					return@launch
				}
				if(r.status == 404)
				{
					state = "login"
					render()
					toast("Посилання для входу застаріло. Спробуй ще раз.")
					return@launch
				}
			}
			if(isActive)
			{
				state = "login"
				render()
				toast("Час на вхід вийшов. Натисни «Увійти через Telegram» ще раз.")
			}
		}
	}

	private fun cancelLogin()
	{
		pairJob?.cancel()
		state = if(loggedIn) "wait" else "login"
		render()
	}

	// ── гра ──
	private fun play(takeover: Boolean = false)
	{
		if(busy)
			return
		busy = true
		render()
		lifecycleScope.launch {
			AnyPlayQuality.prepare(this@AnyPlayActivity)
			var takeoverMs = 0L
			var offerTakeover = false
			var helperOf = ""
			val target = withContext(Dispatchers.IO) {
				val r = if(takeover) AnyPlayCloud.request(this@AnyPlayActivity, "POST", "/api/app/session", JSONObject().put("takeover", true))
					else AnyPlayCloud.session(this@AnyPlayActivity)
				// сервер дав гру сюди; той пристрій відпустить приставку до waitUntil — доти «приставка зайнята» не помилка
				r.json.optJSONObject("takeover")?.let { t ->
					val now = r.json.optLong("now")
					val until = t.optLong("waitUntil")
					takeoverMs = if(until > 0 && now > 0) (until - now).coerceIn(5, 120) * 1000L else 30000L
				}
				// «Передати повністю»: друг грає в бронь власника; щойно передали — приставку ще кілька секунд відпускають
				r.json.optJSONObject("handoff")?.takeIf { it.optString("role") == "friend" }?.let { h ->
					helperOf = h.optJSONObject("owner")?.optString("name") ?: ""
					val now = r.json.optLong("now")
					val until = h.optLong("waitUntil")
					if(takeoverMs == 0L && until > now && now > 0)
						takeoverMs = (until - now).coerceIn(5, 120) * 1000L
				}
				if(r.ok && r.json.optString("state") == "other_device")
				{
					session = r.json
					offerTakeover = r.json.optBoolean("canTakeover")
				}
				if(!r.ok)
					(if(!AnyPlayCloud.online(this@AnyPlayActivity)) PlayError("Немає інтернету на телефоні. Увімкни Wi-Fi або мобільний інтернет і спробуй ще раз.", "NET offline")
					else PlayError("Немає зв'язку з сервером AnyPlay. Спробуй ще раз за хвилину.", "AP-HTTP ${r.status}"))
						.also { AnyPlayCloud.noteError(this@AnyPlayActivity, it) }
				else if(r.json.optString("state") == "other_device")
					PlayError("Зараз ти граєш на «${r.json.optString("otherDevice").ifEmpty { "іншому пристрої" }}». " +
						"Приставка тримає лише одне підключення: закрий гру там (меню AnyPlay → «Вийти з гри»), і тут з'явиться кнопка «Грати».")
				else if(r.json.optString("state") != "play")
					PlayError("Зараз грати не можна: час броні ще не настав або вже минув.")
				else
					AnyPlayCloud.playTarget(this@AnyPlayActivity, r.json)
			}
			busy = false
			if(target is PlayError && offerTakeover)
			{
				// новий сервер: замість «закрий гру там» одразу пропонуємо забрати гру сюди
				state = "other_device"
				render()
				AnyPlayStyle.show(MaterialAlertDialogBuilder(this@AnyPlayActivity)
					.setMessage("Гра вже йде на «${session.optString("otherDevice").ifEmpty { "іншому пристрої" }}». " +
						"Продовжити гру на цьому телефоні? Там гра зупиниться, твій час не змінюється.")
					.setPositiveButton("Грати тут") { _, _ -> play(true) }
					.setNegativeButton("Скасувати", null))
				return@launch
			}
			when(target)
			{
				is PlayReady -> startGame(target, takeoverMs, helperOf)
				is PlayError ->
				{
					render()
					// 118.1: невдала спроба — журнал для підтримки (сам не частіше ніж раз на 2 хв)
					if(target.code.isNotEmpty())
						AnyPlayCloud.uploadLog(this@AnyPlayActivity, "error", "Не вдалося почати гру: ${target.code}")
					AnyPlayStyle.show(MaterialAlertDialogBuilder(this@AnyPlayActivity)
						.setMessage(AnyPlayStyle.errorMessage(target.text, target.code))
						.setPositiveButton("Зрозуміло", null))
				}
			}
		}
	}

	private fun startGame(target: PlayReady, takeoverMs: Long, helperOf: String)
	{
		startActivity(Intent(this, StreamActivity::class.java).also {
			it.putExtra(StreamActivity.EXTRA_CONNECT_INFO, target.connectInfo)
			it.putExtra(StreamActivity.EXTRA_ANYPLAY_TAKEOVER_MS, takeoverMs)
			it.putExtra(StreamActivity.EXTRA_ANYPLAY, true)
			it.putExtra(StreamActivity.EXTRA_ANYPLAY_ADMIN, isAdmin)   // адміну нагадування про кінець гри не потрібні
			it.putExtra(StreamActivity.EXTRA_ANYPLAY_GUEST, target.guest)   // гість: без «Продовжити бронювання»
			it.putExtra(StreamActivity.EXTRA_ANYPLAY_HELPER_OF, helperOf)   // гра друга («Передати повністю»)
		})
	}

	// ── «Передати повністю» (етап 7), бік друга ──
	// Власник готує передачу (стан ready): сервер уже дає нам ключі його приставки, і ми заздалегідь шукаємо її в PSN.
	// Щойно він натисне «Передати» (active) — гра тут починається сама, без пошуку приставки; поки його програма
	// відпускає приставку (до waitUntil), «приставка зайнята» не помилка, а повтори раз на 3 с, як у «Грати тут».
	private var handoffJob: Job? = null
	private var handoffInfo: JSONObject? = null   // стан передачі для сторінки (без ключів)
	private var handoffTarget: PlayReady? = null
	private var handoffTargetAt = 0L
	private var handoffTargetId = 0L
	private var handoffLaunched = 0L

	private fun watchHandoff()
	{
		if(handoffJob?.isActive == true)
			return
		handoffJob = lifecycleScope.launch {
			while(isActive)
			{
				val r = withContext(Dispatchers.IO) { AnyPlayCloud.request(this@AnyPlayActivity, "GET", "/api/live/handoff") }
				val ho = if(r.ok) r.json.optJSONObject("handoff") else null
				if(r.status != 0 && (ho == null || ho.optString("role") != "friend" || ho.optString("state") !in setOf("ready", "active")))
				{
					// передачу скасували, повернули або сервер її не знає (старий сервер) — звичайний головний екран
					handoffInfo = null
					handoffTarget = null
					render()
					break
				}
				if(ho != null)
				{
					val id = ho.optLong("id")
					handoffInfo = JSONObject(ho.toString()).also { it.remove("console") }
					val console = ho.optJSONObject("console")
					if(console != null && !busy && (handoffTarget == null || handoffTargetId != id ||
							System.currentTimeMillis() - handoffTargetAt > HANDOFF_TARGET_MS))
					{
						val t = withContext(Dispatchers.IO) { AnyPlayCloud.playTarget(this@AnyPlayActivity, JSONObject().put("console", console)) }
						if(t is PlayReady)
						{
							handoffTarget = t
							handoffTargetAt = System.currentTimeMillis()
							handoffTargetId = id
						}
					}
					if(ho.optString("state") == "active" && handoffLaunched != id && !busy)
					{
						handoffLaunched = id
						val target = handoffTarget?.takeIf { handoffTargetId == id }
						if(target != null)
						{
							val until = ho.optLong("waitUntil")
							val now = System.currentTimeMillis() / 1000 + skew
							startGame(target, if(until > now) (until - now).coerceIn(5, 120) * 1000L else 30000L,
								ho.optJSONObject("owner")?.optString("name") ?: "")
						}
						else
							play()   // ключів наперед не отримали: звичайний шлях через сервер
						break
					}
					render()
				}
				delay(HANDOFF_POLL_MS)
			}
		}
	}

	// ── адмін ──
	private val adminCurrent get() = adminInfo?.optJSONObject("current")

	private fun confirm(text: String, yes: String, action: () -> Unit)
	{
		AnyPlayStyle.show(MaterialAlertDialogBuilder(this)
			.setMessage(text)
			.setPositiveButton(yes) { _, _ -> action() }
			.setNegativeButton("Скасувати", null))
	}

	/**
	 * Чи клієнт справді стрімить зараз. Новий сервер дає `streaming` (так/ні), а `live` там стає об'єктом телеметрії;
	 * старий сервер дає лише `live` (так/ні).
	 */
	private fun streaming(c: JSONObject): Boolean =
		if(c.has("streaming")) c.optBoolean("streaming") else c.opt("live").let { it == true || it is JSONObject }

	/** Адмін може зайти на приставку будь-коли, але про клієнта попереджаємо */
	private fun adminPlay()
	{
		val c = adminCurrent
		if(c == null)
			play()
		else if(c.let { streaming(it) })
			confirm("Зараз на приставці грає ${c.optString("user")}. Якщо підключишся, його трансляція перерветься. Підключитись?", "Підключитись") { play() }
		else
			confirm("Зараз час броні ${c.optString("user")} (він ще не підключився). Поки ти на приставці, клієнт не зможе зайти. Підключитись?", "Підключитись") { play() }
	}

	private fun adminSend(body: JSONObject, done: String, fail: String)
	{
		lifecycleScope.launch {
			val r = withContext(Dispatchers.IO) { AnyPlayCloud.adminAction(this@AnyPlayActivity, body) }
			toast(if(r.ok) done else "$fail (помилка ${r.status}).")
			refresh()
		}
	}

	private fun adminKick()
	{
		val c = adminCurrent ?: return
		confirm("Завершити гру ${c.optString("user")} просто зараз? Приставка відключиться, клієнт отримає повідомлення в боті.", "Завершити") {
			adminSend(JSONObject().put("action", "kick").put("bookingId", c.optLong("id")),
				"Гру клієнта завершено. Йому прийшло повідомлення в боті.", "Не вдалося завершити гру")
		}
	}

	private fun adminToggleClosed()
	{
		val a = adminInfo ?: return
		if(a.optBoolean("closed"))
			adminSend(JSONObject().put("action", "open"), "Доступ відкрито: клієнти знову грають у свій час.", "Не вдалося змінити доступ")
		else
			confirm("Тимчасово закрити доступ усім клієнтам? Хто грає, відключиться, бот показуватиме «технічні роботи», поки не відкриєш знову.", "Закрити доступ") {
				adminSend(JSONObject().put("action", "close"), "Доступ закрито: клієнти не можуть грати, бот показує «технічні роботи».", "Не вдалося змінити доступ")
			}
	}

	/** Заявки клієнтів на свій акаунт PSN */
	private fun showPsnClients()
	{
		val list = adminInfo?.optJSONArray("psnClients")
		val lines = ArrayList<String>()
		for(i in 0 until (list?.length() ?: 0))
		{
			val u = list!!.optJSONObject(i) ?: continue
			val status = when(u.optString("status"))
			{
				"signed_in" -> "уже увійшов на PS5, чекає прив'язки"
				"created" -> "профіль на PS5 створено, чекаємо, поки клієнт увійде"
				else -> "нова заявка"
			}
			lines.add("${u.optString("user")}\nPSN: ${u.optString("psn")}\n$status")
		}
		AnyPlayStyle.show(MaterialAlertDialogBuilder(this)
			.setTitle("Свої PSN клієнтів")
			.setMessage(if(lines.isEmpty()) "Заявок немає: усі клієнти зі своїм акаунтом уже підключені."
				else lines.joinToString("\n\n") + "\n\nПідключити клієнта можна в боті: там є кнопка «Клієнт уже на PS5: пустити без коду».")
			.setPositiveButton("Відкрити бота") { _, _ -> openBot() }
			.setNegativeButton("Закрити", null))
	}

	/** Спільний акаунт PSN, з якого грають клієнти без свого акаунта */
	private fun showSharedPsn()
	{
		val c = adminInfo?.optJSONObject("console")
		val text = if(c == null)
			"Спільний акаунт PSN ще не передано. Це робиться в програмі AnyPlay на комп'ютері: плитка «Спільний PSN»."
		else
		{
			val name = c.optString("psn_name").ifEmpty { "акаунт на ${c.optString("label").ifEmpty { "PS5" }}" }
			"Спільний акаунт: $name\nПриставка: ${c.optString("label").ifEmpty { "PS5" }}\n" +
				(if(c.optBoolean("tokenOk")) "Вхід у PSN діє, клієнти можуть грати." else "Вхід у PSN не діє: зайди в програму AnyPlay на комп'ютері й увійди в PSN знову.") +
				"\n\nЗмінити спільний акаунт можна в програмі на комп'ютері."
		}
		AnyPlayStyle.show(MaterialAlertDialogBuilder(this)
			.setTitle("Спільний PSN")
			.setMessage(text)
			.setPositiveButton("Зрозуміло", null))
	}

	private fun duration(seconds: Long): String
	{
		val m = (if(seconds > 0) seconds else 0L) / 60
		return if(m >= 60) "${m / 60} год ${m % 60} хв" else "$m хв"
	}

	private fun psnLine(b: JSONObject): String
	{
		val psn = b.optString("psn")
		if(psn.isEmpty())
			return ""
		var t = if(b.optBoolean("psnOwn")) "PSN: $psn (свій акаунт клієнта)" else "PSN: $psn (спільний акаунт AnyPlay)"
		val own = b.optString("clientPsn")
		if(!b.optBoolean("psnOwn") && own.isNotEmpty())
			t += "; свій $own ще підключається"
		return t
	}

	/** Панель адміна для сторінки: хто грає, найближчі броні, заявки на свій PSN, спільний акаунт */
	private fun adminView(a: JSONObject): JSONObject
	{
		val c = a.optJSONObject("current")
		val next = a.optJSONArray("next")
		val lines = ArrayList<String>()
		var from = 0
		if(c != null)
		{
			val left = c.optLong("end") - (System.currentTimeMillis() / 1000 + skew)
			lines.add((if(c.let { streaming(it) }) "у грі" else "ще не підключився") +
				", ${formatTime(c.optLong("start"))}–${formatTime(c.optLong("end"))}, лишилось ${duration(left)}")
			psnLine(c).let { if(it.isNotEmpty()) lines.add(it) }
		}
		else if(next != null && next.length() > 0)
		{
			val n = next.optJSONObject(0)
			lines.add("Наступна бронь: ${n.optString("user")}, ${formatTime(n.optLong("start"))}–${formatTime(n.optLong("end"))}")
			psnLine(n).let { if(it.isNotEmpty()) lines.add(it) }
			from = 1
		}
		else
			lines.add("Найближчих оплачених броней немає.")
		for(i in from until minOf(from + 2, next?.length() ?: 0))
		{
			val n = next!!.optJSONObject(i) ?: continue
			lines.add("далі: ${n.optString("user")}, ${formatTime(n.optLong("start"))}–${formatTime(n.optLong("end"))}")
		}
		val shared = a.optJSONObject("console")
		return JSONObject()
			.put("closed", a.optBoolean("closed"))
			.put("title", c?.optString("user") ?: "")
			.put("current", c != null)
			.put("lines", JSONArray(lines))
			.put("waiting", a.optJSONArray("psnClients")?.length() ?: 0)
			.put("shared", shared?.optString("psn_name")?.ifEmpty { null } ?: if(shared != null) "передано" else "не передано")
	}

	// ── вигляд ──
	private fun formatTime(serverTs: Long): String
	{
		if(serverTs <= 0)
			return ""
		// до найближчої хвилини: зсув годинника на секунду-дві не має перетворювати «19:00» на «18:59»
		val date = Date(Math.round((serverTs - skew) / 60.0) * 60_000L)
		val cal = Calendar.getInstance().apply { time = date }
		val today = Calendar.getInstance()
		val tomorrow = Calendar.getInstance().apply { add(Calendar.DAY_OF_YEAR, 1) }
		fun sameDay(a: Calendar, b: Calendar) = a.get(Calendar.YEAR) == b.get(Calendar.YEAR) && a.get(Calendar.DAY_OF_YEAR) == b.get(Calendar.DAY_OF_YEAR)
		val time = SimpleDateFormat("HH:mm", Locale.getDefault()).format(date)
		return when
		{
			sameDay(cal, today) -> time
			sameDay(cal, tomorrow) -> "завтра о $time"
			else -> SimpleDateFormat("d.MM", Locale.getDefault()).format(date) + " о $time"
		}
	}

	/** Передати сторінці поточний стан: вона сама малює потрібний екран і кнопки */
	private fun render()
	{
		val o = JSONObject()
			.put("state", state)
			.put("loggedIn", loggedIn)
			.put("busy", busy)
			.put("admin", isAdmin)
			.put("skew", skew)
			.put("build", BuildConfig.ANYPLAY_BUILD)
			.put("user", if(loggedIn) session.optString("user") else "")
			.put("quality", AnyPlayQuality.json(this))
			.put("pairShort", if(state == "pairing") pairShort else "")
			.put("pairBot", pairBot)
		updater.offerJson()?.let { o.put("update", it) }   // 118: нова версія для рядка на головному екрані
		// зі стану сервера лише те, що показує сторінка: ключів доступу до PSN тут немає
		val s = JSONObject()
		for(k in arrayOf("next", "booking", "closed", "myPsn", "myPsnReady", "myPsnStatus", "otherDevice", "otherSeen", "canTakeover", "guest", "guestAccess", "guestWait", "guestFreeAt", "handoff", "handoffOffer"))
			session.opt(k)?.let { s.put(k, it) }
		session.optJSONObject("console")?.let { s.put("console", JSONObject().put("psn", it.optString("psn")).put("own", it.optBoolean("own"))) }
		// баланс клієнта {balances, primary}: сторінка показує вкладку «Баланс» і оплату з балансу лише коли він є
		// (у адміна балансу немає, старий сервер поля не дає)
		if(!isAdmin)
			session.optJSONObject("wallet")?.let { s.put("wallet", it) }
		o.put("session", s)
		handoffInfo?.let { o.put("handoffLive", it) }   // «Передати повністю»: свіжіший стан, ніж у session
		if(isAdmin)
			adminInfo?.let { o.put("adminView", adminView(it)) }
		homeJson = o.toString()
		if(::web.isInitialized)
			web.evaluateJavascript("window.__anyplayHome && window.__anyplayHome(${JSONObject.quote(homeJson)})", null)
	}

	private fun openBot() = openLink(AnyPlayCloud.BOT_URL)

	private fun openLink(link: String)
	{
		try
		{
			startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(link)))
		}
		catch(e: ActivityNotFoundException)
		{
			toast("Не вдалося відкрити Telegram. Встанови Telegram або відкрий бота @play_any_bot вручну.")
		}
	}

	private fun toast(text: String) = Toast.makeText(this, text, Toast.LENGTH_LONG).show()
}
