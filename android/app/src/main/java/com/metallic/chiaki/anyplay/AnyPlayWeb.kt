// AnyPlay: екрани бронювання, продовження і «Мій PSN» — вбудована сторінка (assets/anyplay/app.html),
// яка ходить на сервер через цю програму; і вікно входу в PSN на сайті Sony.
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
import android.net.Uri
import android.os.Bundle
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup
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
import com.metallic.chiaki.R
import com.metallic.chiaki.touchcontrols.ButtonHaptics
import org.json.JSONObject
import java.util.concurrent.Executors

private val anyplayIo = Executors.newCachedThreadPool()

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

/** Повноекранне вікно з вбудованою сторінкою AnyPlay. page: book | mine | extend | psn */
class AnyPlayWebDialog(private val activity: Activity, private val page: String, private val onClosed: () -> Unit = {}):
	Dialog(activity, R.style.AnyPlayTheme)
{
	private lateinit var web: WebView
	private val haptics = ButtonHaptics(activity)

	@SuppressLint("SetJavaScriptEnabled")
	override fun onCreate(savedInstanceState: Bundle?)
	{
		super.onCreate(savedInstanceState)
		web = WebView(activity)
		web.setBackgroundColor(Color.rgb(11, 6, 24))
		web.settings.javaScriptEnabled = true
		web.settings.domStorageEnabled = true
		web.overScrollMode = View.OVER_SCROLL_NEVER
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
		web.addJavascriptInterface(Bridge(), "AnyPlay")
		setContentView(web, ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
		window?.setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
		web.loadUrl("file:///android_asset/anyplay/app.html#$page")
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

	private inner class Bridge
	{
		@JavascriptInterface
		fun req(id: Int, method: String, path: String, body: String)
		{
			if(!path.startsWith("/api/app/"))
				return
			anyplayIo.execute {
				val json = if(body.isEmpty()) null else try { JSONObject(body) } catch(e: Exception) { null }
				val r = AnyPlayCloud.request(activity, if(method == "POST") "POST" else "GET", path, json)
				val text = JSONObject.quote(r.json.toString())
				activity.runOnUiThread {
					if(isShowing)
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
		fun close() = activity.runOnUiThread { dismiss() }

		@JavascriptInterface
		fun haptic() = activity.runOnUiThread { haptics.trigger() }

		@JavascriptInterface
		fun psnLogin(create: Boolean) = activity.runOnUiThread {
			PsnLoginDialog(activity, create) { error ->
				if(error != null)
					Toast.makeText(activity, error, Toast.LENGTH_LONG).show()
				else
					Toast.makeText(activity, "Вхід у PSN виконано. Адміністратор додасть твій профіль на приставку: це кілька хвилин.", Toast.LENGTH_LONG).show()
				if(isShowing)
					web.evaluateJavascript("window.__anyplayEvent && window.__anyplayEvent('psn')", null)
			}.show()
		}
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
		val root = LinearLayout(activity).apply { orientation = LinearLayout.VERTICAL; setBackgroundColor(Color.rgb(26, 11, 51)) }
		val density = activity.resources.displayMetrics.density
		val bar = LinearLayout(activity).apply {
			orientation = LinearLayout.HORIZONTAL
			gravity = Gravity.CENTER_VERTICAL
			setPadding((14 * density).toInt(), (10 * density).toInt(), (14 * density).toInt(), (10 * density).toInt())
		}
		bar.addView(TextView(activity).apply {
			text = "✕"
			textSize = 20f
			setTextColor(Color.WHITE)
			setPadding((8 * density).toInt(), (4 * density).toInt(), (16 * density).toInt(), (4 * density).toInt())
			setOnClickListener { dismiss() }
		})
		bar.addView(TextView(activity).apply {
			text = if(create) "Реєстрація й вхід у PSN" else "Вхід у PSN: пароль бачить лише Sony"
			textSize = 15f
			setTextColor(Color.WHITE)
		})
		root.addView(bar)
		val frame = FrameLayout(activity)
		web = WebView(activity)
		web.settings.javaScriptEnabled = true
		web.settings.domStorageEnabled = true
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
			setBackgroundColor(Color.rgb(11, 6, 24))
			visibility = View.GONE
			addView(ProgressBar(activity))
			addView(TextView(activity).apply {
				text = "Перевіряємо вхід у Sony…"
				textSize = 16f
				setTextColor(Color.WHITE)
				setPadding(0, (16 * density).toInt(), 0, 0)
			})
		}
		frame.addView(progress, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
		root.addView(frame, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
		setContentView(root)
		window?.setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
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
