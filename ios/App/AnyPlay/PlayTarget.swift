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

	private static func devices(_ token: String) -> [(duid: String, name: String, rp: Bool)]?
	{
		var buf = [CChar](repeating: 0, count: 16384)
		let err = anyplay_core_psn_devices(token, &buf, buf.count)
		if err != 0 { return nil }
		let text = String(cString: buf)
		var out: [(String, String, Bool)] = []
		for line in text.split(separator: "\n").dropFirst()
		{
			let p = line.split(separator: "\t", omittingEmptySubsequences: false)
			if p.count >= 3 { out.append((String(p[0]), String(p[1]), p[2] == "1")) }
		}
		return out
	}
}
