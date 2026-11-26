// AnyPlay 124: трансляція друзям з телефона. Як на комп'ютері (gui/src/anyplaylive.cpp): кімната на нашому сервері
// (/api/live/*), відео й звук гри йдуть у Cloudflare SFU через WebRTC без перекодування (LiveNative), друзі дивляться
// за посиланням у будь-якому браузері чи в Telegram (watch.html). Ефір не стає на паузу сам: зупиняється лише кнопкою
// або коли в гравця зник інтернет (тоді повертається сам).
// Усі запити й рідні виклики — в одному фоновому потоці; екран бере знімок стану через info() і чекає onChange.
package com.metallic.chiaki.anyplay

import android.content.Context
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.SystemClock
import com.metallic.chiaki.lib.LiveNative
import org.json.JSONArray
import org.json.JSONObject

object AnyPlayLive
{
	private const val POLL_MS = 2000L
	private const val KEY_GAP_MS = 3000L
	private const val CHAT_KEEP = 60
	private val TRACKS = arrayOf("video", "game", "mic")
	private const val CH_INPUT = "input"
	private const val CH_EVENTS = "events"

	private var thread: HandlerThread? = null
	private var h: Handler? = null
	private val main = Handler(Looper.getMainLooper())
	private lateinit var app: Context

	/** Екран гри: щось змінилось (стан, глядачі, чат) — у головному потоці */
	@Volatile var onChange: (() -> Unit)? = null
	/** Коротке повідомлення гравцю (тост) — у головному потоці */
	@Volatile var onMessage: ((String) -> Unit)? = null

	// стан (лише фоновий потік пише; читають через info() під lock)
	private val lock = Any()
	private var state = "off"            // off | starting | live | reconnecting | error
	private var text = ""
	private var token = ""
	private var code = ""
	private var webLink = ""
	private var tgLink = ""
	private var maxViewers = 5
	private var viewers = JSONArray()
	private val chat = ArrayList<JSONObject>()
	private var lastChatId = -1L
	private var gameAudio = true
	private var eventsCh = -1
	private var gen = 0
	private var everLive = false
	private var republishTries = 0
	private var lastKeyAt = 0L
	private var keyPending = false
	private val known = HashSet<Long>()
	private var lastPollOk = 0L
	private var bytesAt = 0L
	private var bytesVal = 0L
	private var gameKbps = 0
	private var sentKbps = 0
	private var sentAt = 0L
	private var sentVal = 0L

	val supported: Boolean get() = LiveNative.available

	private fun worker(): Handler
	{
		h?.let { return it }
		val t = HandlerThread("anyplay-live").apply { start() }
		thread = t
		return Handler(t.looper).also { h = it }
	}

	private fun changed() = main.post { onChange?.invoke() }
	private fun message(m: String) = main.post { onMessage?.invoke(m) }

	/** Знімок для меню гри (будь-який потік) */
	fun info(): JSONObject = synchronized(lock) {
		JSONObject()
			.put("supported", supported)
			.put("state", state)
			.put("text", text)
			.put("code", code)
			.put("webLink", webLink)
			.put("tgLink", tgLink)
			.put("viewers", JSONArray(viewers.toString()))
			.put("maxViewers", maxViewers)
			.put("chat", JSONArray(chat.map { JSONObject(it.toString()) }))
			.put("gameAudio", gameAudio)
			.put("gameKbps", gameKbps)
			.put("sentKbps", sentKbps)
	}

	private fun setState(s: String, t: String = "")
	{
		synchronized(lock) { state = s; text = t }
		AnyPlayDiag.i("Трансляція: $s${if(t.isNotEmpty()) " ($t)" else ""}")
		changed()
	}

	private fun api(path: String, body: JSONObject = JSONObject()): com.metallic.chiaki.anyplay.CloudResult
	{
		if(token.isNotEmpty() && !body.has("token"))
			body.put("token", token)
		return AnyPlayCloud.request(app, "POST", path, body)
	}

	private fun errText(r: com.metallic.chiaki.anyplay.CloudResult, fallback: String): String
	{
		val t = r.json.optString("text")
		if(t.isNotEmpty())
			return t
		return when(r.json.optString("error"))
		{
			"not_configured" -> "Трансляції ще не налаштовано."
			"disabled" -> "Трансляції зараз вимкнено."
			"not_playing" -> "Трансляцію можна ввімкнути лише під час своєї гри."
			else -> if(r.status == 0) "Немає зв'язку з сервером AnyPlay. Перевір інтернет." else fallback
		}
	}

	// ───────────────────────────── керування з екрана ─────────────────────────────

