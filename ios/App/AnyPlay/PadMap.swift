// AnyPlay 137 для iPhone та iPad: «Джойстик» — той самий малюнок DualSense, що на Android (PadMapView.kt) і комп'ютері.
// Кнопки, які є на екрані, світяться блакитним; торкнувся — кнопка ховається з екрана (на малюнку стає притиснутою,
// без світла), ще раз — з'являється. Тут же: окремі кнопки L3 і R3, розмір кнопок і прозорість у горизонтальному екрані.
import UIKit

final class PadMapView: UIView
{
	private struct Layer { let rect: CGRect; let src: String; let dark: String? }
	private struct Art { let floor: Layer, base: Layer, trig: [String: Layer], sh: [String: Layer], caps: [String: Layer], pressed: [String: Layer], glow: [String: Layer] }

	static let PW: CGFloat = 1084, PH: CGFloat = 733, TOP: CGFloat = 16

	/** Кнопка екрана → частини малюнка */
	static let parts: [String: [String]] = [
		"l2": ["L2"], "l1": ["L1"], "r2": ["R2"], "r1": ["R1"], "touchpad": ["TOUCHPAD"], "create": ["SHARE"], "options": ["OPTIONS"], "ps": ["PS"],
		"dpad": ["DPAD_UP", "DPAD_DOWN", "DPAD_LEFT", "DPAD_RIGHT"], "face": ["PYRAMID", "MOON", "CROSS", "BOX"],
		"lstick": ["L3"], "rstick": ["R3"]]

	static func idOf(_ part: String) -> String { parts.first { $0.value.contains(part) }?.key ?? "" }

	/** Назва кнопки екрана для підказки */
	static func title(_ id: String) -> String
	{
		["l2": "L2", "l1": "L1", "r2": "R2", "r1": "R1", "touchpad": "Тачпад", "create": "Create", "options": "Options", "ps": "PS",
		 "dpad": "Стрілки", "face": "✕ ○ □ △", "lstick": "Лівий стік", "rstick": "Правий стік"][id] ?? id
	}

	private static var cached: Art?
	private static var images: [String: UIImage] = [:]

	var hidden: Set<String> = [] { didSet { setNeedsDisplay() } }
	var onToggle: ((String) -> Void)?

	private var k: CGFloat = 1, ox: CGFloat = 0, oy: CGFloat = 0
	private var flash: [String: Date] = [:]
	private var link: CADisplayLink?

	override init(frame: CGRect)
	{
		super.init(frame: frame)
		isOpaque = false
		backgroundColor = .clear
		contentMode = .redraw
	}

	required init?(coder: NSCoder) { fatalError() }

	private static func load() -> Art?
	{
		if let a = cached { return a }
		guard let path = Bundle.main.path(forResource: "pad", ofType: "json", inDirectory: "web/pad"),
			let data = FileManager.default.contents(atPath: path),
			let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
		func num(_ v: Any?) -> CGFloat { CGFloat((v as? NSNumber)?.doubleValue ?? 0) }
		func layer(_ v: Any?) -> Layer?
		{
			guard let o = v as? [String: Any], let src = o["src"] as? String else { return nil }
			let dark = (o["dark"] as? String).flatMap { $0.isEmpty ? nil : $0 }
			return Layer(rect: CGRect(x: num(o["x"]), y: num(o["y"]), width: num(o["w"]), height: num(o["h"])), src: src, dark: dark)
		}
		func group(_ k: String) -> [String: Layer]
		{
			var out: [String: Layer] = [:]
			for (n, v) in j[k] as? [String: Any] ?? [:] { if let l = layer(v) { out[n] = l } }
			return out
		}
		guard let floor = layer(j["floor"]), let base = layer(j["base"]) else { return nil }
		let a = Art(floor: floor, base: base, trig: group("l2"), sh: group("sh"), caps: group("caps"), pressed: group("pressed"), glow: group("glow"))
		cached = a
		return a
	}

	private static func image(_ name: String) -> UIImage?
	{
		if let i = images[name] { return i }
		guard let p = Bundle.main.path(forResource: name, ofType: nil, inDirectory: "web/pad"), let i = UIImage(contentsOfFile: p) else { return nil }
		images[name] = i
		return i
	}

	override func layoutSubviews()
	{
		super.layoutSubviews()
		k = min(bounds.width / PadMapView.PW, bounds.height / PadMapView.PH)
		ox = (bounds.width - PadMapView.PW * k) / 2
		oy = (bounds.height - PadMapView.PH * k) / 2 + PadMapView.TOP * k
		setNeedsDisplay()
	}

