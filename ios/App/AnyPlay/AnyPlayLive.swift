// AnyPlay 157: трансляція друзям з iPhone та iPad — як на Android (AnyPlayLive.kt) і комп'ютері: кімната на нашому
// сервері (/api/live/*), відео й звук гри йдуть у Cloudflare SFU через WebRTC без перекодування (anyplay_live_* у
// рідній частині, libdatachannel), друзі дивляться за посиланням у будь-якому браузері чи в Telegram (watch.html).
// Відео для трансляції — H.264 (H.265 більшість браузерів не показує): якщо гра йде в H.265, вона плавно
// перепідключається в H.264, і трансляція стартує сама. Мікрофона й голосів глядачів на iPhone поки немає.
// Усі запити й рідні виклики — в одній фоновій черзі; меню гри бере знімок стану через info() і чекає onChange.
import Foundation
import AnyPlayCore

final class AnyPlayLive
{
	static let shared = AnyPlayLive()

	/** Меню гри: щось змінилось (стан, глядачі, чат) — у головному потоці */
	var onChange: (() -> Void)?
	/** Коротке повідомлення гравцю поверх гри — у головному потоці */
	var onMessage: ((String) -> Void)?
	/** Екран гри: плавно перепідключити гру (щоб перейти на H.264 для трансляції) */
	var reconnectGame: (() -> Void)?

	private let pollEvery = 2.0
	private let keyGap = 3.0
	private let chatKeep = 60
	private let tracks = ["video", "game", "mic"]
	private let q = DispatchQueue(label: "anyplay-live")
	private let lock = NSLock()

	// стан (пише лише черга q; читають через info() під lock)
	private var state = "off"            // off | starting | live | reconnecting | error
	private var text = ""
	private var token = ""
	private var code = ""
	private var webLink = ""
	private var tgLink = ""
	private var maxViewers = 5
	private var viewers: [[String: Any]] = []
	private var chat: [[String: Any]] = []
	private var lastChatId: Int64 = -1
	private var gameAudio = true
	private var hidden = false            // прихована трансляція лише для адміна (він дивиться гру відео)
	private var eventsCh: Int32 = -1
	private var gen = 0
	private var everLive = false
	private var republishTries = 0
	private var lastKeyAt = 0.0
	private var keyPending = false
	private var known = Set<Int64>()
	private var lastPollOk = 0.0
	private var bytesAt = 0.0, bytesVal: Int64 = 0, gameKbps = 0
	private var sentAt = 0.0, sentVal: Int64 = 0, sentKbps = 0

	private static let liveH264Key = "liveH264"
	/** Гравець веде трансляції: гра в H.264 (читає Session при підключенні) */
	static var wantH264: Bool { UserDefaults.standard.bool(forKey: liveH264Key) }

	private init()
	{
		anyplay_live_set_log { p in
			if let p { Log.add(4, "[live] " + String(cString: p)) }
		}
	}

	var supported: Bool { anyplay_live_available() != 0 }

	private func now() -> Double { ProcessInfo.processInfo.systemUptime }

	// ── рідна частина ──
	private func nativeCodec() -> String { var b = [CChar](repeating: 0, count: 16); anyplay_live_codec(&b, 16); return String(cString: b) }
	private func nativeState() -> String { var b = [CChar](repeating: 0, count: 32); anyplay_live_state(&b, 32); return String(cString: b) }
	private func nativeSdp() -> String
	{
		let need = anyplay_live_local_sdp(nil, 0)
		var b = [CChar](repeating: 0, count: max(need, 1))
		anyplay_live_local_sdp(&b, b.count)
		return String(cString: b)
	}

	// ── для меню ──
	func info() -> [String: Any]
	{
		lock.lock(); defer { lock.unlock() }
		if hidden
		{
			return ["supported": supported, "state": "off", "text": "", "code": "", "webLink": "", "tgLink": "", "viewers": [],
				"maxViewers": maxViewers, "chat": [], "gameAudio": gameAudio, "gameKbps": gameKbps, "sentKbps": 0]
		}
		return ["supported": supported, "state": state, "text": text, "code": code, "webLink": webLink, "tgLink": tgLink,
			"viewers": viewers, "maxViewers": maxViewers, "chat": chat, "gameAudio": gameAudio, "gameKbps": gameKbps, "sentKbps": sentKbps]
	}