	fun start(context: Context, withGameAudio: Boolean)
	{
		app = context.applicationContext
		worker().post {
			if(state != "off" && state != "error")
				return@post
			if(!supported)
			{
				message("У цій версії програми трансляції немає.")
				return@post
			}
			if(!LiveNative.headerReady())
			{
				message("Зачекай кілька секунд, поки з'явиться картинка гри, і спробуй ще раз.")
				return@post
			}
			gen++
			gameAudio = withGameAudio
			everLive = false
			republishTries = 0
			lastChatId = -1
			synchronized(lock) { chat.clear(); viewers = JSONArray(); code = ""; webLink = ""; tgLink = "" }
			known.clear()
			setState("starting", "Запускаю трансляцію…")
			beginServer(gen)
		}
	}

	fun stop()
	{
		val hh = h ?: return
		hh.post { teardown(true); setState("off") ; message("Трансляцію вимкнено.") }
	}

	fun setGameAudio(on: Boolean)
	{
		worker().post {
			gameAudio = on
			LiveNative.setGameAudio(on)
			if(token.isNotEmpty())
				api("/api/live/state", JSONObject().put("gameAudio", on))
			changed()
		}
	}

	fun sendChat(text: String)
	{
		val t = text.trim().take(300)
		if(t.isEmpty())
			return
		worker().post {
			if(token.isEmpty())
				return@post
			val r = api("/api/live/chat", JSONObject().put("text", t))
			if(r.status != 200)
				message(errText(r, "Повідомлення не надіслано."))
			poll(gen)
		}
	}

	/** Гра закінчилась (вийшли з екрана гри): ефір закриваємо */
	fun gameEnded()
	{
		val hh = h ?: return
		hh.post { if(state != "off") { teardown(true); setState("off") } }
	}

	// ───────────────────────────── запуск ─────────────────────────────

	private fun beginServer(g: Int)
	{
		if(g != gen)
			return
		val r = api("/api/live/start", JSONObject().put("quality", "720p").put("gameAudio", gameAudio).put("access", "link"))
		val tok = r.json.optString("token")
		if(r.status != 200 || tok.isEmpty())
		{
			if(everLive) { scheduleRepublish(g, 5000); return }
			fail(errText(r, "Не вдалося почати трансляцію. Спробуй ще раз."))
			return
		}
		val oldCode = code
		token = tok
		lastPollOk = SystemClock.elapsedRealtime()
		applyRoom(r.json)
		if(everLive && oldCode.isNotEmpty() && code != oldCode)
			message("Інтернету не було довго, тож кімната трансляції нова: надішли друзям нове посилання.")
		publish(g)
	}

	private fun fail(t: String)
	{
		teardown(false)
		setState("error", t)
		message(t)
	}

