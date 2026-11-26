// AnyPlay: оновлення програми всередині неї — сервер каже, чи є нова збірка, APK береться з GitHub,
// перевіряється (розмір + SHA-256) і встановлюється через PackageInstaller.
package com.metallic.chiaki.anyplay

import android.app.PendingIntent
import android.content.ActivityNotFoundException
import android.content.BroadcastReceiver
import android.content.Context
import android.content.DialogInterface
import android.content.Intent
import android.content.pm.PackageInstaller
import android.content.res.ColorStateList
import android.net.Uri
import android.os.Build
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
import android.view.View
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.IntentCompat
import androidx.lifecycle.lifecycleScope
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import com.metallic.chiaki.BuildConfig
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.lang.ref.WeakReference
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.Locale

/** Нова збірка з /api/app/update */
class AnyPlayUpdate(val build: Int, val version: String, val url: String, val sha256: String, val size: Long,
	val mandatory: Boolean, val notes: String, val manual: String)
{
	companion object
	{
		private val HEX64 = Regex("^[0-9a-f]{64}$")

		fun parse(o: JSONObject?): AnyPlayUpdate?
		{
			if(o == null)
				return null
			val build = o.optInt("build")
			val url = o.optString("url")
			val sha = o.optString("sha256").lowercase(Locale.ROOT)
			val size = o.optLong("size")
			// лише справжня нова збірка, лише HTTPS і з контрольною сумою
			if(build <= BuildConfig.ANYPLAY_BUILD || !url.startsWith("https://") || !HEX64.matches(sha) || size <= 0)
				return null
			return AnyPlayUpdate(build, o.optString("version").ifEmpty { "1.0.$build" }, url, sha, size,
				o.optBoolean("mandatory"), o.optString("notes").trim(),
				o.optString("manual").ifEmpty { AnyPlayCloud.BOT_URL })
		}
	}
}

/** Файл не той, що обіцяв сервер: зайвий розмір або інша контрольна сума */
private class CorruptUpdateException: IOException()

/** На телефоні не вистачає місця для файлу оновлення і його встановлення */
private class NoSpaceException(val missing: Long): IOException()

/**
 * Перевіряє оновлення і веде користувача через завантаження та встановлення.
 * Живе разом з AnyPlayActivity; вікна показує лише коли головний екран на виду
 * (під час гри зверху StreamActivity — тоді все чекає до повернення).
 *
 * AnyPlay 118 («не пропонує сама оновитись»): до 118 перевірка йшла лише при створенні головного екрана і далі раз на
 * 6 годин, а невдала перевірка (телефон щойно прокинувся, мережа ще не піднялась) теж рахувалась як зроблена — тож
 * програма, що жила у фоні днями, могла не бачити нову версію пів доби й більше. Після «Пізніше» нагадування не було
 * зовсім. Тепер: перевірка на старті, при кожному поверненні в застосунок (не частіше ніж раз на 5 хв), раз на годину,
 * поки головний екран на виду, і через хвилину після невдалої; знайдена версія видна на головному екрані постійно
 * (рядок «Доступна версія …»), а вікно після «Пізніше» з'являється знову через 12 годин або при наступному запуску.
 */