	private func changed() { DispatchQueue.main.async { self.onChange?() } }
	private func message(_ m: String) { if !hidden { DispatchQueue.main.async { self.onMessage?(m) } } }

	private func setState(_ s: String, _ t: String = "")
	{
		lock.lock(); state = s; text = t; lock.unlock()
		Log.add(2, "Трансляція: \(s)\(t.isEmpty ? "" : " (\(t))")")
		changed()
	}

	/** Запит до сервера з черги q (блокує її до відповіді) */
	private func api(_ path: String, _ body: [String: Any] = [:]) -> CloudResult
	{
		var b = body
		if !token.isEmpty && b["token"] == nil { b["token"] = token }
		final class Box: @unchecked Sendable { var r = CloudResult(status: 0, json: [:]) }
		let box = Box()
		let sem = DispatchSemaphore(value: 0)
		let payload = b
		Task.detached { box.r = await Cloud.request("POST", path, body: payload); sem.signal() }
		sem.wait()
		return box.r
	}

	private func errText(_ r: CloudResult, _ fallback: String) -> String
	{
		if let t = r.json["text"] as? String, !t.isEmpty { return t }
		switch r.json["error"] as? String ?? ""
		{
		case "not_configured": return "Трансляції ще не налаштовано."
		case "disabled": return "Трансляції зараз вимкнено."
		case "not_playing": return "Трансляцію можна ввімкнути лише під час своєї гри."
		default: return r.status == 0 ? "Немає зв'язку з сервером AnyPlay. Перевір інтернет." : fallback
		}
	}

	private func resetRoom()
	{
		lock.lock(); chat.removeAll(); viewers = []; code = ""; webLink = ""; tgLink = ""; lock.unlock()
		known.removeAll()
		everLive = false
		republishTries = 0
		lastChatId = -1
	}

	// ── керування з меню ──
	func start(gameAudio withAudio: Bool)
	{
		q.async { [self] in
			if hidden && state != "off"
			{
				teardown(true)   // ішов перегляд адміна: замість нього — звичайна трансляція гравця
				setState("off")
			}
			hidden = false
			guard state == "off" || state == "error" else { return }
			guard supported else { message("У цій версії програми трансляції немає."); return }
			guard anyplay_live_header_ready() != 0 else { message("Зачекай кілька секунд, поки з'явиться картинка гри, і спробуй ще раз."); return }
			gameAudio = withAudio
			if nativeCodec() == "H.265", reconnectGame != nil
			{
				// H.265 більшість браузерів не показує: гра перепідключається в H.264, трансляція стартує з новою картинкою
				UserDefaults.standard.set(true, forKey: AnyPlayLive.liveH264Key)
				gen += 1
				let g = gen
				setState("starting", "Перемикаю гру на формат, який показують усі браузери…")
				DispatchQueue.main.async { self.reconnectGame?() }
				waitH264(g, until: now() + 45)
				return
			}
			gen += 1
			resetRoom()
			setState("starting", "Запускаю трансляцію…")
			beginServer(gen)
		}
	}

	private func waitH264(_ g: Int, until: Double)
	{
		q.asyncAfter(deadline: .now() + 1) { [self] in
			guard g == gen, state == "starting" else { return }
			if anyplay_live_header_ready() != 0 && nativeCodec() == "H.264"
			{
				resetRoom()
				setState("starting", "Запускаю трансляцію…")
				beginServer(g)
			}
			else if now() > until
			{
				setState("off")
				message("Гра ще не перепідключилась. Спробуй увімкнути трансляцію ще раз за хвилину.")
			}
			else { waitH264(g, until: until) }
		}
	}

	func stop()
	{
		q.async { [self] in
			guard state != "off" else { return }
			teardown(true)
			setState("off")
			message("Трансляцію вимкнено.")
		}
	}

	func setGameAudio(_ on: Bool)
	{
		q.async { [self] in
			gameAudio = on
			anyplay_live_set_game_audio(on ? 1 : 0)
			if !token.isEmpty { _ = api("/api/live/state", ["gameAudio": on]) }
			changed()
		}
	}

