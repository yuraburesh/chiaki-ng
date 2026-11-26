// AnyPlay для iPhone та iPad: якість картинки (як AnyPlayQuality.kt): «Авто» і три рівні.
// Усі iPhone та iPad з iOS 15 мають апаратний H.265, тож відео завжди H.265 (менше трафіку при тій самій якості).
import Foundation
import UIKit

struct VideoProfile
{
	let width: UInt32, height: UInt32, fps: UInt32, bitrate: UInt32
}

enum Quality
{
	static let levels: [(title: String, hint: String, w: UInt32, h: UInt32, fps: UInt32, kbps: UInt32)] = [
		("Економна", "540p, 30 кадрів: для слабкого або мобільного інтернету", 960, 540, 30, 6000),
		("Оптимальна", "720p, 60 кадрів: підходить більшості", 1280, 720, 60, 10000),
		("Максимальна", "1080p, 60 кадрів: потрібен швидкий Wi-Fi", 1920, 1080, 60, 15000)]

	private static let d = UserDefaults.standard

	static var auto: Bool
	{
		get { d.object(forKey: "auto_quality") as? Bool ?? true }
		set { d.set(newValue, forKey: "auto_quality"); d.removeObject(forKey: "auto_up") }
	}

	static var level: Int
	{
		get { (d.object(forKey: "quality_level") as? Int ?? 1).clamped(0, levels.count - 1) }
		set { d.set(newValue.clamped(0, levels.count - 1), forKey: "quality_level") }
	}

	static var name: String { (auto ? "Авто: " : "") + levels[level].title }

	static var profile: VideoProfile
	{
		let l = levels[level]
		return VideoProfile(width: l.w, height: l.h, fps: l.fps, bitrate: l.kbps)
	}

	/** Перед грою: якщо минулого разу все було стабільно, пробуємо рівень вище */
	static func prepare()
	{
		guard auto else { return }
		let now = Date().timeIntervalSince1970
		if d.bool(forKey: "auto_up") && level < levels.count - 1 && now > d.double(forKey: "auto_no_up_until")
		{
			level += 1
			d.set(now, forKey: "auto_raised_at")
		}
		d.removeObject(forKey: "auto_up")
	}

	/** Інтернет не тягне: рівень нижче. Повертає назву або nil */
	static func down() -> String?
	{
		guard auto, level > 0 else { return nil }
		let now = Date().timeIntervalSince1970
		d.removeObject(forKey: "auto_up")
		if now - d.double(forKey: "auto_raised_at") < 20 * 60 { d.set(now + 3 * 86400, forKey: "auto_no_up_until") }
		level -= 1
		return levels[level].title
	}

	static func good() { if auto { d.set(true, forKey: "auto_up") } }

	/** choice: -1 — «Авто», 0..2 — сталий рівень. true — змінилось */
	@discardableResult
	static func select(_ choice: Int) -> Bool
	{
		let before = (auto, level)
		if choice < 0 { auto = true } else { auto = false; level = choice }
		return before != (auto, level)
	}

	static var json: [String: Any]
	{
		["auto": auto, "level": level, "name": name, "levels": levels.map { ["title": $0.title, "hint": $0.hint] }]
	}
}

extension Comparable
{
	func clamped(_ lo: Self, _ hi: Self) -> Self { min(max(self, lo), hi) }
}

/** Налаштування, які на Android живуть у SharedPreferences: кольори, вібрація, статистика, кнопки */
enum Prefs
{
	static let d = UserDefaults.standard

	static var picture: [String: Any]
	{
		get { d.dictionary(forKey: "picture") ?? ["brightness": 0, "contrast": 0, "saturation": 0, "warmth": 0, "sharp": 0] }
		set { d.set(newValue, forKey: "picture") }
	}

	static var feel: [String: Any]
	{
		get { d.dictionary(forKey: "feel") ?? ["rumble": 2, "buttons": 1, "analog": false] }
		set { d.set(newValue, forKey: "feel") }
	}

	static var hud: Int
	{
		get { d.integer(forKey: "hud") }
		set { d.set(newValue.clamped(0, 2), forKey: "hud") }
	}

	/** Коли ховати екранні кнопки: -1 одразу (через 1 с), N секунд, 0 — ніколи */
	static var autoHide: Int
	{
		// 134: на iPad кнопки типово не ховаються (екран великий, а сховані кнопки там здавалися відсутніми)
		get { d.object(forKey: "autohide") as? Int ?? (UIDevice.current.userInterfaceIdiom == .pad ? 0 : -1) }
		set { d.set(newValue, forKey: "autohide") }
	}

	static var controls: Bool
	{
		get { d.object(forKey: "controls") as? Bool ?? true }
		set { d.set(newValue, forKey: "controls") }
	}
}
