// AnyPlay: сторінка програми (assets/anyplay/app.html) — головний екран з вкладками, бронювання, баланс, продовження,
// «Мій PSN», якість, довідка й меню під час гри. Сторінка ходить на сервер через цю програму (міст AnyPlay);
// тут же вікно входу в PSN на сайті Sony.
package com.metallic.chiaki.anyplay

import android.annotation.SuppressLint
import android.app.Activity
import android.app.Dialog
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.Drawable
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.webkit.CookieManager
import android.webkit.JavascriptInterface
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import android.widget.Toast
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import com.metallic.chiaki.R
import com.metallic.chiaki.touchcontrols.ButtonHaptics
import org.json.JSONObject
import java.util.concurrent.Executors

private val anyplayIo = Executors.newCachedThreadPool()

const val ANYPLAY_PAGE = "file:///android_asset/anyplay/app.html"

/** Чи підключено справжній геймпад (Bluetooth чи кабель) */
fun hasGamepad(): Boolean = android.view.InputDevice.getDeviceIds().any { id ->
	val d = android.view.InputDevice.getDevice(id)
	d != null && !d.isVirtual && (d.sources and android.view.InputDevice.SOURCE_GAMEPAD == android.view.InputDevice.SOURCE_GAMEPAD ||
		d.sources and android.view.InputDevice.SOURCE_JOYSTICK == android.view.InputDevice.SOURCE_JOYSTICK)
}

/** Що сторінка програми може питати в сервера через міст (з токеном пристрою) */
private val ANYPLAY_REQ_PATHS = arrayOf("/api/app/", "/api/miniapp/friends", "/api/live/handoff")

private fun openExternal(context: Context, url: String)
{
	try
	{
		context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
	}
	catch(e: ActivityNotFoundException)
	{
		Toast.makeText(context, "Не вдалося відкрити посилання", Toast.LENGTH_LONG).show()
	}
}

/** Хто показує сторінку (головний екран чи гра): дає їй дані й виконує її команди */
interface AnyPlayHost
{
	/** JSON зі станом для сторінки. Викликається не з головного потоку. */
	fun info(): String

	/** Команда сторінки (вхід, гра, вихід тощо). Уже в головному потоці. */
	fun action(name: String, arg: String)

	/** На сторінці змінили якість картинки. Уже в головному потоці. */
	fun qualityChanged() {}

	/** На сторінці змінили кольори картинки (Зображення). Уже в головному потоці. */
	fun pictureChanged() {}
}

/** WebView для сторінки AnyPlay; будь-яке стороннє посилання відкривається в браузері */
@SuppressLint("SetJavaScriptEnabled")
fun anyplayWebView(activity: Activity, transparent: Boolean): WebView
{
	val web = WebView(activity)
	web.setBackgroundColor(if(transparent) Color.TRANSPARENT else AnyPlayStyle.BG1)
	web.settings.javaScriptEnabled = true
	web.settings.domStorageEnabled = true
	// сторінці потрібні лише її файли з assets (вони доступні й так): жодних файлів телефона і content:// —
	// на старих Android без оновленого WebView доступ до файлів інакше увімкнений
	web.settings.allowFileAccess = false
	web.settings.allowContentAccess = false
	web.overScrollMode = View.OVER_SCROLL_NEVER
	web.isVerticalScrollBarEnabled = false
	web.isHorizontalScrollBarEnabled = false
	web.webViewClient = object: WebViewClient()
	{
		// сторінка лише наша, з програми: будь-яке інше посилання відкриваємо в браузері
		override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean
		{
			val url = request.url.toString()
			if(url.startsWith("file:///android_asset/anyplay/"))
				return false
			openExternal(activity, url)
			return true
		}
	}
	return web
}

/** Обгортка для сторінки: відступи від системних панелей, вирізу екрана й клавіатури; під панелями видно тло */
fun anyplayFrame(activity: Activity, web: WebView, background: Drawable?): FrameLayout
{
	val frame = FrameLayout(activity)
	frame.background = background
	frame.addView(web, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
	ViewCompat.setOnApplyWindowInsetsListener(frame) { v, insets ->
		val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout())
		val ime = insets.getInsets(WindowInsetsCompat.Type.ime())
		v.setPadding(bars.left, bars.top, bars.right, maxOf(bars.bottom, ime.bottom))
		WindowInsetsCompat.CONSUMED
	}
	return frame
}

