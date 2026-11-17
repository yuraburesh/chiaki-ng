// AnyPlay: головний екран — вхід через Telegram, стан броні, кнопка «Грати».
package com.metallic.chiaki.anyplay

import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.view.View
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import com.metallic.chiaki.common.Preferences
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

	override fun onCreate(savedInstanceState: Bundle?)
	{
		super.onCreate(savedInstanceState)
		binding = ActivityAnyplayBinding.inflate(layoutInflater)
		setContentView(binding.root)

		binding.versionLabel.text = "AnyPlay для Android, збірка ${AnyPlayCloud.BUILD}"
		binding.logoutButton.setOnClickListener {
			MaterialAlertDialogBuilder(this)
				.setMessage("Вийти з AnyPlay на цьому телефоні?")
				.setPositiveButton("Вийти") { _, _ -> logout() }
				.setNegativeButton("Скасувати", null)
				.show()
		}
		binding.primaryButton.setOnClickListener { primaryClicked() }
		binding.secondaryButton.setOnClickListener { secondaryClicked() }
		binding.tileBooking.setOnClickListener { openWeb("book") }
		binding.tilePsn.setOnClickListener { openWeb("psn") }
		binding.tileSupport.setOnClickListener { openBot() }
		binding.tileQuality.setOnClickListener { chooseQuality() }

		state = if(loggedIn) "wait" else "login"
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
				delay(POLL_MS)
			}
		}
	}

	override fun onPause()
	{
		super.onPause()
		pollJob?.cancel()
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
		when(state)
		{
			"login" -> login()
			"pairing" -> cancelLogin()
			"play" -> play()
			"offline" -> lifecycleScope.launch { refresh() }
			"wait" -> openWeb(if((session.optJSONObject("next")?.optLong("start") ?: 0L) > 0) "mine" else "book")
			else -> openBot()
		}
	}

	private fun secondaryClicked()
	{
		if(state == "play")
			openWeb(if(session.optJSONObject("booking") != null) "extend" else "book")
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

	// ── якість ──
	private data class Quality(val title: String, val hint: String, val resolution: Preferences.Resolution, val fps: Preferences.FPS, val bitrate: Int?)
	private val qualities = listOf(
		Quality("Економна", "540p, 30 кадрів: для слабкого або мобільного інтернету", Preferences.Resolution.RES_540P, Preferences.FPS.FPS_30, null),
		Quality("Оптимальна", "720p, 60 кадрів: підходить більшості", Preferences.Resolution.RES_720P, Preferences.FPS.FPS_60, null),
		Quality("Максимальна", "1080p, 60 кадрів: потрібен швидкий Wi-Fi", Preferences.Resolution.RES_1080P, Preferences.FPS.FPS_60, 25000))

	private fun currentQuality(): Quality
	{
		val p = Preferences(this)
		return qualities.firstOrNull { it.resolution == p.resolution && it.fps == p.fps } ?: when
		{
			p.resolution == Preferences.Resolution.RES_1080P -> qualities[2]
			p.resolution == Preferences.Resolution.RES_720P -> qualities[1]
			else -> qualities[0]
		}
	}

	private fun chooseQuality()
	{
		val current = qualities.indexOf(currentQuality())
		MaterialAlertDialogBuilder(this)
			.setTitle("Якість картинки")
			.setSingleChoiceItems(qualities.map { "${it.title}\n${it.hint}" }.toTypedArray(), current) { dialog, which ->
				val q = qualities[which]
				val p = Preferences(this)
				p.resolution = q.resolution
				p.fps = q.fps
				p.bitrate = q.bitrate
				dialog.dismiss()
				render()
			}
			.setNegativeButton("Закрити", null)
			.show()
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
		binding.userLabel.text = if(loggedIn && user.isNotEmpty()) "👤 $user" else ""
		binding.logoutButton.visibility = if(loggedIn) View.VISIBLE else View.GONE
		binding.tileQuality.text = "🎚\nЯкість: ${currentQuality().title}"
		val myPsn = session.optString("myPsn")
		binding.tilePsn.text = when
		{
			myPsn.isEmpty() -> "🎮\nМій PSN: підключити"
			session.optBoolean("myPsnReady") -> "🎮\nМій PSN: $myPsn"
			else -> "🎮\nМій PSN: підключається"
		}
		binding.secondaryButton.visibility = View.GONE
		binding.cardProgress.visibility = View.GONE
		binding.cardKicker.text = if(session.optBoolean("admin")) "ПАНЕЛЬ АДМІНА" else "ТВОЯ ГРА"

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
				binding.primaryButton.text = "▶  Грати"
				binding.secondaryButton.text = if(booking != null) "⏱ Продовжити гру" else "📅 Забронювати час"
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
				binding.cardText.text = "Ця версія програми застаріла й більше не підключається до приставки. Завантаж нову в боті: кнопка «Програма»."
				binding.primaryButton.text = "Завантажити в боті"
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
					binding.primaryButton.text = "📅 Мої броні"
				}
				else
				{
					binding.cardTitle.text = "Броні поки немає"
					binding.cardText.text = "Забронюй час прямо тут. Коли він настане, з'явиться кнопка «Грати»."
					binding.primaryButton.text = "📅 Забронювати"
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
