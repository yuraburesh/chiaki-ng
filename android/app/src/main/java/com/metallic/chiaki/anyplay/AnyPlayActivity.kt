// AnyPlay: головний екран — вхід через Telegram, стан броні, кнопка «Грати».
// Вигляд — сторінка assets/anyplay/app.html з вкладками «Гра», «Бронювання», «Якість», «Мій PSN», «Як керувати»;
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
	}

	private lateinit var web: WebView
	@Volatile private var homeJson = "{}"   // останній стан для сторінки (сторінка читає його не з головного потоку)
	private var state = "login"          // login | pairing | wait | play | no_console | update | offline
	private var session = JSONObject()
	private var skew = 0L                // час сервера мінус час телефона, секунди
	private var pairJob: Job? = null
	private var pollJob: Job? = null
	private var busy = false             // шукаємо приставку перед грою
	private var adminInfo: JSONObject? = null   // лише для адміна: хто грає, наступні броні, заявки
	// оновлення програми: вікна лише на цьому екрані й не під час пошуку приставки чи входу
	private val updater = AnyPlayUpdater(this) { !busy && state != "pairing" }

	private val isAdmin get() = loggedIn && session.optBoolean("admin")

	override fun onCreate(savedInstanceState: Bundle?)
	{
		super.onCreate(savedInstanceState)
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
		updater.onPause()
	}

	// ── сторінка ──

	override fun info(): String = homeJson

	/** Команди сторінки головного екрана */
	override fun action(name: String, arg: String)
	{
		when(name)
		{
			"login" -> if(state == "login") login()
			"cancelLogin" -> cancelLogin()
			"play" -> if(isAdmin && adminInfo != null) adminPlay() else play()
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
			"crm" ->
			{
				openBot()
				toast("У боті натисни кнопку «CRM» внизу зліва")
			}
			"adminPsn" -> showPsnClients()
			"adminShared" -> showSharedPsn()
			"adminKick" -> adminKick()
			"adminToggle" -> adminToggleClosed()
		}
	}

	override fun qualityChanged() = render()

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
		if(r.json.optBoolean("admin"))
		{
			val a = withContext(Dispatchers.IO) { AnyPlayCloud.admin(this@AnyPlayActivity) }
			if(a.ok)
				adminInfo = a.json
		}
		else
			adminInfo = null
		state = when(r.json.optString("state"))
		{
			"play" -> "play"
			"no_console" -> "no_console"
			"update" -> "update"
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
	private fun login()
	{
		state = "pairing"
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
	private fun play()
	{
		if(busy)
			return
		busy = true
		render()
		lifecycleScope.launch {
			AnyPlayQuality.prepare(this@AnyPlayActivity)
			val target = withContext(Dispatchers.IO) {
				val r = AnyPlayCloud.session(this@AnyPlayActivity)
				if(!r.ok)
					PlayError("Немає зв'язку з сервером AnyPlay. Перевір інтернет.")
				else if(r.json.optString("state") != "play")
					PlayError("Зараз грати не можна: час броні ще не настав або вже минув.")
				else
					AnyPlayCloud.playTarget(this@AnyPlayActivity, r.json)
			}
			busy = false
			when(target)
			{
				is PlayReady -> startActivity(Intent(this@AnyPlayActivity, StreamActivity::class.java).also {
					it.putExtra(StreamActivity.EXTRA_CONNECT_INFO, target.connectInfo)
					it.putExtra(StreamActivity.EXTRA_ANYPLAY, true)
					it.putExtra(StreamActivity.EXTRA_ANYPLAY_ADMIN, isAdmin)   // адміну нагадування про кінець гри не потрібні
				})
				is PlayError ->
				{
					render()
					AnyPlayStyle.show(MaterialAlertDialogBuilder(this@AnyPlayActivity)
						.setMessage(target.text)
						.setPositiveButton("Зрозуміло", null))
				}
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

	/** Адмін може зайти на приставку будь-коли, але про клієнта попереджаємо */
	private fun adminPlay()
	{
		val c = adminCurrent
		if(c == null)
			play()
		else if(c.optBoolean("live"))
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
			lines.add((if(c.optBoolean("live")) "у грі" else "ще не підключився") +
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
		val date = Date((serverTs - skew) * 1000)
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
		// зі стану сервера лише те, що показує сторінка: ключів доступу до PSN тут немає
		val s = JSONObject()
		for(k in arrayOf("next", "booking", "closed", "myPsn", "myPsnReady", "myPsnStatus"))
			session.opt(k)?.let { s.put(k, it) }
		session.optJSONObject("console")?.let { s.put("console", JSONObject().put("psn", it.optString("psn")).put("own", it.optBoolean("own"))) }
		o.put("session", s)
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