	private func on(_ part: String) -> Bool { !hidden.contains(PadMapView.idOf(part)) }

	private func draw(_ l: Layer?, dark: Bool = false, alpha: CGFloat = 1)
	{
		guard let l = l, alpha > 0, let img = PadMapView.image(dark ? (l.dark ?? l.src) : l.src) else { return }
		let r = CGRect(x: ox + l.rect.minX * k, y: oy + l.rect.minY * k, width: l.rect.width * k, height: l.rect.height * k)
		img.draw(in: r, blendMode: .normal, alpha: min(alpha, 1))
	}

	override func draw(_ rect: CGRect)
	{
		guard let a = PadMapView.load() else { return }
		// як на комп'ютері: підлога, курки позаду корпусу, корпус, притиснуті кнопки, ковпачки стіків, світіння
		draw(a.floor)
		for n in ["L2", "R2"] { draw(a.trig[n], dark: !on(n)) }
		for n in ["L1", "R1"] { draw(a.sh[n], dark: !on(n)) }
		draw(a.base)
		for (n, l) in a.pressed where !on(n) { draw(l) }
		for n in ["L3", "R3"] { draw(a.caps[n], dark: !on(n)) }
		let now = Date()
		for (n, l) in a.glow
		{
			let f = flash[n].map { max(0, 1 - CGFloat(now.timeIntervalSince($0) / 0.42)) } ?? 0
			draw(l, alpha: max(on(n) ? 0.85 : 0, f))
		}
	}

	private func partAt(_ p: CGPoint) -> String?
	{
		guard let a = PadMapView.load() else { return nil }
		let px = (p.x - ox) / k, py = (p.y - oy) / k
		var best: (String, CGFloat)?
		for (n, l) in a.glow
		{
			guard l.rect.insetBy(dx: -14, dy: -14).contains(CGPoint(x: px, y: py)) else { continue }
			let d = hypot(px - l.rect.midX, py - l.rect.midY)
			if best == nil || d < best!.1 { best = (n, d) }
		}
		return best?.0
	}

	override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?)
	{
		guard let t = touches.first, let n = partAt(t.location(in: self)) else { return }
		let id = PadMapView.idOf(n)
		guard !id.isEmpty else { return }
		Haptics.shared.tap(n.hasPrefix("L") || n.hasPrefix("R") ? .click : .tick)
		// спалах на всю групу: ✕○□△ чи всі стрілки ховаються разом
		let now = Date()
		for p in PadMapView.parts[id] ?? [n] { flash[p] = now }
		startFlash()
		onToggle?(id)
	}

	private func startFlash()
	{
		guard link == nil else { return }
		let l = CADisplayLink(target: self, selector: #selector(tick))
		l.add(to: .main, forMode: .common)
		link = l
	}

	@objc private func tick()
	{
		let now = Date()
		flash = flash.filter { now.timeIntervalSince($0.value) < 0.42 }
		if flash.isEmpty { link?.invalidate(); link = nil }
		setNeedsDisplay()
	}

	override func removeFromSuperview()
	{
		link?.invalidate(); link = nil
		super.removeFromSuperview()
	}
}

/** Екран «Джойстик»: які кнопки на екрані, L3/R3, розмір і прозорість. onClose — оновити кнопки в грі */
final class PadSettingsViewController: UIViewController
{
	var onClose: (() -> Void)?

	private let ink = UIColor(red: 232 / 255, green: 229 / 255, blue: 242 / 255, alpha: 1)
	private let muted = UIColor(red: 170 / 255, green: 164 / 255, blue: 196 / 255, alpha: 1)
	private let accent = UIColor(red: 143 / 255, green: 227 / 255, blue: 1, alpha: 1)
	private let card = UIColor(red: 0x36 / 255.0, green: 0x31 / 255.0, blue: 0x50 / 255.0, alpha: 1)

	private let map = PadMapView()
	private let note = UILabel()
	private let panel = UIStackView()
	private let l3 = UISwitch()
	private let size = UISlider()
	private let opacity = UISlider()
	private let sizeValue = UILabel()
	private let opacityValue = UILabel()
	private var wide: [NSLayoutConstraint] = []
	private var tall: [NSLayoutConstraint] = []

	init()
	{
		super.init(nibName: nil, bundle: nil)
		modalPresentationStyle = .fullScreen
	}

