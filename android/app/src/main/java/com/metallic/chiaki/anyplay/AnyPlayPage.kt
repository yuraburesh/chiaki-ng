// AnyPlay: сторінки сервера всередині програми (етап 7) — «Дивитись» (webapp/watch.html: відео друга, голос, чат,
// керування для помічника) і «Друзі й подарунки» (webapp/book.html). Ті самі сторінки працюють у Telegram і на комп'ютері.
//
// Вхід без Telegram, як на комп'ютері (К10): сторінка нашого сервера отримує window.AnyPlayApp = {token, platform, build}.
// Скрипт додаємо в сам HTML ще до скриптів сторінки (програма сама завантажує документ сторінки), тож він є лише на адресі
// нашого сервера; на будь-якій іншій адресі його немає (інші посилання відкриваються зовні).
// Мікрофон: лише нашому серверу і лише після дозволу Android. Геймпад: стан кнопок передаємо сторінці самі
// (navigator.getGamepads повертає геймпад з програми), бо WebView на частині телефонів геймпада не бачить.
package com.metallic.chiaki.anyplay

import android.Manifest
import android.annotation.SuppressLint
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.webkit.ConsoleMessage
import android.webkit.JavascriptInterface
import android.webkit.PermissionRequest
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Toast
import androidx.activity.OnBackPressedCallback
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import com.metallic.chiaki.BuildConfig
import com.metallic.chiaki.touchcontrols.ButtonHaptics
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.net.HttpURLConnection
import java.net.URL

/** Чи адреса — сторінка нашого сервера (https, той самий хост, шлях /app/…) */
fun anyplayOwnPage(url: String): Boolean
{
	val u = try { Uri.parse(url) } catch(e: Exception) { return false }
	val own = Uri.parse(AnyPlayCloud.SERVER)
	return u.scheme == own.scheme && u.host == own.host && (u.port == own.port || u.port == -1) && (u.path ?: "").startsWith("/app/")
}

class AnyPlayPageActivity: AppCompatActivity()
{
	companion object
	{
		const val EXTRA_PATH = "anyplay_path"   // шлях на сервері, наприклад /app/watch.html?room=… або /app/book.html#friends
		const val EXTRA_KIND = "anyplay_kind"   // watch — трансляція (на весь екран, геймпад, мікрофон), page — звичайна сторінка
		const val KIND_WATCH = "watch"
		const val KIND_PAGE = "page"
		private const val TAG = "anyplay-web"
		private const val PAD_PUSH_MS = 8L
		private const val HANDOFF_CHECK_MS = 2000L

		/** Відкрити сторінку сервера. path — з / на початку (лише /app/…) */
		fun open(context: Context, path: String, kind: String = KIND_PAGE)
		{
			if(!path.startsWith("/app/"))
				return
			context.startActivity(Intent(context, AnyPlayPageActivity::class.java)
				.putExtra(EXTRA_PATH, path)
				.putExtra(EXTRA_KIND, kind))
		}

		/** Документ сторінки з нашим скриптом на самому початку (до скриптів сторінки) */
		private fun inject(html: String, script: String): String
		{
			val tag = "<script>$script</script>"
			val m = Regex("<head[^>]*>", RegexOption.IGNORE_CASE).find(html)
			return if(m != null) html.substring(0, m.range.last + 1) + tag + html.substring(m.range.last + 1)
				else tag + html
		}
	}

	private lateinit var web: WebView
	private val kind get() = intent.getStringExtra(EXTRA_KIND) ?: KIND_PAGE
	private val watch get() = kind == KIND_WATCH
	@Volatile private var pageOk = false   // зараз відкрита сторінка нашого сервера (для мосту AnyPlayAndroid)
	private var pendingMic: PermissionRequest? = null
	private val handler = Handler(Looper.getMainLooper())
	private lateinit var haptics: ButtonHaptics