/**
 * Міст сторінка ↔ програма (у сторінці це window.AnyPlay).
 * alive — чи сторінка ще на екрані; host — головний екран або гра (без нього сторінка лише бронює й показує довідку).
 */
class AnyPlayBridge(private val activity: Activity, private val web: WebView, private val alive: () -> Boolean,
	private val host: AnyPlayHost?, private val onClose: () -> Unit)
{
	private val haptics = ButtonHaptics(activity)

	/**
	 * Запити сторінки до сервера з токеном пристрою. Дозволені лише API програми, друзі й подарунки (етап 7)
	 * і «Передати повністю» — нічого іншого сторінка від імені пристрою не просить.
	 */
	@JavascriptInterface
	fun req(id: Int, method: String, path: String, body: String)
	{
		if(!ANYPLAY_REQ_PATHS.any { path.startsWith(it) } || path.contains(".."))
			return
		anyplayIo.execute {
			val json = if(body.isEmpty()) null else try { JSONObject(body) } catch(e: Exception) { null }
			val r = AnyPlayCloud.request(activity, if(method == "POST") "POST" else "GET", path, json)
			val text = JSONObject.quote(r.json.toString())
			activity.runOnUiThread {
				if(alive())
					web.evaluateJavascript("window.__anyplayResp($id, ${r.status}, $text)", null)
			}
		}
	}

	@JavascriptInterface
	fun copy(text: String)
	{
		val cm = activity.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
		cm.setPrimaryClip(ClipData.newPlainText("AnyPlay", text))
	}

	@JavascriptInterface
	fun open(url: String)
	{
		if(url.startsWith("https://"))
			activity.runOnUiThread { openExternal(activity, url) }
	}

	@JavascriptInterface
	fun close() = activity.runOnUiThread { if(alive()) onClose() }

	/** Поділитися текстом (запрошення в друзі): системне вікно «Надіслати» — Telegram, Viber тощо */
	@JavascriptInterface
	fun share(text: String) = activity.runOnUiThread {
		if(!alive())
			return@runOnUiThread
		try
		{
			activity.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, text), "Надіслати запрошення"))
		}
		catch(e: ActivityNotFoundException)
		{
			copy(text)
			Toast.makeText(activity, "Посилання скопійовано", Toast.LENGTH_LONG).show()
		}
	}

	/** «Дивитись»: трансляція друга (код кімнати) на сторінці сервера watch.html — відео, голос, чат, керування помічника */
	@JavascriptInterface
	fun watch(code: String) = activity.runOnUiThread {
		if(alive() && Regex("[A-Za-z0-9]{1,12}").matches(code))
			// без геймпада помічнику потрібні екранні кнопки (на планшеті сторінка сама їх не показує)
			AnyPlayPageActivity.open(activity, "/app/watch.html?r=" + code.uppercase() + if(hasGamepad()) "" else "&pad=1",
				AnyPlayPageActivity.KIND_WATCH)
	}

	/** Сторінка сервера в програмі: друзі й подарунки (book.html, лише вона) */
	@JavascriptInterface
	fun page(path: String) = activity.runOnUiThread {
		if(alive() && path.startsWith("/app/book.html") && !path.contains(".."))
			AnyPlayPageActivity.open(activity, path)
	}

	@JavascriptInterface
	fun haptic() = activity.runOnUiThread { haptics.trigger() }

	@JavascriptInterface
	fun psnLogin(create: Boolean) = activity.runOnUiThread {
		PsnLoginDialog(activity, create) { error ->
			if(error != null)
				Toast.makeText(activity, error, Toast.LENGTH_LONG).show()
			else
				Toast.makeText(activity, "Вхід у PSN виконано. Адміністратор додасть твій профіль на приставку: це кілька хвилин.", Toast.LENGTH_LONG).show()
			if(alive())
				web.evaluateJavascript("window.__anyplayEvent && window.__anyplayEvent('psn')", null)
		}.show()
	}

	/** Стан для сторінки від головного екрана чи гри */
	@JavascriptInterface
	fun info(): String = host?.info() ?: "{}"

	@JavascriptInterface
	fun action(name: String, arg: String) = activity.runOnUiThread { if(alive()) host?.action(name, arg) }

	/** Якість картинки: {auto, level, name, levels} */
	@JavascriptInterface
	fun quality(): String = AnyPlayQuality.json(activity).toString()

	/** Кольори картинки: {brightness, contrast, saturation, warmth}, кожне -50..50 */
	@JavascriptInterface
	fun picture(): String = AnyPlayPicture.json(activity).toString()

	/** Змінити кольори (JSON з тими самими ключами; порожній об'єкт — без змін). Повертає нові значення. */
	@JavascriptInterface
	fun setPicture(json: String): String
	{
		val o = try { JSONObject(json) } catch(e: Exception) { JSONObject() }
		AnyPlayPicture.set(activity, o)
		activity.runOnUiThread { if(alive()) host?.pictureChanged() }
		return picture()
	}

	/** Кольори до типових (усе на нулі) */
	@JavascriptInterface
	fun resetPicture(): String
	{
		AnyPlayPicture.reset(activity)
		activity.runOnUiThread { if(alive()) host?.pictureChanged() }
		return picture()
	}

	/** choice: -1 — «Авто», 0..2 — сталий рівень. Повертає нову якість. */
	@JavascriptInterface
	fun setQuality(choice: Int): String
	{
		if(AnyPlayQuality.select(activity, choice))
			activity.runOnUiThread { if(alive()) host?.qualityChanged() }
		return quality()
	}
}