	required init?(coder: NSCoder) { fatalError() }

	override var prefersStatusBarHidden: Bool { true }

	private func label(_ text: String, _ size: CGFloat, _ color: UIColor, bold: Bool = false) -> UILabel
	{
		let l = UILabel()
		l.text = text
		l.textColor = color
		l.font = .systemFont(ofSize: size, weight: bold ? .bold : .regular)
		l.numberOfLines = 0
		return l
	}

	private func button(_ title: String, filled: Bool, _ action: Selector) -> UIButton
	{
		let b = UIButton(type: .system)
		b.setTitle(title, for: .normal)
		b.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
		b.titleLabel?.lineBreakMode = .byTruncatingTail
		b.setTitleColor(filled ? UIColor(red: 0x1b / 255.0, green: 0x18 / 255.0, blue: 0x2b / 255.0, alpha: 1) : ink, for: .normal)
		b.backgroundColor = filled ? accent : card
		b.layer.cornerRadius = 12
		b.heightAnchor.constraint(equalToConstant: 46).isActive = true
		b.addTarget(self, action: action, for: .touchUpInside)
		return b
	}

	private func row(_ title: String, _ sub: String, _ control: UIView) -> UIView
	{
		let t = label(title, 16, ink, bold: true)
		let s = label(sub, 13, muted)
		let text = UIStackView(arrangedSubviews: [t, s])
		text.axis = .vertical
		text.spacing = 3
		let h = UIStackView(arrangedSubviews: [text, control])
		h.alignment = .center
		h.spacing = 12
		control.setContentHuggingPriority(.required, for: .horizontal)
		control.setContentCompressionResistancePriority(.required, for: .horizontal)
		return box(h)
	}