	private val micPermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
		val r = pendingMic ?: return@registerForActivityResult
		pendingMic = null
		if(granted)
			r.grant(arrayOf(PermissionRequest.RESOURCE_AUDIO_CAPTURE))
		else
		{
			r.deny()
			Toast.makeText(this, "Без доступу до мікрофона тебе не чутно, але слухати й писати в чат можна. Увімкнути: Налаштування Android → Програми → AnyPlay → Дозволи.", Toast.LENGTH_LONG).show()
		}
	}

	@SuppressLint("SetJavaScriptEnabled")
	override fun onCreate(savedInstanceState: Bundle?)
	{
		super.onCreate(savedInstanceState)
		val path = intent.getStringExtra(EXTRA_PATH) ?: ""
		if(!path.startsWith("/app/") || AnyPlayCloud.token(this).isEmpty())
		{
			finish()
			return
		}
		haptics = ButtonHaptics(this)
		WindowCompat.setDecorFitsSystemWindows(window, false)
		@Suppress("DEPRECATION")
		window.statusBarColor = Color.TRANSPARENT
		@Suppress("DEPRECATION")
		window.navigationBarColor = Color.TRANSPARENT
		if(watch)
			window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)   // дивимось гру: екран не гасне
		web = anyplayWebView(this, false)
		web.settings.mediaPlaybackRequiresUserGesture = false   // відео й голоси друзів грають одразу
		web.webViewClient = client
		web.webChromeClient = chrome
		web.addJavascriptInterface(Bridge(), "AnyPlayAndroid")
		web.isFocusable = true
		web.isFocusableInTouchMode = true
		setContentView(anyplayFrame(this, web, AnyPlayStyle.background()))
		applyBars()
		onBackPressedDispatcher.addCallback(this, object: OnBackPressedCallback(true)
		{
			override fun handleOnBackPressed()
			{
				web.evaluateJavascript("window.__anyplayBack ? window.__anyplayBack() : false") {
					if(it == "true" || isFinishing)
						return@evaluateJavascript
					if(web.canGoBack())
						web.goBack()
					else
						finish()
				}
			}
		})
		web.loadUrl(AnyPlayCloud.SERVER + path)
	}

	/** Трансляція: на весь екран без системних панелей (з'являються жестом); звичайна сторінка: з панелями */
	private fun applyBars()
	{
		val c = WindowCompat.getInsetsController(window, window.decorView)
		c.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
		if(watch)
			c.hide(WindowInsetsCompat.Type.systemBars())
		else
			c.show(WindowInsetsCompat.Type.systemBars())
	}

	override fun onWindowFocusChanged(hasFocus: Boolean)
	{
		super.onWindowFocusChanged(hasFocus)
		if(hasFocus)
			applyBars()
	}

	override fun onResume()
	{
		super.onResume()
		if(::web.isInitialized)
			web.onResume()
		handler.removeCallbacks(handoffCheck)
		if(watch)
			handler.postDelayed(handoffCheck, HANDOFF_CHECK_MS)
	}

	override fun onPause()
	{
		super.onPause()
		if(::web.isInitialized)
			web.onPause()
		handler.removeCallbacks(handoffCheck)
	}

	// «Передати повністю»: друг дивиться трансляцію, а власник передає йому гру — щойно передав, закриваємо перегляд
	// і граємо самі (головний екран підключається з повторами, поки приставку відпускають)
	private var handoffToldId = 0L
	private val handoffCheck = Runnable { checkHandoff() }

	private fun checkHandoff()
	{
		val app = applicationContext
		Thread {
			val r = AnyPlayCloud.request(app, "GET", "/api/live/handoff")
			val h = if(r.ok) r.json.optJSONObject("handoff") else null
			runOnUiThread {
				if(isFinishing || isDestroyed)
					return@runOnUiThread
				if(h != null && h.optString("role") == "friend")
				{
					val owner = h.optJSONObject("owner")?.optString("name") ?: "Друг"
					if(h.optString("state") == "active")
					{
						Toast.makeText(this, "$owner передав тобі гру. Підключаюсь…", Toast.LENGTH_LONG).show()
						startActivity(Intent(this, AnyPlayActivity::class.java)
							.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
							.putExtra(AnyPlayActivity.EXTRA_ACTION, "play"))
						finish()
						return@runOnUiThread
					}
					if(h.optString("state") == "ready" && handoffToldId != h.optLong("id"))
					{
						handoffToldId = h.optLong("id")
						Toast.makeText(this, "$owner хоче передати тобі гру. Щойно він натисне «Передати», гра почнеться тут сама.", Toast.LENGTH_LONG).show()
					}
				}
				// поки запит ішов, сторінку могли згорнути (тоді перевірки знову почне onResume)
				if(lifecycle.currentState.isAtLeast(androidx.lifecycle.Lifecycle.State.RESUMED))
				{
					handler.removeCallbacks(handoffCheck)
					handler.postDelayed(handoffCheck, HANDOFF_CHECK_MS)
				}
			}
		}.apply { isDaemon = true }.start()
	}

	override fun onDestroy()
	{
		handler.removeCallbacksAndMessages(null)
		pendingMic?.deny()
		pendingMic = null
		if(::web.isInitialized)
		{
			web.removeJavascriptInterface("AnyPlayAndroid")
			web.destroy()
		}
		super.onDestroy()
	}

	/** Скрипт для сторінки нашого сервера: вхід токеном пристрою і геймпад з програми */
	private fun appScript(): String
	{
		val app = JSONObject()
			.put("token", AnyPlayCloud.token(this))
			.put("platform", "android")
			.put("build", BuildConfig.ANYPLAY_BUILD)
			.put("native", true)   // є міст window.AnyPlayAndroid (close, share, copy, open, haptic, action)
		val own = Uri.parse(AnyPlayCloud.SERVER)
		val where = JSONObject().put("host", own.host).put("protocol", own.scheme + ":")
		return "(function(){var w=$where;if(location.protocol!==w.protocol||location.hostname!==w.host)return;" +
			"try{Object.defineProperty(window,'AnyPlayApp',{value:Object.freeze($app),writable:false,configurable:false});}catch(e){}" +
			// геймпад з програми: navigator.getGamepads() віддає його, щойно програма передала перший стан
			"var pad=null,orig=navigator.getGamepads?navigator.getGamepads.bind(navigator):null;" +
			"window.__anyplayNativePad=function(b,a){var first=!pad;pad={id:'AnyPlay Android (STANDARD GAMEPAD)',index:0,connected:true,mapping:'standard'," +
			"timestamp:performance.now(),axes:a,buttons:b.map(function(v){return{pressed:v>0.5,touched:v>0,value:v};})};" +
			"if(first){try{var e=new Event('gamepadconnected');e.gamepad=pad;window.dispatchEvent(e);}catch(x){}}};" +
			"try{Object.defineProperty(navigator,'getGamepads',{configurable:true,value:function(){if(pad)return[pad,null,null,null];return orig?orig():[];}});}catch(x){}" +
			"})();"
	}

	private val client = object: WebViewClient()
	{
		override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean
		{
			val url = request.url.toString()
			if(anyplayOwnPage(url))
				return false
			openExternal(url)
			return true
		}

		override fun onPageStarted(view: WebView, url: String, favicon: android.graphics.Bitmap?)
		{
			pageOk = anyplayOwnPage(url)
		}

		/** Документ нашої сторінки завантажуємо самі, щоб першим рядком додати window.AnyPlayApp */
		override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse?
		{
			val url = request.url.toString()
			if(!request.isForMainFrame || request.method != "GET" || !anyplayOwnPage(url))
				return null
			val path = request.url.path ?: ""
			if(!path.endsWith(".html"))
				return null
			var conn: HttpURLConnection? = null
			try
			{
				conn = URL(url).openConnection() as HttpURLConnection
				conn.connectTimeout = 15000
				conn.readTimeout = 15000
				conn.setRequestProperty("X-AnyPlay-Build", AnyPlayCloud.BUILD.toString())
				conn.setRequestProperty("X-AnyPlay-Platform", "android")
				request.requestHeaders["Accept-Language"]?.let { conn.setRequestProperty("Accept-Language", it) }
				val status = conn.responseCode
				if(status !in 200..299)
					return errorPage("Сторінка зараз недоступна (помилка $status). Спробуй ще раз за хвилину.")
				val html = conn.inputStream.bufferedReader(Charsets.UTF_8).use { it.readText() }
				val body = inject(html, appScript()).toByteArray(Charsets.UTF_8)
				return WebResourceResponse("text/html", "utf-8", 200, "OK",
					mapOf("Cache-Control" to "no-store"), ByteArrayInputStream(body))
			}
			catch(e: Exception)
			{
				Log.w(TAG, "page load failed: ${e.javaClass.simpleName}")
				return errorPage(if(AnyPlayCloud.online(this@AnyPlayPageActivity)) "Немає зв'язку з сервером AnyPlay. Спробуй ще раз за хвилину."
					else "Немає інтернету на телефоні. Увімкни Wi-Fi або мобільний інтернет і спробуй ще раз.")
			}
			finally
			{
				conn?.disconnect()
			}
		}
	}

	/** Сторінка помилки в стилі AnyPlay (з кнопкою «Спробувати ще раз») */
	private fun errorPage(text: String): WebResourceResponse
	{
		val html = "<!doctype html><html lang=\"uk\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">" +
			"<style>body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;background:linear-gradient(160deg,#2b2740,#4a3558 55%,#7a4a63);" +
			"color:#f5f3f7;font:16px/1.5 sans-serif;text-align:center;padding:24px;box-sizing:border-box}" +
			"button{font:600 15px sans-serif;letter-spacing:.08em;text-transform:uppercase;border:0;border-radius:2px;padding:12px 18px;margin:6px;background:#f5f3f7;color:#221d2e}" +
			"button.g{background:transparent;color:#f5f3f7;border:1px solid rgba(255,255,255,.25)}</style></head><body><div><p>" +
			text.replace("&", "&amp;").replace("<", "&lt;") +
			"</p><button onclick=\"location.reload()\">Спробувати ще раз</button><button class=\"g\" onclick=\"window.AnyPlayAndroid&&AnyPlayAndroid.close()\">Закрити</button></div></body></html>"
		return WebResourceResponse("text/html", "utf-8", 200, "OK", mapOf("Cache-Control" to "no-store"),
			ByteArrayInputStream(html.toByteArray(Charsets.UTF_8)))
	}

	private val chrome = object: WebChromeClient()
	{
		/** Мікрофон для голосового чату: лише сторінці нашого сервера і лише з дозволу Android */
		override fun onPermissionRequest(request: PermissionRequest)
		{
			val ownOrigin = anyplayOwnPage(request.origin.toString().trimEnd('/') + "/app/")
			if(!ownOrigin || !request.resources.contains(PermissionRequest.RESOURCE_AUDIO_CAPTURE))
			{
				request.deny()
				return
			}
			if(ContextCompat.checkSelfPermission(this@AnyPlayPageActivity, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED)
				request.grant(arrayOf(PermissionRequest.RESOURCE_AUDIO_CAPTURE))
			else
			{
				pendingMic?.deny()
				pendingMic = request
				micPermission.launch(Manifest.permission.RECORD_AUDIO)
			}
		}

		override fun onPermissionRequestCanceled(request: PermissionRequest)
		{
			if(pendingMic === request)
				pendingMic = null
		}

		override fun onConsoleMessage(message: ConsoleMessage): Boolean
		{
			if(message.messageLevel() == ConsoleMessage.MessageLevel.ERROR)
				Log.w(TAG, "${message.message()} (${message.sourceId().substringAfterLast('/')}:${message.lineNumber()})")
			return true
		}
	}

	private fun openExternal(url: String)
	{
		try
		{
			startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
		}
		catch(e: ActivityNotFoundException)
		{
			Toast.makeText(this, if(url.startsWith("tg:") || url.contains("t.me/")) "Не вдалося відкрити Telegram." else "Не вдалося відкрити посилання", Toast.LENGTH_LONG).show()
		}
	}

	/** Міст для сторінки сервера (window.AnyPlayAndroid); діє лише на сторінках нашого сервера */
	private inner class Bridge
	{
		@JavascriptInterface
		fun close() = runOnUiThread { if(!isFinishing) finish() }

		@JavascriptInterface
		fun haptic() = runOnUiThread { if(pageOk) haptics.trigger() }

		@JavascriptInterface
		fun copy(text: String)
		{
			if(!pageOk)
				return
			val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
			cm.setPrimaryClip(ClipData.newPlainText("AnyPlay", text))
		}

		/** Поділитися запрошенням (Telegram, Viber тощо) */
		@JavascriptInterface
		fun share(text: String) = runOnUiThread {
			if(!pageOk || isFinishing)
				return@runOnUiThread
			try
			{
				startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, text), "Надіслати запрошення"))
			}
			catch(e: ActivityNotFoundException) { }
		}

		@JavascriptInterface
		fun open(url: String) = runOnUiThread {
			if(!pageOk || isFinishing)
				return@runOnUiThread
			if(anyplayOwnPage(url))
				web.loadUrl(url)
			else if(url.startsWith("https://") || url.startsWith("tg://"))
				openExternal(url)
		}

		/**
		 * Команди програмі: play — закрити сторінку й грати (друг передав гру повністю, бронь власника);
		 * watch — відкрити трансляцію (arg — шлях /app/watch.html?…); home — повернутись на головний екран.
		 */
		@JavascriptInterface
		fun action(name: String, arg: String) = runOnUiThread {
			if(!pageOk || isFinishing)
				return@runOnUiThread
			when(name)
			{
				"play", "home" ->
				{
					startActivity(Intent(this@AnyPlayPageActivity, AnyPlayActivity::class.java)
						.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
						.putExtra(AnyPlayActivity.EXTRA_ACTION, name))
					finish()
				}
				"watch" -> if(arg.startsWith("/app/watch.html"))
				{
					web.loadUrl(AnyPlayCloud.SERVER + arg)
				}
			}
		}
	}

	// ── геймпад: стан кнопок і стіків у розкладці standard (W3C Gamepad), сторінка читає navigator.getGamepads() ──
	private val padButtons = FloatArray(17)
	private val padAxes = FloatArray(4)
	private var padPushAt = 0L
	private var padPushQueued = false
	private val padPush = Runnable { pushPad() }

	private fun pushPad()
	{
		padPushQueued = false
		padPushAt = SystemClock.uptimeMillis()
		val b = padButtons.joinToString(",") { if(it == 0f) "0" else String.format(java.util.Locale.US, "%.3f", it) }
		val a = padAxes.joinToString(",") { String.format(java.util.Locale.US, "%.3f", it) }
		web.evaluateJavascript("window.__anyplayNativePad&&window.__anyplayNativePad([$b],[$a])", null)
	}

	private fun schedulePad()
	{
		if(padPushQueued)
			return
		padPushQueued = true
		val wait = PAD_PUSH_MS - (SystemClock.uptimeMillis() - padPushAt)
		if(wait <= 0)
			handler.post(padPush)
		else
			handler.postDelayed(padPush, wait)
	}

	private fun isPad(source: Int) = source and InputDevice.SOURCE_GAMEPAD == InputDevice.SOURCE_GAMEPAD ||
		source and InputDevice.SOURCE_JOYSTICK == InputDevice.SOURCE_JOYSTICK

	/** Кнопка геймпада → номер у розкладці standard: ✕ ○ □ △ L1 R1 L2 R2 Share Options L3 R3 ↑ ↓ ← → PS */
	private fun padIndex(keyCode: Int): Int = when(keyCode)
	{
		KeyEvent.KEYCODE_BUTTON_A -> 0
		KeyEvent.KEYCODE_BUTTON_B -> 1
		KeyEvent.KEYCODE_BUTTON_X -> 2
		KeyEvent.KEYCODE_BUTTON_Y -> 3
		KeyEvent.KEYCODE_BUTTON_L1 -> 4
		KeyEvent.KEYCODE_BUTTON_R1 -> 5
		KeyEvent.KEYCODE_BUTTON_L2 -> 6
		KeyEvent.KEYCODE_BUTTON_R2 -> 7
		KeyEvent.KEYCODE_BUTTON_SELECT -> 8
		KeyEvent.KEYCODE_BUTTON_START -> 9
		KeyEvent.KEYCODE_BUTTON_THUMBL -> 10
		KeyEvent.KEYCODE_BUTTON_THUMBR -> 11
		KeyEvent.KEYCODE_DPAD_UP -> 12
		KeyEvent.KEYCODE_DPAD_DOWN -> 13
		KeyEvent.KEYCODE_DPAD_LEFT -> 14
		KeyEvent.KEYCODE_DPAD_RIGHT -> 15
		KeyEvent.KEYCODE_BUTTON_MODE, KeyEvent.KEYCODE_BUTTON_C -> 16
		else -> -1
	}

	override fun dispatchKeyEvent(event: KeyEvent): Boolean
	{
		// у трансляції кнопки геймпада йдуть у гру (через сторінку), а не на кнопки сторінки
		if(watch && isPad(event.source))
		{
			// частина геймпадів шле ○ як «Назад»: у трансляції це кнопка гри, а не вихід (вийти — жестом «Назад» телефона)
			val i = if(event.keyCode == KeyEvent.KEYCODE_BACK) 1 else padIndex(event.keyCode)
			if(i >= 0 && (event.action == KeyEvent.ACTION_DOWN || event.action == KeyEvent.ACTION_UP))
			{
				padButtons[i] = if(event.action == KeyEvent.ACTION_DOWN) 1f else 0f
				schedulePad()
				return true
			}
		}
		return super.dispatchKeyEvent(event)
	}

	override fun dispatchGenericMotionEvent(event: MotionEvent): Boolean
	{
		if(watch && event.source and InputDevice.SOURCE_CLASS_JOYSTICK == InputDevice.SOURCE_CLASS_JOYSTICK && event.action == MotionEvent.ACTION_MOVE)
		{
			padAxes[0] = event.getAxisValue(MotionEvent.AXIS_X)
			padAxes[1] = event.getAxisValue(MotionEvent.AXIS_Y)
			padAxes[2] = event.getAxisValue(MotionEvent.AXIS_Z)
			padAxes[3] = event.getAxisValue(MotionEvent.AXIS_RZ)
			val l2 = maxOf(event.getAxisValue(MotionEvent.AXIS_LTRIGGER), event.getAxisValue(MotionEvent.AXIS_BRAKE))
			val r2 = maxOf(event.getAxisValue(MotionEvent.AXIS_RTRIGGER), event.getAxisValue(MotionEvent.AXIS_GAS))
			// курки: аналогові осі, якщо є (кнопки L2/R2 приходять окремо як натиснуто/ні)
			if(event.device?.getMotionRange(MotionEvent.AXIS_LTRIGGER) != null || event.device?.getMotionRange(MotionEvent.AXIS_BRAKE) != null)
				padButtons[6] = l2
			if(event.device?.getMotionRange(MotionEvent.AXIS_RTRIGGER) != null || event.device?.getMotionRange(MotionEvent.AXIS_GAS) != null)
				padButtons[7] = r2
			// хрестовина осями (у більшості геймпадів); якщо осей немає, вона приходить кнопками DPAD_* вище
			if(event.device?.getMotionRange(MotionEvent.AXIS_HAT_X) != null)
			{
				val hx = event.getAxisValue(MotionEvent.AXIS_HAT_X)
				val hy = event.getAxisValue(MotionEvent.AXIS_HAT_Y)
				padButtons[12] = if(hy < -0.5f) 1f else 0f
				padButtons[13] = if(hy > 0.5f) 1f else 0f
				padButtons[14] = if(hx < -0.5f) 1f else 0f
				padButtons[15] = if(hx > 0.5f) 1f else 0f
			}
			schedulePad()
			return true
		}
		return super.dispatchGenericMotionEvent(event)
	}
}