class AnyPlayUpdater(private val activity: AppCompatActivity, private val canShowExtra: () -> Boolean,
	private val onChanged: () -> Unit = {})
{
	companion object
	{
		const val ACTION_INSTALL_STATUS = "app.anyplay.android.UPDATE_STATUS"
		private const val PREFS = "anyplay_update"
		private const val KEY_PENDING = "pending_build"    // користувач уже натиснув «Оновити» для цієї збірки
		private const val KEY_RELAUNCH = "relaunch_build"  // після встановлення цієї збірки відкрити AnyPlay знову
		private const val KEY_SNOOZE_BUILD = "snooze_build"   // «Пізніше» для цієї збірки…
		private const val KEY_SNOOZE_UNTIL = "snooze_until"   // …до цього часу (мс, годинник телефона)
		private const val SNOOZE_MS = 12 * 60 * 60 * 1000L
		private const val CHECK_EVERY_MS = 60 * 60 * 1000L          // поки головний екран на виду
		private const val CHECK_ON_RETURN_MS = 5 * 60 * 1000L       // повернулись у застосунок
		private const val CHECK_RETRY_MS = 60 * 1000L               // після невдалої перевірки
		private const val CHECK_UPDATE_STATE_MS = 60 * 1000L
		private const val MB = 1024.0 * 1024.0

		@Volatile
		private var current: WeakReference<AnyPlayUpdater>? = null

		private fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

		private fun updatesDir(context: Context) = File(context.cacheDir, "updates")

		/** Відповідь PackageInstaller (через AnyPlayInstallReceiver) */
		fun onInstallStatus(context: Context, intent: Intent)
		{
			val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)
			val updater = current?.get()
			when(status)
			{
				PackageInstaller.STATUS_PENDING_USER_ACTION ->
				{
					val confirm = IntentCompat.getParcelableExtra(intent, Intent.EXTRA_INTENT, Intent::class.java) ?: return
					if(updater != null)
						updater.confirmInstall(confirm)
					else
						startSafely(context, confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
				}
				PackageInstaller.STATUS_SUCCESS -> relaunch(context)
				PackageInstaller.STATUS_FAILURE_ABORTED ->
				{
					prefs(context).edit().remove(KEY_RELAUNCH).apply()
					updater?.installAborted()
				}
				else ->
				{
					prefs(context).edit().remove(KEY_RELAUNCH).apply()
					updater?.installFailed()
				}
			}
		}

		/** Нова версія встановилась: відкриваємо AnyPlay знову (лише якщо оновлення запускали ми) */
		fun relaunch(context: Context)
		{
			val p = prefs(context)
			if(p.getInt(KEY_RELAUNCH, 0) <= 0)
				return
			p.edit().remove(KEY_RELAUNCH).remove(KEY_PENDING).apply()
			val launch = context.packageManager.getLaunchIntentForPackage(context.packageName) ?: return
			startSafely(context, launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
		}

		private fun startSafely(context: Context, intent: Intent)
		{
			try
			{
				context.startActivity(intent)
			}
			catch(e: Exception)
			{
				// система може не дозволити відкрити вікно з фону — тоді користувач відкриє AnyPlay сам
			}
		}
	}

	private enum class Phase { IDLE, PERMISSION, DOWNLOADING, INSTALLING }
	private enum class Failure { NETWORK, CORRUPT, INSTALL, SPACE }

	private var phase = Phase.IDLE
	private var offer: AnyPlayUpdate? = null
	private var dialog: AlertDialog? = null
	private var statusText: TextView? = null
	private var progressBar: ProgressBar? = null
	private var job: Job? = null
	@Volatile private var conn: HttpURLConnection? = null
	private var checking = false
	private var lastCheck = 0L                 // SystemClock.elapsedRealtime() останньої вдалої перевірки (0 — ще не було)
	private var lastTry = 0L                   // останньої спроби (вдалої чи ні)
	private var lastFailed = false
	private var shownThisRun = 0               // збірка, вікно якої вже показали від запуску (без «Пізніше» не повторюємо)
	private var resumed = false
	private var deferred: (() -> Unit)? = null // що показати, коли головний екран знову на виду
	private var confirmLaunched = false
	private var lastState = ""                 // стан з останнього опитування сервера (play, wait, update…)
	private var offerDialog: AlertDialog? = null   // вікно «Доступна версія», яке не можна закрити (обов'язкове)
	private var missingBytes = 0L

	private val canShow get() = resumed && !activity.isFinishing && canShowExtra()

	// ── життєвий цикл (викликає AnyPlayActivity) ──

	fun onCreate()
	{
		current = WeakReference(this)
		cleanup()
		check()
	}

	/** Чи пора перевіряти: давно не перевіряли (поріг залежить від нагоди) або минула спроба не вдалась */
	private fun due(normalMs: Long): Boolean
	{
		val now = SystemClock.elapsedRealtime()
		if(lastFailed)
			return now - lastTry > CHECK_RETRY_MS
		return lastCheck == 0L || now - lastCheck > normalMs
	}

	/** Для головного екрана: знайдена нова версія {build, version, notes, mandatory, busy} або null */
	fun offerJson(): JSONObject?
	{
		val u = offer ?: return null
		return JSONObject()
			.put("build", u.build)
			.put("version", u.version)
			.put("notes", u.notes)
			.put("mandatory", u.mandatory)
			.put("busy", phase != Phase.IDLE)
	}

	private fun snoozed(u: AnyPlayUpdate): Boolean
	{
		val p = prefs(activity)
		return !u.mandatory && p.getInt(KEY_SNOOZE_BUILD, 0) == u.build && System.currentTimeMillis() < p.getLong(KEY_SNOOZE_UNTIL, 0)
	}

	fun onResume()
	{
		resumed = true
		current = WeakReference(this)
		when
		{
			phase == Phase.PERMISSION -> offer?.let { start(it) }
			phase == Phase.INSTALLING && confirmLaunched -> activity.lifecycleScope.launch {
				// після «Встановити» система ще кілька секунд ставить нову версію й сама закриє AnyPlay;
				// якщо ж вікно системи закрили, а відповіді так і нема, — даємо скасувати вручну
				delay(5000)
				if(resumed && phase == Phase.INSTALLING && confirmLaunched)
					setStatus("Встановлюємо, AnyPlay відкриється сам", cancellable = true)
			}
			else -> {}
		}
		runDeferred()
		// повернулись у застосунок (з гри, з Telegram, з фону): перевіряємо, якщо давно не перевіряли
		if(due(CHECK_ON_RETURN_MS))
			check()
		else
			offer?.let { u -> if(phase == Phase.IDLE && dialog == null && shownThisRun != u.build && !snoozed(u)) whenVisible { offerAgain(u) } }
	}

	fun onPause()
	{
		resumed = false
	}

	fun onDestroy()
	{
		resumed = false
		job?.cancel()
		dropConnection()
		dialog?.dismiss()
		dialog = null
		if(current?.get() === this)
			current = null
	}

	/** Кожне опитування сервера (раз на кілька секунд, лише коли екран на виду) */
	fun poll(state: String)
	{
		lastState = state
		// сервер дозволяє грати (бронь іде, наприклад, після обриву гри): обов'язкове вікно не тримає екран,
		// інакше до кінця броні не вийшло б підключитись знову. Покажемо його, коли сервер попросить оновитись
		val d = offerDialog
		if(state == "play" && phase == Phase.IDLE && d != null && dialog === d)
			dismissDialog()
		runDeferred()
		if(due(CHECK_EVERY_MS) || (state == "update" && phase == Phase.IDLE && dialog == null && due(CHECK_UPDATE_STATE_MS)))
			check()
	}

	/** Кнопка «Оновити» на картці «Потрібна нова версія» і в рядку «Доступна версія» */
	fun updateNow(fallback: () -> Unit)
	{
		if(phase != Phase.IDLE)
		{
			// уже качаємо або чекаємо дозволу: просто показати вікно з ходом, якщо його закрили
			if(phase == Phase.PERMISSION)
				offer?.let { askPermission(it) }
			return
		}
		val u = offer
		if(u != null)
		{
			start(u)
			return
		}
		check(force = true) { found ->
			if(found != null)
				start(found)
			else
				fallback()
		}
	}

	private fun runDeferred()
	{
		val d = deferred ?: return
		if(!canShow)
			return
		deferred = null
		d()
	}

	/** Показати зараз або, якщо екран не на виду (гра, бот, налаштування), — коли повернуться */
	private fun whenVisible(action: () -> Unit)
	{
		if(canShow)
			action()
		else
			deferred = action
	}

	// ── перевірка ──

	private fun check(force: Boolean = false, done: ((AnyPlayUpdate?) -> Unit)? = null)
	{
		if(checking || (!force && phase != Phase.IDLE))
			return
		checking = true
		activity.lifecycleScope.launch {
			val r = withContext(Dispatchers.IO) {
				AnyPlayCloud.request(activity, "GET", "/api/app/update?platform=android&build=${BuildConfig.ANYPLAY_BUILD}", auth = false)
			}
			checking = false
			lastTry = SystemClock.elapsedRealtime()
			lastFailed = !r.ok
			if(!r.ok)
			{
				AnyPlayDiag.w("Оновлення: перевірка не вдалась (HTTP ${r.status}), повтор за хвилину")
				done?.invoke(null)
				return@launch
			}
			lastCheck = lastTry
			val raw = r.json.optJSONObject("update")
			val u = AnyPlayUpdate.parse(raw)
			if(u != null)
				AnyPlayDiag.i("Оновлення: доступна збірка ${u.build}${if(u.mandatory) " (обов'язкова)" else ""}, у нас ${BuildConfig.ANYPLAY_BUILD}")
			else if(raw != null)
				AnyPlayDiag.w("Оновлення: сервер дав збірку ${raw.optInt("build")}, але без правильного файлу (https, sha256, size) — пропускаю")
			else
				AnyPlayDiag.i("Оновлення: нової збірки немає (у нас ${BuildConfig.ANYPLAY_BUILD})")
			val changed = offer?.build != u?.build || offer?.mandatory != u?.mandatory
			offer = u
			if(changed)
				onChanged()
			val p = prefs(activity)
			if(u == null || p.getInt(KEY_PENDING, 0) != u.build)
				p.edit().remove(KEY_PENDING).apply()
			if(done != null)
			{
				done(u)
				return@launch
			}
			if(u == null || phase != Phase.IDLE)
				return@launch
			// вікно цієї ж версії вже відкрите — не смикаємо його
			if(dialog != null && shownThisRun == u.build)
				return@launch
			// «Пізніше» натиснули недавно: лише рядок на головному екрані, без вікна
			if(snoozed(u) && prefs(activity).getInt(KEY_PENDING, 0) != u.build)
				return@launch
			whenVisible { offerAgain(u) }
		}
	}

	/** Показати пропозицію (або продовжити завантаження, на яке вже погодились) */
	private fun offerAgain(u: AnyPlayUpdate)
	{
		if(phase != Phase.IDLE || offer !== u || dialog != null)
			return
		// уже погодились раніше (програму закрили посеред завантаження) — продовжуємо без питань
		if(prefs(activity).getInt(KEY_PENDING, 0) == u.build)
			start(u)
		else if(!snoozed(u))
			showOffer(u)
	}

	private fun showOffer(u: AnyPlayUpdate)
	{
		dialog?.dismiss()
		// поки сервер дозволяє грати (бронь іде), навіть обов'язкове оновлення можна відкласти
		val blocking = u.mandatory && lastState != "play"
		var text = "Щоб встановити оновлення, ми ненадовго закриємо AnyPlay і відкриємо знову. Вхід і броні збережуться."
		if(u.notes.isNotEmpty())
			text += "\n\nЩо нового: ${u.notes}"
		if(blocking)
			text += "\n\nБез цього оновлення грати не вийде."
		val b = MaterialAlertDialogBuilder(activity)
			.setTitle("Доступна версія ${u.build}")
			.setMessage(text)
			.setCancelable(!blocking)
			.setPositiveButton("Оновити") { _, _ -> start(u) }
		if(!blocking)
		{
			b.setNegativeButton("Пізніше") { _, _ -> snooze(u) }
			b.setOnCancelListener { snooze(u) }
		}
		shownThisRun = u.build
		AnyPlayDiag.i("Оновлення: показую вікно «Доступна версія ${u.build}»")
		val d = present(b)
		offerDialog = if(blocking) d else null
	}

	/** «Пізніше»: вікно цієї версії — знову через 12 годин; рядок на головному екрані лишається */
	private fun snooze(u: AnyPlayUpdate)
	{
		prefs(activity).edit().putInt(KEY_SNOOZE_BUILD, u.build).putLong(KEY_SNOOZE_UNTIL, System.currentTimeMillis() + SNOOZE_MS).apply()
	}

	/** Показує вікно й пам'ятає його, поки його не закриють */
	private fun present(b: MaterialAlertDialogBuilder): AlertDialog
	{
		val d = AnyPlayStyle.show(b)   // вікна оновлення в стилі нового дизайну
		dialog = d
		d.setOnDismissListener {
			if(dialog === d)
			{
				dialog = null
				statusText = null
				progressBar = null
			}
			if(offerDialog === d)
				offerDialog = null
		}
		return d
	}

	// ── дозвіл на встановлення ──

	private fun installAllowed() =
		Build.VERSION.SDK_INT < Build.VERSION_CODES.O || activity.packageManager.canRequestPackageInstalls()

	private fun askPermission(u: AnyPlayUpdate)
	{
		phase = Phase.IDLE
		dismissDialog()
		val b = MaterialAlertDialogBuilder(activity)
			.setTitle("Потрібен дозвіл")
			.setMessage("Щоб AnyPlay міг сам встановити оновлення, Android має це дозволити. Зараз відкриються налаштування: увімкни «Дозволити з цього джерела» і повернись сюди кнопкою «Назад». Оновлення продовжиться само.")
			.setCancelable(false)
			.setPositiveButton("Відкрити налаштування") { _, _ -> openInstallSettings(u) }
		if(u.mandatory)
			b.setNegativeButton("Завантажити вручну") { _, _ -> manual(u) }
		else
			b.setNegativeButton("Пізніше") { _, _ -> later() }
		present(b)
	}

	private fun openInstallSettings(u: AnyPlayUpdate)
	{
		if(Build.VERSION.SDK_INT < Build.VERSION_CODES.O)
			return
		try
		{
			phase = Phase.PERMISSION
			activity.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${activity.packageName}")))
		}
		catch(e: ActivityNotFoundException)
		{
			phase = Phase.IDLE
			failed(u, Failure.INSTALL)
		}
	}

	// ── завантаження ──

	private fun start(u: AnyPlayUpdate)
	{
		prefs(activity).edit().putInt(KEY_PENDING, u.build).apply()
		offer = u
		if(!installAllowed())
		{
			askPermission(u)
			return
		}
		download(u)
	}

	private fun later()
	{
		phase = Phase.IDLE
		prefs(activity).edit().remove(KEY_PENDING).apply()
		onChanged()
	}

	private fun manual(u: AnyPlayUpdate)
	{
		later()
		try
		{
			activity.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(u.manual)))
		}
		catch(e: ActivityNotFoundException)
		{
			Toast.makeText(activity, "Не вдалося відкрити посилання. Відкрий бота @play_any_bot вручну.", Toast.LENGTH_LONG).show()
		}
	}

	private fun showProgress()
	{
		dismissDialog()
		val dp = activity.resources.displayMetrics.density
		val text = TextView(activity).apply {
			textSize = 15f
			typeface = AnyPlayStyle.body(activity)
			setTextColor(0xD9FFFFFF.toInt())
			text = "Завантаження…"
		}
		val bar = ProgressBar(activity, null, android.R.attr.progressBarStyleHorizontal).apply {
			max = 1000
			isIndeterminate = true
			progressTintList = ColorStateList.valueOf(AnyPlayStyle.INK)
			progressBackgroundTintList = ColorStateList.valueOf(0x33FFFFFF)
			indeterminateTintList = ColorStateList.valueOf(AnyPlayStyle.INK)
		}
		val box = LinearLayout(activity).apply {
			orientation = LinearLayout.VERTICAL
			setPadding((24 * dp).toInt(), (12 * dp).toInt(), (24 * dp).toInt(), 0)
			addView(text)
			addView(bar, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).also {
				it.topMargin = (14 * dp).toInt()
			})
		}
		present(MaterialAlertDialogBuilder(activity)
			.setTitle("Оновлення AnyPlay")
			.setView(box)
			.setCancelable(false)
			.setNegativeButton("Скасувати") { _, _ -> cancelDownload() })
		statusText = text
		progressBar = bar
	}

	private fun setStatus(text: String, done: Long = -1, total: Long = 0, cancellable: Boolean = true)
	{
		statusText?.text = text
		progressBar?.let {
			if(done >= 0 && total > 0)
			{
				it.isIndeterminate = false
				it.progress = (done * 1000 / total).toInt()
			}
			else
				it.isIndeterminate = true
		}
		dialog?.getButton(DialogInterface.BUTTON_NEGATIVE)?.visibility = if(cancellable) View.VISIBLE else View.GONE
	}

	private fun dismissDialog()
	{
		dialog?.dismiss()
		dialog = null
		statusText = null
		progressBar = null
	}

	private fun dropConnection()
	{
		val c = conn ?: return
		conn = null
		// закриваємо з’єднання не в головному потоці, щоб завантаження зупинилось одразу
		Thread { try { c.disconnect() } catch(e: Exception) {} }.start()
	}

	private fun cancelDownload()
	{
		job?.cancel()
		job = null
		deferred = null
		dropConnection()
		dismissDialog()
		later()
	}

	private fun download(u: AnyPlayUpdate)
	{
		phase = Phase.DOWNLOADING
		onChanged()
		showProgress()
		job?.cancel()
		job = activity.lifecycleScope.launch {
			val file = try
			{
				fetch(u)
			}
			catch(e: CancellationException)
			{
				throw e
			}
			catch(e: Exception)
			{
				ensureActive()   // «Скасувати» обриває з’єднання — це не помилка
				missingBytes = (e as? NoSpaceException)?.missing ?: 0L
				failed(u, when(e)
				{
					is CorruptUpdateException -> Failure.CORRUPT
					is NoSpaceException -> Failure.SPACE
					else -> Failure.NETWORK
				})
				return@launch
			}
			setStatus("Перевіряємо файл…")
			val good = withContext(Dispatchers.IO) { file.length() == u.size && sha256(file) == u.sha256 }
			if(!good)
			{
				file.delete()
				failed(u, Failure.CORRUPT)
				return@launch
			}
			job = null
			install(u, file)
		}
	}

	private fun speedText(done: Long, total: Long, speed: Double): String
	{
		var t = "Завантаження… ${Math.round(done / MB)} з ${Math.round(total / MB)} МБ"
		if(speed > 0)
			t += ", " + String.format(Locale("uk"), "%.1f", speed / MB) + " МБ/с"
		return t
	}

	/** Завантажує APK у cacheDir/updates/AnyPlay-<build>.apk; продовжує з місця обриву (Range) */
	private suspend fun fetch(u: AnyPlayUpdate): File = withContext(Dispatchers.IO) {
		val dir = updatesDir(activity)
		dir.mkdirs()
		val file = File(dir, "AnyPlay-${u.build}.apk")
		dir.listFiles()?.forEach { if(it.name != file.name) it.delete() }
		if(file.length() > u.size)
			file.delete()
		// місце: решта файлу + ще одна його копія для встановлення (система копіює APK до себе) + запас
		val need = (u.size - file.length()) + u.size + 50L * 1024 * 1024
		val free = dir.usableSpace
		if(free in 1 until need)
			throw NoSpaceException(need - free)
		var url = URL(u.url)
		var hops = 0
		var restarted = false
		while(file.length() < u.size)
		{
			ensureActive()
			val have = file.length()
			val c = url.openConnection() as HttpURLConnection
			conn = c
			try
			{
				// переспрямування GitHub (на release-assets.githubusercontent.com) обробляємо самі, щоб не загубити Range
				c.instanceFollowRedirects = false
				c.connectTimeout = 15000
				c.readTimeout = 30000
				c.setRequestProperty("User-Agent", "AnyPlay-Android/${BuildConfig.ANYPLAY_BUILD}")
				c.setRequestProperty("Accept", "application/octet-stream")
				if(have > 0)
					c.setRequestProperty("Range", "bytes=$have-")
				val code = c.responseCode
				if(code in 300..399)
				{
					val location = c.getHeaderField("Location")
					if(location.isNullOrEmpty() || ++hops > 8)
						throw IOException("redirect")
					url = URL(url, location)
					if(url.protocol != "https")
						throw IOException("not https")
					continue
				}
				if(code == 416 && !restarted)
				{
					// шматок, що лишився з минулого разу, не підходить — починаємо спочатку
					file.delete()
					restarted = true
					continue
				}
				val append = code == 206 && have > 0 &&
					(c.getHeaderField("Content-Range") ?: "").startsWith("bytes $have-")
				if(code != 200 && !append)
					throw IOException("HTTP $code")
				if(code == 200 && c.contentLengthLong > 0 && c.contentLengthLong != u.size)
					throw CorruptUpdateException()
				var done = if(append) have else 0L
				var lastUi = 0L
				var speedFrom = SystemClock.elapsedRealtime()
				var speedBytes = done
				var speed = 0.0
				FileOutputStream(file, append).use { out ->
					c.inputStream.use { input ->
						val buf = ByteArray(64 * 1024)
						while(true)
						{
							ensureActive()
							val n = input.read(buf)
							if(n < 0)
								break
							if(done + n > u.size)
								throw CorruptUpdateException()
							out.write(buf, 0, n)
							done += n
							val now = SystemClock.elapsedRealtime()
							if(now - speedFrom >= 1000)
							{
								val s = (done - speedBytes) * 1000.0 / (now - speedFrom)
								speed = if(speed > 0) speed * 0.6 + s * 0.4 else s
								speedFrom = now
								speedBytes = done
							}
							if(now - lastUi >= 250 || done == u.size)
							{
								lastUi = now
								val text = speedText(done, u.size, speed)
								val shown = done
								activity.runOnUiThread { if(phase == Phase.DOWNLOADING) setStatus(text, shown, u.size) }
							}
						}
					}
				}
				if(file.length() < u.size)
					throw IOException("short")
			}
			finally
			{
				if(conn === c)
					conn = null
				c.disconnect()
			}
		}
		if(file.length() != u.size)
			throw CorruptUpdateException()
		file
	}

	private fun sha256(file: File): String
	{
		val md = MessageDigest.getInstance("SHA-256")
		file.inputStream().use { input ->
			val buf = ByteArray(256 * 1024)
			while(true)
			{
				val n = input.read(buf)
				if(n < 0)
					break
				md.update(buf, 0, n)
			}
		}
		return md.digest().joinToString("") { "%02x".format(it) }
	}

	/** Прибирає завантажені раніше файли вже встановлених збірок */
	private fun cleanup()
	{
		val p = prefs(activity)
		p.edit().remove(KEY_RELAUNCH).apply()
		if(p.getInt(KEY_PENDING, 0) <= BuildConfig.ANYPLAY_BUILD)
			p.edit().remove(KEY_PENDING).apply()
		val dir = updatesDir(activity)
		Thread {
			dir.listFiles()?.forEach {
				val build = Regex("^AnyPlay-(\\d+)\\.apk$").find(it.name)?.groupValues?.get(1)?.toIntOrNull() ?: 0
				if(build <= BuildConfig.ANYPLAY_BUILD)
					it.delete()
			}
		}.start()
	}

	// ── встановлення ──

	private fun install(u: AnyPlayUpdate, file: File)
	{
		if(!installAllowed())
		{
			askPermission(u)
			return
		}
		if(!canShow)
		{
			// гравець пішов з головного екрана — встановимо, коли повернеться
			deferred = { if(phase == Phase.DOWNLOADING) install(u, file) }
			return
		}
		phase = Phase.INSTALLING
		confirmLaunched = false
		if(dialog == null)
			showProgress()
		setStatus("Встановлюємо, AnyPlay відкриється сам", cancellable = false)
		prefs(activity).edit().putInt(KEY_RELAUNCH, u.build).apply()
		activity.lifecycleScope.launch {
			val ok = withContext(Dispatchers.IO) {
				try
				{
					commit(file)
					true
				}
				catch(e: Exception)
				{
					false
				}
			}
			if(!ok)
			{
				prefs(activity).edit().remove(KEY_RELAUNCH).apply()
				failed(u, Failure.INSTALL)
			}
		}
	}

	private fun commit(file: File)
	{
		val installer = activity.packageManager.packageInstaller
		// незавершені спроби з минулого разу більше не потрібні
		for(s in installer.mySessions)
			try { installer.abandonSession(s.sessionId) } catch(e: Exception) {}
		val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
		params.setAppPackageName(activity.packageName)
		params.setSize(file.length())
		if(Build.VERSION.SDK_INT >= Build.VERSION_CODES.S)
			params.setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
		val id = installer.createSession(params)
		try
		{
			installer.openSession(id).use { session ->
				session.openWrite("anyplay.apk", 0, file.length()).use { out ->
					file.inputStream().use { it.copyTo(out, 256 * 1024) }
					session.fsync(out)
				}
				// система дописує в Intent результат, тому на Android 12+ потрібен FLAG_MUTABLE (Intent явний — це дозволено)
				val flags = PendingIntent.FLAG_UPDATE_CURRENT or
					(if(Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0)
				val intent = Intent(activity, AnyPlayInstallReceiver::class.java)
					.setAction(ACTION_INSTALL_STATUS)
					.setPackage(activity.packageName)
				val pending = PendingIntent.getBroadcast(activity, id, intent, flags)
				session.commit(pending.intentSender)
			}
		}
		catch(e: Exception)
		{
			try { installer.abandonSession(id) } catch(x: Exception) {}
			throw e
		}
	}

	/** Система просить підтвердження встановлення (перше оновлення, Android до 12 тощо) */
	private fun confirmInstall(confirm: Intent)
	{
		whenVisible {
			confirmLaunched = true
			try
			{
				activity.startActivity(confirm)
			}
			catch(e: Exception)
			{
				confirmLaunched = false
				prefs(activity).edit().remove(KEY_RELAUNCH).apply()
				offer?.let { failed(it, Failure.INSTALL) }
			}
		}
	}

	private fun installAborted()
	{
		if(phase != Phase.INSTALLING)
			return
		confirmLaunched = false
		prefs(activity).edit().remove(KEY_RELAUNCH).apply()
		dismissDialog()
		later()
	}

	private fun installFailed()
	{
		if(phase != Phase.INSTALLING)
			return
		confirmLaunched = false
		offer?.let { failed(it, Failure.INSTALL) }
	}

	// ── помилки ──

	private fun failed(u: AnyPlayUpdate, why: Failure)
	{
		phase = Phase.IDLE
		job = null
		AnyPlayDiag.w("Оновлення до ${u.build} не вдалось: $why")
		onChanged()
		dismissDialog()
		whenVisible {
			if(phase != Phase.IDLE || dialog != null)
				return@whenVisible
			val text = when(why)
			{
				Failure.NETWORK -> "Не вдалося завантажити оновлення. Перевір інтернет."
				Failure.CORRUPT -> "Файл пошкоджений, спробуй ще раз."
				Failure.INSTALL -> "Не вдалося встановити оновлення. Спробуй ще раз або завантаж нову версію вручну."
				Failure.SPACE -> "На телефоні не вистачає місця для оновлення. Звільни ще приблизно ${Math.max(1L, Math.round(missingBytes / MB))} МБ і спробуй ще раз."
			}
			val b = MaterialAlertDialogBuilder(activity)
				.setTitle("Оновлення AnyPlay")
				.setMessage(text)
				.setCancelable(!u.mandatory)
				.setPositiveButton("Спробувати ще раз") { _, _ -> start(u) }
				.setNeutralButton("Завантажити вручну") { _, _ -> manual(u) }
			if(!u.mandatory)
				b.setNegativeButton("Пізніше") { _, _ -> later() }
			present(b)
		}
	}
}

/** Результат встановлення від PackageInstaller і «програму оновлено» від системи */
class AnyPlayInstallReceiver: BroadcastReceiver()
{
	override fun onReceive(context: Context, intent: Intent)
	{
		when(intent.action)
		{
			AnyPlayUpdater.ACTION_INSTALL_STATUS -> AnyPlayUpdater.onInstallStatus(context, intent)
			Intent.ACTION_MY_PACKAGE_REPLACED -> AnyPlayUpdater.relaunch(context)
		}
	}
}