	private fun publish(g: Int)
	{
		if(g != gen)
			return
		val failed = { t: String ->
			if(everLive)
			{
				AnyPlayDiag.w("Трансляція: не вдалося підключитись знову ($t), повтор")
				scheduleRepublish(g, minOf(15000L, 3000L * (1 + republishTries++)))
			}
			else
				fail(t)
		}
		LiveNative.close(-1)
		eventsCh = -1
		val s = api("/api/live/sfu/session")
		if(s.status != 200 || s.json.optString("sessionId").isEmpty())
		{
			if(everLive && s.status in intArrayOf(401, 403, 404, 410))
			{
				token = ""
				beginServer(g)
				return
			}
			failed(errText(s, "Сервер трансляцій не відповів. Спробуй ще раз."))
			return
		}
		val ice = ArrayList<String>()
		s.json.optJSONArray("iceServers")?.let { arr ->
			for(i in 0 until arr.length())
			{
				val u = arr.optJSONObject(i)?.opt("urls")
				if(u is JSONArray) for(j in 0 until u.length()) ice.add(u.optString(j))
				else if(u is String) ice.add(u)
			}
		}
		val err = LiveNative.create(ice.toTypedArray(), paceKbps())
		if(err.isNotEmpty())
		{
			failed(if(err == "no_header") "Немає картинки гри, трансляції нічого показувати." else "Не вдалося підготувати з'єднання трансляції ($err).")
			return
		}
		// кандидати: до 2,5 с (STUN може не відповісти — SFU сам знайде шлях до нас)
		val until = SystemClock.elapsedRealtime() + 2500
		while(!LiveNative.gathered() && SystemClock.elapsedRealtime() < until)
			Thread.sleep(50)
		if(g != gen)
			return
		val tracks = JSONArray()
		for(name in TRACKS)
			tracks.put(JSONObject().put("location", "local").put("mid", name).put("trackName", name))
		val t = api("/api/live/sfu/tracks", JSONObject()
			.put("sessionDescription", JSONObject().put("type", "offer").put("sdp", LiveNative.localSdp()))
			.put("tracks", tracks))
		val answer = t.json.optJSONObject("sessionDescription")
		if(t.status != 200 || answer?.optString("type") != "answer")
		{
			failed(errText(t, "Сервер трансляцій не прийняв відео. Спробуй ще раз."))
			return
		}
		val ae = LiveNative.applyAnswer(answer.optString("sdp"))
		if(ae.isNotEmpty())
		{
			AnyPlayDiag.w("Трансляція: відповідь SFU не застосовано: $ae")
			failed("Сервер трансляцій не прийняв відео. Спробуй ще раз.")
			return
		}
		// з'єднання з SFU (ICE + DTLS)
		val until2 = SystemClock.elapsedRealtime() + 15000
		while(LiveNative.state() != "connected" && SystemClock.elapsedRealtime() < until2)
		{
			if(g != gen) return
			if(LiveNative.state() == "failed") break
			Thread.sleep(100)
		}
		if(LiveNative.state() != "connected")
		{
			failed("Не вдалося з'єднатися з сервером трансляцій. Можливо, мережа блокує WebRTC.")
			return
		}
		// канали даних (сторінка глядача чекає events; input — керування друга, на телефоні поки без нього)
		val c = api("/api/live/sfu/datachannels/new", JSONObject().put("dataChannels", JSONArray()
			.put(JSONObject().put("location", "local").put("dataChannelName", CH_INPUT))
			.put(JSONObject().put("location", "local").put("dataChannelName", CH_EVENTS))))
		var inId = -1
		var evId = -1
		c.json.optJSONArray("dataChannels")?.let { arr ->
			for(i in 0 until arr.length())
			{
				val o = arr.optJSONObject(i) ?: continue
				if(o.has("errorCode") || !o.has("id")) continue
				when(o.optString("dataChannelName"))
				{
					CH_INPUT -> inId = o.optInt("id", -1)
					CH_EVENTS -> evId = o.optInt("id", -1)
				}
			}
		}
		val pol = c.json.optJSONObject("policy")?.optJSONObject(CH_INPUT)
		if(c.status != 200 || inId < 0 || evId < 0
			|| !LiveNative.openChannel(inId, CH_INPUT, pol?.optBoolean("ordered", false) ?: false, pol?.optInt("maxRetransmits", 0) ?: 0)
			|| !LiveNative.openChannel(evId, CH_EVENTS, true, -1))
		{
			failed(errText(c, "Сервер трансляцій не відкрив канал. Спробуй ще раз."))
			return
		}
		eventsCh = evId
		goLive(g)
	}

	private fun goLive(g: Int)
	{
		val again = everLive
		everLive = true
		republishTries = 0
		LiveNative.goLive(gameAudio)
		lastKeyAt = SystemClock.elapsedRealtime()
		setState("live")
		api("/api/live/state", JSONObject().put("paused", false).put("muted", true))
		message(if(again) "Трансляція знову в ефірі." else "Трансляцію ввімкнено. Надішли друзям посилання.")
		AnyPlayDiag.i("Трансляція в ефірі: кімната $code, ${LiveNative.codec()}")
		h?.removeCallbacksAndMessages(TICK)
		tick(g)
	}

	private val TICK = Any()

	/** Раз на 2 с: кімната (глядачі, чат), стан з'єднання, ключові кадри, швидкість */
	private fun tick(g: Int)
	{
		if(g != gen || (state != "live" && state != "reconnecting"))
			return
		val st = LiveNative.state()
		if(state == "live" && (st == "failed" || st == "closed" || st == "disconnected"))
		{
			if(st != "disconnected" || SystemClock.elapsedRealtime() - lastPollOk > 6000)
			{
				LiveNative.setVideoOn(false)
				setState("reconnecting", "Зник інтернет. Ефір повернеться сам, щойно зв'язок з'явиться.")
				scheduleRepublish(g, 2000)
				return
			}
		}
		if(LiveNative.takeKeyWanted() > 0)
			keyframe()
		poll(g)
		speed()
		h?.postAtTime({ tick(g) }, TICK, SystemClock.uptimeMillis() + POLL_MS)
	}

