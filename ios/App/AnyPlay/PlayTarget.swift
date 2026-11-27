// AnyPlay для iPhone та iPad: з відповіді /api/app/session (state == "play") — усе для з'єднання з PS5 через PSN
// (як AnyPlayCloud.findTarget на Android): ключ PSN, акаунт, приставка зі списку акаунта Sony.
import Foundation
import AnyPlayCore

struct PlayReady
{
	let token: String
	let accountId: [UInt8]
	let duid: String
	let guest: Bool
	// 136: приставка в домашній мережі — напряму за адресою, ключами прив'язки (без PSN)
	var lanAddr: String? = nil
	var registKey: [UInt8] = []
	var morning: [UInt8] = []
}

enum PlayTarget
{
	case ready(PlayReady)
	case error(String, String)

	/** Блокує потік: питає Sony про приставки акаунта */
	static func find(_ session: [String: Any]) -> PlayTarget
	{
		guard let console = session["console"] as? [String: Any] else
		{ return .error("Сервер не передав приставку. Спробуй ще раз за хвилину.", "AP-NO-CONSOLE") }
		let remote = console["remote"] as? [String: Any] ?? [:]
		let token = remote["auth_token"] as? String ?? ""
		let account = Data(base64Encoded: remote["account_id"] as? String ?? "").map { [UInt8]($0) } ?? []
		let guest = session["guest"] as? Bool ?? false
		if let lan = lanTarget(console["host"] as? [String: Any] ?? [:], guest: guest) { return .ready(lan) }
		if token.isEmpty || account.count != 8
		{ return .error("Вхід у PSN для цієї приставки ще не готовий. Напиши в підтримку через бота.", "AP-NO-PSN") }
		CA.ensure()
		let nickname = (console["host"] as? [String: Any])?["server_nickname"] as? String ?? ""
		var list = devices(token)
		if list == nil { list = devices(token) }   // один повтор: мережа часто «прокидається» не одразу
		guard let all = list else
		{ return .error("Sony зараз не відповідає. Спробуй ще раз за хвилину. Якщо повторюється, напиши в підтримку через бота.", "PSN-LIST") }
		let enabled = all.filter { $0.rp }
		guard let dev = enabled.first(where: { $0.name == nickname }) ?? enabled.first else
		{
			return all.isEmpty
				? .error("Приставку не знайдено в акаунті PSN. Напиши в підтримку через бота.", "PSN-LIST 0 PS5")
				: .error("На приставці вимкнено дистанційне відтворення або вона вимкнена повністю. Напиши в підтримку через бота.", "PSN-LIST RP off")
		}
		return .ready(PlayReady(token: token, accountId: account, duid: dev.duid, guest: session["guest"] as? Bool ?? false))
	}

	/** 136: телефон у тій самій мережі, що й приставка — підключення напряму, як на комп'ютері (за секунди) */
	private static func lanTarget(_ host: [String: Any], guest: Bool) -> PlayReady?
	{
		func b64(_ k: String) -> [UInt8] { Data(base64Encoded: host[k] as? String ?? "").map { [UInt8]($0) } ?? [] }
		let regist = b64("rp_regist_key"), morning = b64("rp_key"), mac = b64("server_mac")
		guard regist.count == 16, morning.count == 16, mac.count == 6 else { return nil }
		let macHex = mac.map { String(format: "%02X", $0) }.joined()
		let keyText = String(decoding: regist.prefix { $0 != 0 }, as: UTF8.self)
		var buf = [CChar](repeating: 0, count: 64)
		let started = Date()
		let r = anyplay_core_lan_find(macHex, keyText, 1200, 20000, &buf, buf.count)
		let ms = Int(Date().timeIntervalSince(started) * 1000)
		if r != 0
		{
			Log.add(2, "Домашня мережа: приставки не знайдено (\(r), \(ms) мс), підключення через PSN")
			return nil
		}
		let addr = String(cString: buf)
		Log.add(2, "Домашня мережа: приставка \(addr) поруч, підключаємось напряму (пошук \(ms) мс)")
		return PlayReady(token: "", accountId: [], duid: "", guest: guest, lanAddr: addr, registKey: regist, morning: morning)
	}

	private static func devices(_ token: String) -> [(duid: String, name: String, rp: Bool)]?
	{
		var buf = [CChar](repeating: 0, count: 16384)
		let err = anyplay_core_psn_devices(token, &buf, buf.count)
		if err != 0 { return nil }
		let text = String(cString: buf)
		var out: [(String, String, Bool)] = []
		for line in text.split(separator: "\n").dropFirst() {
			let p = line.split(separator: "\t", omittingEmptySubsequences: false)
			if p.count >= 3 { out.append((String(p[0]), String(p[1]), p[2] == "1")) }
		}
		return out
	}
}