/**
 * Повноекранне вікно зі сторінкою AnyPlay. page: book | mine | extend | psn | help | quality | menu | menu:extend.
 * overGame — меню під час гри: напівпрозоре (видно гру), системні панелі сховані.
 */
class AnyPlayWebDialog(private val activity: Activity, private val page: String, private val host: AnyPlayHost? = null,
	private val overGame: Boolean = false, private val onClosed: () -> Unit = {}):
	Dialog(activity, R.style.AnyPlayTheme)
{
	private lateinit var web: WebView

	override fun onCreate(savedInstanceState: Bundle?)
	{
		super.onCreate(savedInstanceState)
		web = anyplayWebView(activity, overGame)
		web.addJavascriptInterface(AnyPlayBridge(activity, web, { isShowing }, host) { dismiss() }, "AnyPlay")
		setContentView(anyplayFrame(activity, web, if(overGame) null else AnyPlayStyle.background()),
			ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
		window?.let { w ->
			w.setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
			WindowCompat.setDecorFitsSystemWindows(w, false)
			// без цього Android 7–10 не повідомляє висоту клавіатури, і вона закриває поле вводу (оплата)
			@Suppress("DEPRECATION")
			w.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)
			if(overGame)
			{
				w.setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
				w.setFormat(PixelFormat.TRANSLUCENT)
				w.clearFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND)
				if(Build.VERSION.SDK_INT >= Build.VERSION_CODES.P)
					w.attributes = w.attributes.also { it.layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES }
				WindowCompat.getInsetsController(w, w.decorView).let {
					it.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
					it.hide(WindowInsetsCompat.Type.systemBars())
				}
			}
			else
			{
				w.statusBarColor = Color.TRANSPARENT
				w.navigationBarColor = Color.TRANSPARENT
			}
		}
		web.loadUrl("$ANYPLAY_PAGE#$page")
		setOnDismissListener {
			web.removeJavascriptInterface("AnyPlay")
			web.destroy()
			onClosed()
		}
	}

	override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean
	{
		if(keyCode == KeyEvent.KEYCODE_BACK)
		{
			web.evaluateJavascript("window.__anyplayBack ? window.__anyplayBack() : false") {
				if(it != "true")
					dismiss()
			}
			return true
		}
		return super.onKeyDown(keyCode, event)
	}
}

