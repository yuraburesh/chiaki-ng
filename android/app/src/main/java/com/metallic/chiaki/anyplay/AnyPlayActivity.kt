// AnyPlay: головний екран — вхід через Telegram, стан броні, кнопка «Грати».
package com.metallic.chiaki.anyplay

import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.res.Configuration
import android.net.Uri
import android.os.Bundle
import android.view.View
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import com.metallic.chiaki.BuildConfig
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import com.metallic.chiaki.databinding.ActivityAnyplayBinding
import com.metallic.chiaki.stream.StreamActivity
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

class AnyPlayActivity: AppCompatActivity()
{
	companion object
	{
		private const val POLL_MS = 8000L
		private const val PAIR_MS = 2000L
		private const val PAIR_MAX_TRIES = 150
	}

	private lateinit var binding: ActivityAnyplayBinding
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
		bindViews()
		updater.onCreate()
	}

	override fun onDestroy()
	{
		updater.onDestroy()
		super.onDestroy()
	}

	/** Екран повернули: вертикальна й горизонтальна розкладки різні, стан програми лишається */
	override fun onConfigurationChanged(newConfig: Configuration)
	{
		super.onConfigurationChanged(newConfig)
		bindViews()
	}

	private fun bindViews()
	{
		binding = ActivityAnyplayBinding.inflate(layoutInflater)
		setContentView(binding.root)

		binding.versionLabel.text = "AnyPlay для Android, збірка ${BuildConfig.ANYPLAY_BUILD}"
		binding.logoutButton.setOnClickListener {
			MaterialAlertDialogBuilder(this)
				.setMessage("Вийти з AnyPlay на цьому телефоні?")
				.setPositiveButton("Вийти") { _, _ -> logout() }
				.setNegativeButton("Скасувати", null)
				.show()
		}
		binding.primaryButton.setOnClickListener { primaryClicked() }
		binding.secondaryButton.setOnClickListener { secondaryClicked() }
		binding.tertiaryButton.setOnClickListener { adminToggleClosed() }
		binding.tileBooking.setOnClickListener {
			if(isAdmin)
			{
				openBot()
				toast("У боті натисни кнопку «CRM» внизу зліва")
			}
			else
				openWeb("book")
		}
		binding.tilePsn.setOnClickListener { if(isAdmin) showPsnClients() else openWeb("psn") }
		binding.tileSupport.setOnClickListener { if(isAdmin) showSharedPsn() else openBot() }
		binding.helpLink.setOnClickListener { AnyPlayWebDialog(this, "help").show() }
		binding.tileQuality.setOnClickListener { AnyPlayQuality.choose(this) { render() } }
		render()
	}

	private val loggedIn get() = AnyPlayCloud.token(this).isNotEmpty()

	override fun onResume()
	{
		super.onResume()
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
		pollJob?.cancel()
		updater.onPause()
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
				})
				is PlayError ->
				{
					render()
					MaterialAlertDialogBuilder(this@AnyPlayActivity)
						.setMessage(target.text)
						.setPositiveButton("Зрозуміло", null)
						.show()
				}
			}
		}
	}

	private fun primaryClicked()
	{
		if(isAdmin && adminInfo != null && (state == "play" || state == "wait" || state == "no_console"))
		{
			adminPlay()
			return
		}
		when(state)
		{
			"login" -> login()
			"pairing" -> cancelLogin()
			"play" -> if(isAdmin) adminPlay() else play()
			"offline" -> lifecycleScope.launch { refresh() }
			"wait" -> openWeb(if((session.optJSONObject("next")?.optLong("start") ?: 0L) > 0) "mine" else "book")
			"update" -> updater.updateNow {
				openBot()
				toast("Нову версію можна завантажити в боті: кнопка «Програма».")
			}
			else -> openBot()
		}
	}

	private fun secondaryClicked()
	{
		if(isAdmin && adminInfo != null)
			adminKick()
		else if(state == "play")
			openWeb(if(session.optJSONObject("booking") != null) "extend" else "book")
	}

	// ── адмін ──
	private val adminCurrent get() = adminInfo?.optJSONObject("current")

	private fun confirm(text: String, yes: String, action: () -> Unit)
	{
		MaterialAlertDialogBuilder(this)
			.setMessage(text)
			.setPositiveButton(yes) { _, _ -> action() }
			.setNegativeButton("Скасувати", null)
			.show()
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
		MaterialAlertDialogBuilder(this)
			.setTitle("Свої PSN клієнтів")
			.setMessage(if(lines.isEmpty()) "Заявок немає: усі клієнти зі своїм акаунтом уже підключені."
				else lines.joinToString("\n\n") + "\n\nПідключити клієнта можна в боті: там є кнопка «Клієнт уже на PS5: пустити без коду».")
			.setPositiveButton("Відкрити бота") { _, _ -> openBot() }
			.setNegativeButton("Закрити", null)
			.show()
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
		MaterialAlertDialogBuilder(this)
			.setTitle("Спільний PSN")
			.setMessage(text)
			.setPositiveButton("Зрозуміло", null)
			.show()
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

	private fun renderAdmin(a: JSONObject)
	{
		val closed = a.optBoolean("closed")
		val c = a.optJSONObject("current")
		val next = a.optJSONArray("next")
		binding.cardKicker.text = if(closed) "ДОСТУП КЛІЄНТАМ ЗАКРИТО" else "ПАНЕЛЬ АДМІНА"
		binding.cardKicker.setTextColor(if(closed) 0xFFFF4D6D.toInt() else 0xFF5FD4FF.toInt())
		binding.cardTitle.text = if(busy) "Шукаємо приставку…" else c?.optString("user") ?: "Зараз ніхто не грає"
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
		binding.cardText.text = lines.joinToString("\n")
		binding.cardProgress.visibility = if(busy) View.VISIBLE else View.GONE
		binding.primaryButton.text = "Підключитись до приставки"
		binding.secondaryButton.text = "Завершити гру"
		binding.secondaryButton.visibility = if(c != null) View.VISIBLE else View.GONE
		binding.tertiaryButton.text = if(closed) "Відкрити доступ" else "Закрити доступ"
		binding.tertiaryButton.visibility = View.VISIBLE
	}

	/** Бронювання, продовження, «Мій PSN» — вбудовані екрани */
	private fun openWeb(page: String)
	{
		if(!loggedIn)
		{
			toast("Спершу увійди через Telegram.")
			return
		}
		AnyPlayWebDialog(this, page) { lifecycleScope.launch { refresh() } }.show()
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

	private fun render()
	{
		val user = session.optString("user")
		binding.userLabel.text = if(loggedIn && user.isNotEmpty()) user else ""
		binding.logoutButton.visibility = if(loggedIn) View.VISIBLE else View.GONE
		binding.tileQuality.text = "Якість\n${AnyPlayQuality.name(this)}"
		val admin = isAdmin
		val a = adminInfo
		val myPsn = session.optString("myPsn")
		if(admin)
		{
			val waiting = a?.optJSONArray("psnClients")?.length() ?: 0
			val shared = a?.optJSONObject("console")
			binding.tileBooking.text = "CRM\nброні й клієнти"
			binding.tilePsn.text = if(waiting > 0) "Свої PSN\nчекають: $waiting" else "Свої PSN\nнемає заявок"
			binding.tileSupport.text = "Спільний PSN\n" + (shared?.optString("psn_name")?.ifEmpty { null } ?: if(shared != null) "передано" else "не передано")
		}
		else
		{
			binding.tileBooking.text = getString(com.metallic.chiaki.R.string.anyplay_tile_booking)
			binding.tilePsn.text = when
			{
				myPsn.isEmpty() -> "Мій PSN\nпідключити свій"
				session.optBoolean("myPsnReady") -> "Мій PSN\n$myPsn"
				else -> "Мій PSN\nпідключається"
			}
			binding.tileSupport.text = getString(com.metallic.chiaki.R.string.anyplay_tile_support)
		}
		binding.tileBooking.setCompoundDrawablesWithIntrinsicBounds(0, if(admin) com.metallic.chiaki.R.drawable.ap_chart else com.metallic.chiaki.R.drawable.ap_calendar, 0, 0)
		binding.tileSupport.setCompoundDrawablesWithIntrinsicBounds(0, if(admin) com.metallic.chiaki.R.drawable.ap_user else com.metallic.chiaki.R.drawable.ap_chat, 0, 0)
		binding.secondaryButton.visibility = View.GONE
		binding.tertiaryButton.visibility = View.GONE
		binding.cardProgress.visibility = View.GONE
		binding.cardKicker.text = "ТВОЯ ГРА"
		binding.cardKicker.setTextColor(0xFF5FD4FF.toInt())

		if(admin && a != null && (state == "play" || state == "wait" || state == "no_console"))
		{
			renderAdmin(a)
			return
		}

		val next = session.optJSONObject("next")
		val booking = session.optJSONObject("booking")
		when(state)
		{
			"login" ->
			{
				binding.cardKicker.text = "ЛАСКАВО ПРОСИМО"
				binding.cardTitle.text = "Грай у PS5 зі свого телефона"
				binding.cardText.text = "Увійди через Telegram: це той самий акаунт, з якого ти бронюєш час у боті."
				binding.primaryButton.text = "Увійти через Telegram"
			}
			"pairing" ->
			{
				binding.cardKicker.text = "ВХІД"
				binding.cardTitle.text = "Підтвердь вхід у Telegram"
				binding.cardText.text = "Відкрився бот AnyPlay. Натисни там «Старт» і повернись сюди: програма продовжить сама."
				binding.cardProgress.visibility = View.VISIBLE
				binding.primaryButton.text = "Скасувати"
			}
			"play" ->
			{
				val end = booking?.optLong("end") ?: 0L
				val console = session.optJSONObject("console")
				val psn = console?.optString("psn") ?: ""
				val own = console?.optBoolean("own") ?: false
				binding.cardTitle.text = if(busy) "Шукаємо приставку…" else "Можна грати!"
				val lines = ArrayList<String>()
				if(end > 0)
					lines.add("Твій час до ${formatTime(end)}")
				if(psn.isNotEmpty())
					lines.add("Акаунт PSN: $psn (${if(own) "твій" else "спільний"})")
				if(busy)
					lines.add("Це займає до хвилини.")
				binding.cardText.text = lines.joinToString("\n")
				binding.cardProgress.visibility = if(busy) View.VISIBLE else View.GONE
				binding.primaryButton.text = "Грати"
				binding.secondaryButton.text = if(booking != null) "Продовжити гру" else "Забронювати час"
				binding.secondaryButton.visibility = View.VISIBLE
			}
			"no_console" ->
			{
				binding.cardTitle.text = if(session.optBoolean("closed")) "Технічні роботи" else "Приставка зараз недоступна"
				binding.cardText.text = "Ми вже це лагодимо. Твоя бронь і оплата збережені. Якщо є питання, напиши в підтримку."
				binding.primaryButton.text = "Відкрити бота"
			}
			"update" ->
			{
				binding.cardTitle.text = "Потрібна нова версія"
				binding.cardText.text = "Ця версія програми застаріла й більше не підключається до приставки. Натисни «Оновити»: нова версія встановиться сама, вхід і броні збережуться."
				binding.primaryButton.text = "Оновити"
			}
			"offline" ->
			{
				binding.cardTitle.text = "Немає зв'язку"
				binding.cardText.text = "Не вдається з'єднатися з сервером AnyPlay. Перевір інтернет."
				binding.primaryButton.text = "Спробувати ще раз"
			}
			else ->
			{
				val start = next?.optLong("start") ?: 0L
				val end = next?.optLong("end") ?: 0L
				if(start > 0)
				{
					binding.cardTitle.text = "Твоя бронь: ${formatTime(start)}"
					binding.cardText.text = "Грати можна з ${formatTime(start)} до ${formatTime(end)}. Кнопка «Грати» з'явиться тут сама."
					binding.primaryButton.text = "Мої броні"
				}
				else
				{
					binding.cardTitle.text = "Броні поки немає"
					binding.cardText.text = "Забронюй час прямо тут. Коли він настане, з'явиться кнопка «Грати»."
					binding.primaryButton.text = "Забронювати"
				}
			}
		}
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