	private func slider(_ title: String, _ s: UISlider, _ value: UILabel, _ min: Float, _ max: Float) -> UIView
	{
		s.minimumValue = min
		s.maximumValue = max
		s.minimumTrackTintColor = accent
		s.addTarget(self, action: #selector(slid), for: .valueChanged)
		value.textColor = accent
		value.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
		value.textAlignment = .right
		value.widthAnchor.constraint(equalToConstant: 54).isActive = true
		let top = UIStackView(arrangedSubviews: [label(title, 16, ink, bold: true), value])
		let v = UIStackView(arrangedSubviews: [top, s])
		v.axis = .vertical
		v.spacing = 8
		return box(v)
	}

	private func box(_ content: UIView) -> UIView
	{
		let b = UIView()
		b.backgroundColor = card
		b.layer.cornerRadius = 14
		content.translatesAutoresizingMaskIntoConstraints = false
		b.addSubview(content)
		NSLayoutConstraint.activate([
			content.topAnchor.constraint(equalTo: b.topAnchor, constant: 12), content.bottomAnchor.constraint(equalTo: b.bottomAnchor, constant: -12),
			content.leadingAnchor.constraint(equalTo: b.leadingAnchor, constant: 14), content.trailingAnchor.constraint(equalTo: b.trailingAnchor, constant: -14)])
		return b
	}

	override func viewDidLoad()
	{
		super.viewDidLoad()
		view.backgroundColor = UIColor(red: 0x2b / 255.0, green: 0x27 / 255.0, blue: 0x40 / 255.0, alpha: 1)

		let title = label("ДЖОЙСТИК", 22, ink, bold: true)
		title.textAlignment = .center
		note.textColor = muted
		note.font = .systemFont(ofSize: 14)
		note.numberOfLines = 0
		note.textAlignment = .center
		note.text = "Торкнись кнопки на малюнку, щоб сховати її з екрана або повернути. Блакитне світіння — кнопка є на екрані."

		map.hidden = Prefs.padHidden
		map.onToggle = { [weak self] id in self?.toggle(id) }
		map.translatesAutoresizingMaskIntoConstraints = false

		l3.onTintColor = accent
		l3.isOn = Prefs.padL3R3
		l3.addTarget(self, action: #selector(l3Changed), for: .valueChanged)
		size.value = Float(Prefs.padScale)
		opacity.value = Float(Prefs.padAlpha)

		let actions = UIStackView(arrangedSubviews: [button("Скинути", filled: false, #selector(reset)), button("Готово", filled: true, #selector(done))])
		actions.spacing = 10
		actions.distribution = .fillEqually

		for v in [row("Окремі кнопки L3 і R3", "L3 і R3 — натиснути стік. Без окремих кнопок: торкнись стіка двічі й тримай другий дотик.", l3),
			slider("Розмір кнопок", size, sizeValue, 0.7, 1.5),
			slider("Прозорість кнопок поверх гри", opacity, opacityValue, 0.3, 1), actions] { panel.addArrangedSubview(v) }
		panel.axis = .vertical
		panel.spacing = 10
		panel.translatesAutoresizingMaskIntoConstraints = false

		let scroll = UIScrollView()
		scroll.translatesAutoresizingMaskIntoConstraints = false
		scroll.alwaysBounceVertical = false
		scroll.addSubview(panel)
		let head = UIStackView(arrangedSubviews: [title, note])
		head.axis = .vertical
		head.spacing = 6
		head.translatesAutoresizingMaskIntoConstraints = false
		view.addSubview(head)
		view.addSubview(map)
		view.addSubview(scroll)
		let g = view.safeAreaLayoutGuide
		let side: CGFloat = 16
		NSLayoutConstraint.activate([
			head.topAnchor.constraint(equalTo: g.topAnchor, constant: 12),
			head.centerXAnchor.constraint(equalTo: g.centerXAnchor),
			head.widthAnchor.constraint(lessThanOrEqualToConstant: 620),
			head.leadingAnchor.constraint(greaterThanOrEqualTo: g.leadingAnchor, constant: side),
			panel.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
			panel.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
			panel.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor),
			panel.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor),
			scroll.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -12)])
		// горизонтально: малюнок ліворуч, налаштування праворуч; вертикально — малюнок над налаштуваннями
		wide = [
			map.topAnchor.constraint(equalTo: head.bottomAnchor, constant: 12),
			map.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: side),
			map.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -12),
			map.trailingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: -20),
			scroll.topAnchor.constraint(equalTo: head.bottomAnchor, constant: 12),
			scroll.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -side),
			scroll.widthAnchor.constraint(equalTo: g.widthAnchor, multiplier: 0.38)]
		tall = [
			map.topAnchor.constraint(equalTo: head.bottomAnchor, constant: 10),
			map.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: side),
			map.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -side),
			map.heightAnchor.constraint(equalTo: map.widthAnchor, multiplier: PadMapView.PH / PadMapView.PW),
			scroll.topAnchor.constraint(equalTo: map.bottomAnchor, constant: 14),
			scroll.centerXAnchor.constraint(equalTo: g.centerXAnchor),
			scroll.widthAnchor.constraint(equalToConstant: 560).withPriority(.defaultHigh),
			scroll.leadingAnchor.constraint(greaterThanOrEqualTo: g.leadingAnchor, constant: side)]
		updateValues()
	}

	override func viewWillLayoutSubviews()
	{
		super.viewWillLayoutSubviews()
		let isWide = view.bounds.width > view.bounds.height
		NSLayoutConstraint.deactivate(isWide ? tall : wide)
		NSLayoutConstraint.activate(isWide ? wide : tall)
	}

	private func toggle(_ id: String)
	{
		var h = Prefs.padHidden
		let hide = !h.contains(id)
		if hide { h.insert(id) } else { h.remove(id) }
		Prefs.padHidden = h
		map.hidden = h
		note.text = "\(PadMapView.title(id)): " + (hide ? "сховано з екрана. Торкнись ще раз, щоб повернути." : "знову на екрані.")
	}

	private func updateValues()
	{
		sizeValue.text = "\(Int((size.value * 100).rounded()))%"
		opacityValue.text = "\(Int((opacity.value * 100).rounded()))%"
	}

	@objc private func slid()
	{
		Prefs.padScale = Double(size.value)
		Prefs.padAlpha = Double(opacity.value)
		updateValues()
	}

	@objc private func l3Changed() { Prefs.padL3R3 = l3.isOn; Haptics.shared.tap(.click) }

	@objc private func reset()
	{
		Prefs.padHidden = []
		Prefs.padL3R3 = false
		Prefs.padScale = 1
		Prefs.padAlpha = 0.7
		map.hidden = []
		l3.setOn(false, animated: true)
		size.setValue(1, animated: true)
		opacity.setValue(0.7, animated: true)
		updateValues()
		note.text = "Усі кнопки на екрані, розмір і прозорість — типові."
	}

	@objc private func done() { dismiss(animated: true) { self.onClose?() } }
}

private extension NSLayoutConstraint
{
	func withPriority(_ p: UILayoutPriority) -> NSLayoutConstraint { priority = p; return self }
}