/** Вхід у PSN на сторінці Sony. onDone(null) — вдалося; onDone(текст) — помилка; закрили самі — onDone не кличемо з помилкою */
class PsnLoginDialog(private val activity: Activity, private val create: Boolean, private val onDone: (String?) -> Unit):
	Dialog(activity, R.style.AnyPlayTheme)
{
	private lateinit var web: WebView
	private lateinit var progress: View
	private var finished = false

	@SuppressLint("SetJavaScriptEnabled")
	override fun onCreate(savedInstanceState: Bundle?)
	{
		super.onCreate(savedInstanceState)
		val root = LinearLayout(activity).apply { orientation = LinearLayout.VERTICAL; setBackgroundColor(AnyPlayStyle.BG1) }
		val density = activity.resources.displayMetrics.density
		val bar = LinearLayout(activity).apply {
			orientation = LinearLayout.HORIZONTAL
			gravity = Gravity.CENTER_VERTICAL
			setPadding((14 * density).toInt(), (10 * density).toInt(), (14 * density).toInt(), (10 * density).toInt())
		}
		bar.addView(TextView(activity).apply {
			text = "✕"
			textSize = 20f
			setTextColor(AnyPlayStyle.INK)
			setPadding((8 * density).toInt(), (4 * density).toInt(), (16 * density).toInt(), (4 * density).toInt())
			setOnClickListener { dismiss() }
		})
		bar.addView(TextView(activity).apply {
			text = if(create) "Реєстрація й вхід у PSN" else "Вхід у PSN: пароль бачить лише Sony"
			textSize = 15f
			typeface = AnyPlayStyle.display(activity)
			isAllCaps = true
			letterSpacing = 0.08f
			setTextColor(AnyPlayStyle.INK)
		})
		root.addView(bar)
		val frame = FrameLayout(activity)
		web = WebView(activity)
		web.settings.javaScriptEnabled = true
		web.settings.domStorageEnabled = true
		web.settings.allowFileAccess = false   // сторінка Sony: файли телефона їй ні до чого
		web.settings.allowContentAccess = false
		// звичайний мобільний браузер: Sony інколи не пускає «вбудовані» вікна
		web.settings.userAgentString = web.settings.userAgentString.replace("; wv", "")
		// попередній вхід не підставляємо: клієнт має сам обрати акаунт
		CookieManager.getInstance().removeAllCookies(null)
		CookieManager.getInstance().setAcceptThirdPartyCookies(web, true)
		web.webViewClient = object: WebViewClient()
		{
			override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean = handle(request.url)
			override fun onPageStarted(view: WebView, url: String, favicon: android.graphics.Bitmap?)
			{
				handle(Uri.parse(url))
			}
		}
		frame.addView(web, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
		progress = LinearLayout(activity).apply {
			orientation = LinearLayout.VERTICAL
			gravity = Gravity.CENTER
			background = AnyPlayStyle.background()
			visibility = View.GONE
			addView(ProgressBar(activity))
			addView(TextView(activity).apply {
				text = "Перевіряємо вхід у Sony…"
				textSize = 16f
				typeface = AnyPlayStyle.body(activity)
				setTextColor(AnyPlayStyle.INK)
				setPadding(0, (16 * density).toInt(), 0, 0)
			})
		}
		frame.addView(progress, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
		root.addView(frame, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
		setContentView(root)
		window?.let { w ->
			w.setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
			// відступи від системних панелей рахуємо самі (на Android 15 вікно все одно на весь екран)
			WindowCompat.setDecorFitsSystemWindows(w, false)
			// без цього Android 7–10 не повідомляє висоту клавіатури, і вона закриває поля входу Sony
			@Suppress("DEPRECATION")
			w.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)
			w.statusBarColor = Color.TRANSPARENT
			w.navigationBarColor = Color.TRANSPARENT
		}
		ViewCompat.setOnApplyWindowInsetsListener(root) { v, insets ->
			val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout())
			val ime = insets.getInsets(WindowInsetsCompat.Type.ime())
			v.setPadding(bars.left, bars.top, bars.right, maxOf(bars.bottom, ime.bottom))
			WindowInsetsCompat.CONSUMED
		}
		web.loadUrl(AnyPlayPsn.pageUrl(create))
		setOnDismissListener { web.destroy() }
	}

	/** Sony після входу веде на сторінку «redirect» з кодом — забираємо його й далі все робимо самі */
	private fun handle(uri: Uri): Boolean
	{
		if(!uri.toString().startsWith(AnyPlayPsn.REDIRECT_PAGE))
			return false
		if(finished)
			return true
		val code = uri.getQueryParameter("code")
		if(code.isNullOrEmpty())
		{
			finished = true
			dismiss()
			onDone("Sony не завершила вхід. Спробуй ще раз.")
			return true
		}
		finished = true
		progress.visibility = View.VISIBLE
		web.stopLoading()
		anyplayIo.execute {
			val error = AnyPlayPsn.finishLogin(activity, code)
			activity.runOnUiThread {
				if(isShowing)
					dismiss()
				onDone(error)
			}
		}
		return true
	}

	override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean
	{
		if(keyCode == KeyEvent.KEYCODE_BACK && !finished && web.canGoBack())
		{
			web.goBack()
			return true
		}
		return super.onKeyDown(keyCode, event)
	}
}
