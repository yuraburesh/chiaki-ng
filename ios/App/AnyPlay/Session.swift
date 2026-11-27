// AnyPlay для iPhone та iPad: сесія гри поверх рідної частини (ios/core/anyplay_core.h).
// Відео — у VideoView (апаратний декодер через AVSampleBufferDisplayLayer), звук — в AudioOut, події — у гру.
import Foundation
import AnyPlayCore

protocol SessionDelegate: AnyObject
{
	func sessionConnected()
	func sessionQuit(reason: Int, text: String)
	func sessionRumble(left: Int, right: Int)
	func sessionTriggers(typeL: Int, typeR: Int, data: [UInt8])
}

final class Session
{
	private var core: OpaquePointer?
	weak var delegate: SessionDelegate?
	let video: VideoView
	let audio = AudioOut()
	// лічильники для статистики (потік сесії пише, головний читає)
	private let lock = NSLock()
	private(set) var framesIn: UInt64 = 0
	private(set) var bytesIn: UInt64 = 0
	private(set) var framesLost: UInt64 = 0
	private(set) var started = false

	init(video: VideoView) { self.video = video }

	/** Створити сесію для PS5 через PSN. Повертає текст помилки або nil */
	func create(target: PlayReady, profile: VideoProfile) -> String?
	{
		var info = AnyPlayConnect()
		info.ps5 = true
		info.width = profile.width
		info.height = profile.height
		info.max_fps = profile.fps
		info.bitrate = profile.bitrate
		info.h265 = true
		withUnsafeMutableBytes(of: &info.psn_account_id) { p in
			for (i, b) in target.accountId.prefix(8).enumerated() { p[i] = b }
		}
		var cb = AnyPlayCallbacks()
		cb.user = Unmanaged.passUnretained(self).toOpaque()
		cb.video = { user, data, size, lost, _ in
			guard let user = user, let data = data else { return true }
			let s = Unmanaged<Session>.fromOpaque(user).takeUnretainedValue()
			s.lock.lock(); s.framesIn += 1; s.bytesIn += UInt64(size); if lost > 0 { s.framesLost += UInt64(lost) }; s.lock.unlock()
			s.video.feed(UnsafeBufferPointer(start: data, count: size))
			return true
		}
		cb.audio_format = { user, channels, rate in
			guard let user = user else { return }
			Unmanaged<Session>.fromOpaque(user).takeUnretainedValue().audio.setFormat(channels: Int(channels), rate: Double(rate))
		}
		cb.audio = { user, pcm, frames in
			guard let user = user, let pcm = pcm else { return }
			Unmanaged<Session>.fromOpaque(user).takeUnretainedValue().audio.play(pcm, frames: Int(frames))
		}
		cb.event = { user, type, a, b, text, data, size in
			guard let user = user else { return }
			let s = Unmanaged<Session>.fromOpaque(user).takeUnretainedValue()
			let t = text.map { String(cString: $0) } ?? ""
			let bytes = data.map { Array(UnsafeBufferPointer(start: $0, count: size)) } ?? []
			DispatchQueue.main.async {
				// ANYPLAY_EVENT_*: 1 підключено, 2 кінець, 3 вібрація, 4 курки, 5 PIN
				switch Int(type)
				{
				case 1: s.delegate?.sessionConnected()
				case 2: s.delegate?.sessionQuit(reason: Int(a), text: t)
				case 3: s.delegate?.sessionRumble(left: Int(a), right: Int(b))
				case 4: s.delegate?.sessionTriggers(typeL: Int(a), typeR: Int(b), data: bytes)
				default: break
				}
			}
		}
		cb.log = { _, level, msg in
			guard let msg = msg else { return }
			Log.add(Int(level), String(cString: msg))
		}
		var err: Int32 = 0
		let c: OpaquePointer?
		if let addr = target.lanAddr
		{
			// 136: домашня мережа — напряму за адресою, ключами прив'язки, без PSN
			withUnsafeMutableBytes(of: &info.regist_key) { p in for (i, b) in target.registKey.prefix(16).enumerated() { p[i] = b } }
			withUnsafeMutableBytes(of: &info.morning) { p in for (i, b) in target.morning.prefix(16).enumerated() { p[i] = b } }
			c = addr.withCString { host in
				info.host = host
				info.psn_token = nil
				return withUnsafePointer(to: &info) { ip in withUnsafePointer(to: &cb) { cp in anyplay_core_create(ip, cp, &err) } }
			}
		}
		else
		{
			c = target.token.withCString { tok in
				info.psn_token = tok
				return "0.0.0.0".withCString { host in
					info.host = host
					return withUnsafePointer(to: &info) { ip in
						withUnsafePointer(to: &cb) { cp in anyplay_core_create(ip, cp, &err) }
					}
				}
			}
		}
		guard let created = c else { return "Не вдалося підготувати гру (помилка \(err)). Спробуй ще раз." }
		core = created
		return nil
	}