	func sendChat(_ t: String)
	{
		let s = String(t.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
		guard !s.isEmpty else { return }
		q.async { [self] in
			guard !token.isEmpty else { return }
			let r = api("/api/live/chat", ["text": s])
			if r.status == 200 { applyRoom(r.json) }
		}
	}

	/** Гра закінчилась (вийшли з екрана гри): ефір закриваємо */
	func gameEnded()
	{
		q.async { [self] in
			if state != "off" { teardown(true); setState("off") }
			hidden = false
		}
	}

	/** Адмін дивиться гру (сервер у сигналі гри: preview.live) — прихована трансляція лише для нього, у H.264 */
	func adminWatch(_ on: Bool)
	{
		guard supported else { return }
		q.async { [self] in
			if on
			{
				guard state == "off" || state == "error" else { return }
				guard anyplay_live_header_ready() != 0, nativeCodec() == "H.264" else { return }   // H.265 — лишаються знімки
				hidden = true
				gameAudio = true
				gen += 1
				resetRoom()
				Log.add(2, "Адмін дивиться гру: прихована трансляція для нього")
				setState("starting")
				beginServer(gen)
			}
			else if hidden && state != "off"
			{
				Log.add(2, "Адмін більше не дивиться: прихована трансляція закрита")
				teardown(true)
				hidden = false
				setState("off")
			}
		}
	}

	// ── запуск ──
	private func beginServer(_ g: Int)
	{
		guard g == gen else { return }
		let r = api("/api/live/start", ["quality": "720p", "gameAudio": gameAudio, "access": "link", "hidden": hidden])
		guard r.status == 200, let tok = r.json["token"] as? String, !tok.isEmpty else
		{
			if everLive { scheduleRepublish(g, 5); return }
			fail(errText(r, "Не вдалося почати трансляцію. Спробуй ще раз."))
			return
		}
		let oldCode = code
		token = tok
		lastPollOk = now()
		applyRoom(r.json)
		if everLive && !oldCode.isEmpty && code != oldCode
		{
			message("Інтернету не було довго, тож кімната трансляції нова: надішли друзям нове посилання.")
		}
		publish(g)
	}

	private func fail(_ t: String)
	{
		teardown(true)   // кімнату закриваємо: глядач не бачитиме вічне «З'єднуємось…»
		if hidden
		{
			Log.add(2, "Перегляд адміна відео не вдався: \(t)")
			hidden = false
			setState("off")
			return
		}
		setState("error", t)
		message(t)
	}

	private func publish(_ g: Int)
	{
		guard g == gen else { return }
		let failed: (String) -> Void = { [self] t in
			if everLive
			{
				Log.add(2, "Трансляція: не вдалося підключитись знову (\(t)), повтор")
				republishTries += 1
				scheduleRepublish(g, min(15, 3 * Double(republishTries)))
			}
			else { fail(t) }
		}
		anyplay_live_close(-1)
		eventsCh = -1
		let s = api("/api/live/sfu/session")
		guard s.status == 200, let sid = s.json["sessionId"] as? String, !sid.isEmpty else
		{
			if everLive && [401, 403, 404, 410].contains(s.status) { token = ""; beginServer(g); return }
			failed(errText(s, "Сервер трансляцій не відповів. Спробуй ще раз."))
			return
		}
		var ice: [String] = []
		for o in s.json["iceServers"] as? [[String: Any]] ?? []
		{
			if let u = o["urls"] as? [String] { ice += u } else if let u = o["urls"] as? String { ice.append(u) }
		}
		var err = [CChar](repeating: 0, count: 256)
		if anyplay_live_create(ice.joined(separator: "\n"), Int32(paceKbps()), &err, err.count) != 0
		{
			let e = String(cString: err)
			failed(e == "no_header" ? "Немає картинки гри, трансляції нічого показувати." : "Не вдалося підготувати з'єднання трансляції (\(e)).")
			return
		}
		// кандидати: до 2,5 с (STUN може не відповісти — SFU сам знайде шлях до нас)
		let until = now() + 2.5
		while anyplay_live_gathered() == 0 && now() < until { usleep(50_000) }
		guard g == gen else { return }
		let t = api("/api/live/sfu/tracks", [
			"sessionDescription": ["type": "offer", "sdp": nativeSdp()],
			"tracks": tracks.map { ["location": "local", "mid": $0, "trackName": $0] }])
		guard t.status == 200, let answer = t.json["sessionDescription"] as? [String: Any], answer["type"] as? String == "answer" else
		{
			failed(errText(t, "Сервер трансляцій не прийняв відео. Спробуй ще раз."))
			return
		}
		if anyplay_live_apply_answer(answer["sdp"] as? String ?? "", &err, err.count) != 0
		{
			Log.add(2, "Трансляція: відповідь SFU не застосовано: \(String(cString: err))")
			failed("Сервер трансляцій не прийняв відео. Спробуй ще раз.")
			return
		}
		// з'єднання з SFU (ICE + DTLS)
		let until2 = now() + 15
		while nativeState() != "connected" && now() < until2
		{
			guard g == gen else { return }
			if nativeState() == "failed" { break }
			usleep(100_000)
		}
		guard nativeState() == "connected" else
		{
			Log.add(2, "Трансляція: з'єднання з SFU не встановлено, стан \(nativeState())")
			failed("Не вдалося з'єднатися з сервером трансляцій. Можливо, мережа блокує WebRTC.")
			return
		}
		// канали даних (сторінка глядача чекає events; input — керування друга, на iPhone поки без нього)
		let c = api("/api/live/sfu/datachannels/new", ["dataChannels": [
			["location": "local", "dataChannelName": "input"], ["location": "local", "dataChannelName": "events"]]])
		var inId: Int32 = -1, evId: Int32 = -1
		for o in c.json["dataChannels"] as? [[String: Any]] ?? []
		{
			guard o["errorCode"] == nil, let id = o["id"] as? Int else { continue }
			if o["dataChannelName"] as? String == "input" { inId = Int32(id) }
			if o["dataChannelName"] as? String == "events" { evId = Int32(id) }
		}
		let pol = (c.json["policy"] as? [String: Any])?["input"] as? [String: Any]
		guard c.status == 200, inId >= 0, evId >= 0,
			anyplay_live_open_channel(inId, "input", (pol?["ordered"] as? Bool ?? false) ? 1 : 0, Int32(pol?["maxRetransmits"] as? Int ?? 0)) != 0,
			anyplay_live_open_channel(evId, "events", 1, -1) != 0 else
		{
			failed(errText(c, "Сервер трансляцій не відкрив канал. Спробуй ще раз."))
			return
		}
		eventsCh = evId
		goLive(g)
	}

	private func goLive(_ g: Int)
	{
		let again = everLive
		everLive = true
		republishTries = 0
		anyplay_live_go_live(gameAudio ? 1 : 0)
		lastKeyAt = now()
		setState("live")
		_ = api("/api/live/state", ["paused": false, "muted": true])
		message(again ? "Трансляція знову в ефірі." : "Трансляцію ввімкнено. Надішли друзям посилання.")
		Log.add(2, "Трансляція в ефірі: кімната \(code), \(nativeCodec())\(hidden ? " (для адміна)" : "")")
		tick(g)
	}

	/** Раз на 2 с: кімната (глядачі, чат), стан з'єднання, ключові кадри, швидкість */
	private func tick(_ g: Int)
	{
		guard g == gen, state == "live" || state == "reconnecting" else { return }
		let st = nativeState()
		if state == "live" && (st == "failed" || st == "closed" || st == "disconnected")
		{
			if st != "disconnected" || now() - lastPollOk > 6
			{
				anyplay_live_set_video_on(0)
				setState("reconnecting", "Зник інтернет. Ефір повернеться сам, щойно зв'язок з'явиться.")
				scheduleRepublish(g, 2)
				return
			}
		}
		if anyplay_live_take_key_wanted() > 0 { keyframe() }
		poll(g)
		speed()
		q.asyncAfter(deadline: .now() + pollEvery) { [weak self] in self?.tick(g) }
	}

	private func speed()
	{
		let t = now()
		let b = anyplay_live_game_bytes()
		if bytesAt > 0 && t > bytesAt { gameKbps = Int(Double(b - bytesVal) * 8 / ((t - bytesAt) * 1000)) }
		bytesAt = t; bytesVal = b
		var v = [Int64](repeating: 0, count: 9)
		anyplay_live_stats(&v)
		if sentAt > 0 && t > sentAt { sentKbps = Int(Double(v[4] - sentVal) * 8 / ((t - sentAt) * 1000)) }
		sentAt = t; sentVal = v[4]
	}

	/** Межа швидкості для глядачів: з запасом над бітрейтом гри */
	private func paceKbps() -> Int { gameKbps > 0 ? min(max(gameKbps * 13 / 10, 4000), 25000) : 20000 }

	private func keyframe()
	{
		let t = now()
		if t - lastKeyAt < keyGap
		{
			if !keyPending
			{
				keyPending = true
				let g = gen
				q.asyncAfter(deadline: .now() + (keyGap - (t - lastKeyAt)) + 0.01) { [self] in
					keyPending = false
					if g == gen && state == "live" { keyframe() }
				}
			}
			return
		}
		lastKeyAt = t
		anyplay_live_request_keyframe()
	}

	private func scheduleRepublish(_ g: Int, _ delay: Double)
	{
		q.asyncAfter(deadline: .now() + delay) { [self] in
			guard g == gen else { return }
			if token.isEmpty { beginServer(g) } else { publish(g) }
		}
	}

	private func poll(_ g: Int)
	{
		guard !token.isEmpty else { return }
		let r = api("/api/live/poll", ["after": lastChatId])
		guard g == gen else { return }
		let err = r.json["error"] as? String ?? ""
		if r.status == 404 || r.status == 410 || err == "closed"
		{
			if everLive && now() - lastPollOk > 20
			{
				token = ""
				anyplay_live_set_video_on(0)
				setState("reconnecting", "Зник інтернет. Ефір повернеться сам, щойно зв'язок з'явиться.")
				scheduleRepublish(g, 0)
				return
			}
			teardown(false)
			setState("off")
			message("Трансляцію завершено.")
			return
		}
		guard r.status == 200 else { return }   // тимчасові збої зв'язку ефір не зупиняють
		lastPollOk = now()
		applyRoom(r.json)
	}

	private func int64(_ v: Any?) -> Int64 { (v as? NSNumber)?.int64Value ?? 0 }

	private func applyRoom(_ o: [String: Any])
	{
		guard let room = o["room"] as? [String: Any] else { return }
		if room["status"] as? String == "closed" && (state == "live" || state == "reconnecting")
		{
			teardown(false)
			setState("off")
			message("Трансляцію завершено на сервері.")
			return
		}
		var list: [[String: Any]] = []
		var newcomer = false
		var seen = Set<Int64>()
		for m in o["members"] as? [[String: Any]] ?? []
		{
			if m["player"] as? Bool == true || m["me"] as? Bool == true { continue }
			let id = int64(m["memberId"])
			seen.insert(id)
			if known.insert(id).inserted { newcomer = true }
			list.append(["name": m["name"] as? String ?? "", "friend": m["friend"] as? Bool ?? false])
		}
		known = known.intersection(seen)
		let history = lastChatId < 0   // перша відповідь кімнати — це історія, її повідомленнями не показуємо
		var fresh: [[String: Any]] = []
		lock.lock()
		code = room["code"] as? String ?? code
		webLink = room["webLink"] as? String ?? webLink
		tgLink = room["link"] as? String ?? tgLink
		maxViewers = room["maxViewers"] as? Int ?? maxViewers
		viewers = list
		for c in o["chat"] as? [[String: Any]] ?? []
		{
			if int64(c["id"]) > lastChatId || lastChatId < 0 { chat.append(c); fresh.append(c) }
		}
		if chat.count > chatKeep { chat.removeFirst(chat.count - chatKeep) }
		lock.unlock()
		if o["lastChatId"] != nil { lastChatId = max(lastChatId, int64(o["lastChatId"])) }
		// нові повідомлення глядачів — коротко поверх гри (свої — ні)
		if !history && state == "live"
		{
			let lines = fresh.filter { $0["role"] as? String != "player" }.suffix(2).map { c -> String in
				let name = c["name"] as? String ?? ""
				let t = c["text"] as? String ?? ""
				return String((c["kind"] as? String == "system" || name.isEmpty ? t : "\(name): \(t)").prefix(140))
			}.filter { !$0.isEmpty }
			if !lines.isEmpty { message(lines.joined(separator: "\n")) }
		}
		// новий глядач: ключовий кадр зараз і ще раз за 3 с
		if newcomer && state == "live"
		{
			keyframe()
			let g = gen
			q.asyncAfter(deadline: .now() + keyGap + 0.1) { [self] in if g == gen && state == "live" { keyframe() } }
		}
		changed()
	}

	private func teardown(_ tellServer: Bool)
	{
		gen += 1
		anyplay_live_close(tellServer ? eventsCh : -1)
		eventsCh = -1
		if tellServer && !token.isEmpty { _ = api("/api/live/stop") }
		token = ""
		everLive = false
		known.removeAll()
		lock.lock(); viewers = []; code = ""; webLink = ""; tgLink = ""; lock.unlock()
	}
}