	private fun speed()
	{
		val now = SystemClock.elapsedRealtime()
		val b = LiveNative.gameBytes()
		if(bytesAt > 0 && now > bytesAt)
			gameKbps = ((b - bytesVal) * 8 / (now - bytesAt)).toInt()
		bytesAt = now; bytesVal = b
		val s = LiveNative.stats()
		if(s != null && s.size > 4)
		{
			if(sentAt > 0 && now > sentAt)
				sentKbps = ((s[4] - sentVal) * 8 / (now - sentAt)).toInt()
			sentAt = now; sentVal = s[4]
		}
	}

	/** Межа швидкості для глядачів: з запасом над бітрейтом гри (дані з гачка відео) */
	private fun paceKbps(): Int = if(gameKbps > 0) (gameKbps * 13 / 10).coerceIn(4000, 25000) else 20000

	private fun keyframe()
	{
		val now = SystemClock.elapsedRealtime()
		if(now - lastKeyAt < KEY_GAP_MS)
		{
			if(!keyPending)
			{
				keyPending = true
				val g = gen
				h?.postDelayed({ keyPending = false; if(g == gen && state == "live") keyframe() }, KEY_GAP_MS - (now - lastKeyAt) + 10)
			}
			return
		}
		lastKeyAt = now
		LiveNative.requestKeyframe()
	}

	private fun scheduleRepublish(g: Int, delay: Long)
	{
		h?.postDelayed({
			if(g != gen) return@postDelayed
			if(token.isEmpty()) beginServer(g) else publish(g)
		}, delay)
	}

	private fun poll(g: Int)
	{
		if(token.isEmpty())
			return
		val r = api("/api/live/poll", JSONObject().put("after", lastChatId))
		if(g != gen)
			return
		val err = r.json.optString("error")
		if(r.status == 404 || r.status == 410 || err == "closed")
		{
			if(everLive && SystemClock.elapsedRealtime() - lastPollOk > 20000)
			{
				token = ""
				LiveNative.setVideoOn(false)
				setState("reconnecting", "Зник інтернет. Ефір повернеться сам, щойно зв'язок з'явиться.")
				scheduleRepublish(g, 0)
				return
			}
			teardown(false)
			setState("off")
			message("Трансляцію завершено.")
			return
		}
		if(r.status != 200)
			return   // тимчасові збої зв'язку ефір не зупиняють
		lastPollOk = SystemClock.elapsedRealtime()
		applyRoom(r.json)
	}

	private fun applyRoom(o: JSONObject)
	{
		val room = o.optJSONObject("room") ?: return
		if(room.optString("status") == "closed" && (state == "live" || state == "reconnecting"))
		{
			teardown(false)
			setState("off")
			message("Трансляцію завершено на сервері.")
			return
		}
		val list = JSONArray()
		var newcomer = false
		val seen = HashSet<Long>()
		o.optJSONArray("members")?.let { arr ->
			for(i in 0 until arr.length())
			{
				val m = arr.optJSONObject(i) ?: continue
				if(m.optBoolean("player") || m.optBoolean("me"))
					continue
				val id = m.optLong("memberId")
				seen.add(id)
				if(known.add(id))
					newcomer = true
				list.put(JSONObject().put("name", m.optString("name")).put("friend", m.optBoolean("friend")))
			}
		}
		known.retainAll(seen)
		synchronized(lock) {
			code = room.optString("code", code)
			webLink = room.optString("webLink", webLink)
			tgLink = room.optString("link", tgLink)
			maxViewers = room.optInt("maxViewers", maxViewers)
			viewers = list
			o.optJSONArray("chat")?.let { arr ->
				for(i in 0 until arr.length())
					arr.optJSONObject(i)?.let { c -> if(c.optLong("id") > lastChatId || lastChatId < 0) chat.add(c) }
			}
			while(chat.size > CHAT_KEEP)
				chat.removeAt(0)
		}
		if(o.has("lastChatId"))
			lastChatId = maxOf(lastChatId, o.optLong("lastChatId"))
		// новий глядач: ключовий кадр зараз і ще раз за 3 с (перший він може проминути, поки підключає відео)
		if(newcomer && state == "live")
		{
			keyframe()
			val g = gen
			h?.postDelayed({ if(g == gen && state == "live") keyframe() }, KEY_GAP_MS + 100)
		}
		changed()
	}

	private fun teardown(tellServer: Boolean)
	{
		gen++
		h?.removeCallbacksAndMessages(null)
		LiveNative.close(if(tellServer) eventsCh else -1)
		eventsCh = -1
		if(tellServer && token.isNotEmpty())
			api("/api/live/stop")
		token = ""
		everLive = false
		known.clear()
		synchronized(lock) { viewers = JSONArray(); code = ""; webLink = ""; tgLink = "" }
	}
}