	/** Довго (до хвилини), не з головного потоку. 0 — успіх */
	func psnConnect(duid: String) -> Int32 { anyplay_core_psn_connect(core, duid) }
	var psnStep: Int { Int(anyplay_core_psn_step(core)) }
	func psnCancel() { anyplay_core_psn_cancel(core) }

	func start() -> Int32
	{
		let r = anyplay_core_start(core)
		started = r == 0
		return r
	}

	func setController(_ s: PadState)
	{
		anyplay_core_set_controller(core, s.buttons, s.l2, s.r2, s.lx, s.ly, s.rx, s.ry)
	}

	func touch(id: Int, x: UInt16, y: UInt16, up: Bool) -> Int { Int(anyplay_core_touch(core, Int32(id), x, y, up)) }
	func requestIDR() { anyplay_core_request_idr(core) }
	var packetLoss: Double { anyplay_core_packet_loss(core) }
	var rttMs: Int { Int(anyplay_core_rtt_us(core) / 1000) }

	func counters() -> (UInt64, UInt64, UInt64)
	{
		lock.lock(); defer { lock.unlock() }
		return (framesIn, bytesIn, framesLost)
	}

	/** Зупинити й звільнити (у фоні: чекає кінця потоку сесії) */
	func close()
	{
		guard let c = core else { return }
		core = nil
		delegate = nil   // 134: події старої сесії (кінець трансляції) не мають закривати нову
		anyplay_core_psn_cancel(c)
		// self тримаємо, доки потік сесії не зупиниться: він ще може покликати наші обробники
		DispatchQueue.global().async { anyplay_core_free(c); _ = self }
		audio.stop()
	}

	static func quitText(_ reason: Int) -> String { String(cString: anyplay_core_quit_string(Int32(reason))) }
	static func quitIsError(_ reason: Int) -> Bool { anyplay_core_quit_is_error(Int32(reason)) }
}

/** Стан геймпада для приставки (екранні кнопки і справжній геймпад разом) */
struct PadState: Equatable
{
	var buttons: UInt32 = 0
	var l2: UInt8 = 0, r2: UInt8 = 0
	var lx: Int16 = 0, ly: Int16 = 0, rx: Int16 = 0, ry: Int16 = 0

	func merged(_ o: PadState) -> PadState
	{
		func pick(_ a: Int16, _ b: Int16) -> Int16 { abs(Int(a)) >= abs(Int(b)) ? a : b }
		return PadState(buttons: buttons | o.buttons, l2: max(l2, o.l2), r2: max(r2, o.r2),
			lx: pick(lx, o.lx), ly: pick(ly, o.ly), rx: pick(rx, o.rx), ry: pick(ry, o.ry))
	}
}

/** Журнал гри (останні рядки — для підтримки) */
enum Log
{
	private static let q = DispatchQueue(label: "anyplay.log")
	private static var lines: [String] = []
	static func add(_ level: Int, _ msg: String)
	{
		q.async {
			lines.append("[\(level)] " + msg)
			if lines.count > 2000 { lines.removeFirst(lines.count - 2000) }
		}
		#if DEBUG
		print("[chiaki \(level)] \(msg)")
		#endif
	}
	static func text() -> String { q.sync { lines.joined(separator: "\n") } }
}
