// AnyPlay для iPhone та iPad: запити до сервера AnyPlay (те саме, що AnyPlayCloud.kt на Android)
import Foundation
import AnyPlayCore
import UIKit

struct CloudResult
{
	let status: Int
	let json: [String: Any]
	var ok: Bool { status >= 200 && status < 300 }
	func str(_ k: String) -> String { json[k] as? String ?? "" }
	func obj(_ k: String) -> [String: Any]? { json[k] as? [String: Any] }
}

enum Cloud
{
	static let server = "https://34-123-25-16.sslip.io"
	static let botURL = "https://t.me/play_any_bot"
	static var build: Int { Int(Bundle.main.object(forInfoDictionaryKey: "AnyPlayBuild") as? String ?? "") ?? 1 }

	static var token: String
	{
		get { UserDefaults.standard.string(forKey: "device_token") ?? "" }
		set { UserDefaults.standard.set(newValue, forKey: "device_token") }
	}

	static var deviceName: String
	{
		let d = UIDevice.current
		return d.userInterfaceIdiom == .pad ? "iPad (\(d.systemVersion))" : "iPhone (\(d.systemVersion))"
	}

	/** Запит до сервера. status 0 — немає зв'язку */
	static func request(_ method: String, _ path: String, body: [String: Any]? = nil, auth: Bool = true) async -> CloudResult
	{
		guard let url = URL(string: server + path) else { return CloudResult(status: 0, json: [:]) }
		var r = URLRequest(url: url, timeoutInterval: 15)
		r.httpMethod = method
		r.setValue("application/json", forHTTPHeaderField: "Content-Type")
		r.setValue(String(build), forHTTPHeaderField: "X-AnyPlay-Build")
		r.setValue("ios", forHTTPHeaderField: "X-AnyPlay-Platform")
		if auth && !token.isEmpty { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
		if method != "GET" { r.httpBody = try? JSONSerialization.data(withJSONObject: body ?? [:]) }
		do
		{
			let (data, resp) = try await URLSession.shared.data(for: r)
			let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
			let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
			return CloudResult(status: status, json: json)
		}
		catch { return CloudResult(status: 0, json: [:]) }
	}

	/** Те саме, але тіло й відповідь — текст JSON (для сторінки) */
	static func requestRaw(_ method: String, _ path: String, body: String) async -> (Int, String)
	{
		let obj = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
		let r = await request(method, path, body: method == "GET" ? nil : (obj ?? [:]))
		let text = (try? JSONSerialization.data(withJSONObject: r.json)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
		return (r.status, text)
	}

	static func pairStart() async -> CloudResult
	{
		await request("POST", "/api/app/pair", body: ["name": deviceName, "platform": "ios", "build": build], auth: false)
	}

	static func pairPoll(_ code: String) async -> CloudResult
	{
		await request("GET", "/api/app/pair?code=" + (code.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? code), auth: false)
	}

	static func session() async -> CloudResult { await request("GET", "/api/app/session") }

	static func heartbeat(streaming: Bool, stats: [String: Any]? = nil) async -> CloudResult
	{
		var body: [String: Any] = ["streaming": streaming]
		if let s = stats { body["stats"] = s }
		return await request("POST", "/api/app/heartbeat", body: body)
	}

	/** Шляхи, які сторінка може просити від імені пристрою (як ANYPLAY_REQ_PATHS на Android) */
	static let pagePaths = ["/api/app/", "/api/miniapp/friends", "/api/live/handoff"]
}

/** Файл кореневих сертифікатів для HTTPS-запитів рідної бібліотеки до Sony (PSN) */
enum CA
{
	static var ready = false
	static func ensure()
	{
		if ready { return }
		if let path = Bundle.main.path(forResource: "cacert", ofType: "pem")
		{
			anyplay_core_set_ca_bundle(path)
			ready = true
		}
	}
}
