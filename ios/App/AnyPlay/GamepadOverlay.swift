// AnyPlay для iPhone та iPad: екранний геймпад DualSense (як GamepadView.kt на Android, у першій версії без редактора).
// Горизонтально кнопки поверх гри й плавно згасають за секунду після того, як прибрав пальці; вертикально — під картинкою.
// Стіки горизонтально з'являються там, де поставив палець. L3/R3 — окремі кнопки або подвійний дотик до стіка.
import UIKit

final class GamepadOverlay: UIView
{
	var onChange: ((PadState) -> Void)?
	var onMenu: (() -> Void)?
	/** Нижній край картинки у вертикальному режимі (кнопки йдуть нижче) */
	var videoBottom: CGFloat = 0 { didSet { setNeedsLayout() } }

	private enum Kind { case trigger, shoulder, face, dpad, stick, small, ps, menu, touchpad, click }

	private final class Item
	{
		let id: String, kind: Kind
		var center = CGPoint.zero, size = CGSize.zero
		var frame: CGRect { CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height) }
		init(_ id: String, _ kind: Kind) { self.id = id; self.kind = kind }
	}

	private struct Stick { var origin = CGPoint.zero, dx: CGFloat = 0, dy: CGFloat = 0, touch: UITouch?, lastUp = Date.distantPast, click = false, edge = false }

	private let items: [Item] = [
		Item("l2", .trigger), Item("l1", .shoulder), Item("r2", .trigger), Item("r1", .shoulder), Item("touchpad", .touchpad),
		Item("dpad", .dpad), Item("face", .face), Item("lstick", .stick), Item("rstick", .stick), Item("l3", .click), Item("r3", .click),
		Item("create", .small), Item("ps", .ps), Item("options", .small), Item("menu", .menu)]

	// типові місця (частки області кнопок), як PadLayout.defaults на Android
	private let land: [String: CGPoint] = ["l2": .init(x: 0.075, y: 0.09), "l1": .init(x: 0.075, y: 0.205), "r2": .init(x: 0.925, y: 0.09), "r1": .init(x: 0.925, y: 0.205),
		"touchpad": .init(x: 0.5, y: 0.075), "dpad": .init(x: 0.11, y: 0.52), "face": .init(x: 0.89, y: 0.52), "lstick": .init(x: 0.29, y: 0.77), "rstick": .init(x: 0.71, y: 0.77),
		"l3": .init(x: 0.12, y: 0.9), "r3": .init(x: 0.88, y: 0.9), "create": .init(x: 0.41, y: 0.92), "ps": .init(x: 0.5, y: 0.92), "options": .init(x: 0.59, y: 0.92), "menu": .init(x: 0.965, y: 0.92)]
	private let port: [String: CGPoint] = ["l2": .init(x: 0.13, y: 0.07), "l1": .init(x: 0.13, y: 0.17), "r2": .init(x: 0.87, y: 0.07), "r1": .init(x: 0.87, y: 0.17),
		"touchpad": .init(x: 0.5, y: 0.08), "dpad": .init(x: 0.22, y: 0.42), "face": .init(x: 0.78, y: 0.42), "lstick": .init(x: 0.28, y: 0.72), "rstick": .init(x: 0.72, y: 0.72),
		"l3": .init(x: 0.08, y: 0.6), "r3": .init(x: 0.92, y: 0.6), "create": .init(x: 0.37, y: 0.91), "ps": .init(x: 0.5, y: 0.91), "options": .init(x: 0.63, y: 0.91), "menu": .init(x: 0.08, y: 0.91)]

	private func base(_ k: Kind) -> CGSize
	{
		switch k
		{
		case .trigger, .shoulder: return CGSize(width: 60, height: 32)
		case .touchpad: return CGSize(width: 112, height: 34)
		case .dpad: return CGSize(width: 92, height: 92)
		case .face: return CGSize(width: 108, height: 108)
		case .stick: return CGSize(width: 88, height: 88)
		case .small: return CGSize(width: 30, height: 28)
		case .ps: return CGSize(width: 32, height: 32)
		case .menu: return CGSize(width: 34, height: 34)
		case .click: return CGSize(width: 40, height: 40)
		}
	}

	private var area = CGRect.zero
	// 137: «Джойстик» — сховані кнопки й окремі L3/R3
	private var hiddenIds: Set<String> = []
	private func vis(_ id: String) -> Bool
	{
		if id == "menu" { return true }
		if id == "l3" || id == "r3" { return Prefs.padL3R3 && !hiddenIds.contains(id) }
		return !hiddenIds.contains(id)
	}

	/** Налаштування «Джойстика» змінились */
	func reloadPrefs()
	{
		releaseAll()
		setNeedsLayout()
	}
	private var landscape: Bool { bounds.width > bounds.height }

	// натиснуте
	private var keyTouches: [UITouch: String] = [:]   // кнопка: "cross", "l2" тощо
	private var dpadTouch: UITouch?
	private var dpadMask: UInt32 = 0
	private var sticks = [Stick(), Stick()]
	private var triggerLevel: [String: CGFloat] = [:]
	private var triggerStartY: [String: CGFloat] = [:]
	private var touchpadTouch: UITouch?
	private var touchpadPressedUntil = Date.distantPast
	var onTouchpad: ((Int, UInt16, UInt16, Bool) -> Int)?   // id, x, y, up → новий id
	private var touchpadId = -1
	private var touchpadDownAt = Date.distantPast
	private var touchpadDownPoint = CGPoint.zero
	private var hideWork: DispatchWorkItem?

	override init(frame: CGRect)
	{
		super.init(frame: frame)
		isMultipleTouchEnabled = true
		isOpaque = false
		backgroundColor = .clear
		contentMode = .redraw
	}

	required init?(coder: NSCoder) { fatalError() }

	override func layoutSubviews()
	{
		super.layoutSubviews()
		let safe = safeAreaInsets
		if landscape
		{ area = bounds.inset(by: UIEdgeInsets(top: 0, left: safe.left, bottom: safe.bottom, right: safe.right)) }
		else
		{
			let top = min(videoBottom, bounds.height * 0.6)
			area = CGRect(x: 0, y: top, width: bounds.width, height: bounds.height - top - safe.bottom)
		}
		let unit0: CGFloat = landscape ? (min(bounds.width, bounds.height) / 380).clamped(0.85, 1.35)
			: min(bounds.width / 380 * 1.1, area.height / 450).clamped(0.7, 1.4)
		hiddenIds = Prefs.padHidden
		let map = landscape ? land : port
		let unit = unit0 * CGFloat(Prefs.padScale)
		for it in items
		{
			let p = map[it.id] ?? .init(x: 0.5, y: 0.5)
			let s = base(it.kind)
			it.size = CGSize(width: s.width * unit, height: s.height * unit)
			let x = area.minX + p.x * area.width, y = area.minY + p.y * area.height
			it.center = CGPoint(x: x.clamped(area.minX + it.size.width / 2, area.maxX - it.size.width / 2),
				y: y.clamped(area.minY + it.size.height / 2, area.maxY - it.size.height / 2))
		}
		for i in 0..<2 where sticks[i].touch == nil { sticks[i].origin = item(i == 0 ? "lstick" : "rstick").center }
		setNeedsDisplay()
		scheduleHide()
	}

	private func item(_ id: String) -> Item { items.first { $0.id == id }! }

	// ── малювання ──
	private var alphaK: CGFloat { solid ? 1 : CGFloat(Prefs.padAlpha) }
	/** 128: вертикально кнопки на власному тлі під картинкою — щільні й об'ємні, як на геймпаді, символи кольорові як на DualShock 4 */
	private var solid: Bool { !landscape }
	private let accent = UIColor(red: 143 / 255, green: 227 / 255, blue: 1, alpha: 1)
	private let solidInk = UIColor(red: 232 / 255, green: 229 / 255, blue: 242 / 255, alpha: 1)
	private func faceColor(_ k: String) -> UIColor
	{
		switch k
		{
		case "pyramid": return UIColor(red: 64 / 255, green: 226 / 255, blue: 170 / 255, alpha: 1)
		case "moon": return UIColor(red: 1, green: 92 / 255, blue: 108 / 255, alpha: 1)
		case "cross": return UIColor(red: 122 / 255, green: 170 / 255, blue: 1, alpha: 1)
		default: return UIColor(red: 246 / 255, green: 140 / 255, blue: 220 / 255, alpha: 1)
		}
	}

	override func draw(_ rect: CGRect)
	{
		guard let ctx = UIGraphicsGetCurrentContext() else { return }
		if !landscape
		{
			// тло як матовий корпус геймпада, тонка світла смуга під картинкою
			let bg = CGRect(x: 0, y: area.minY, width: bounds.width, height: bounds.height - area.minY)
			let colors = [UIColor(red: 40 / 255, green: 36 / 255, blue: 58 / 255, alpha: 1).cgColor, UIColor(red: 22 / 255, green: 20 / 255, blue: 33 / 255, alpha: 1).cgColor] as CFArray
			if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])
			{
				ctx.saveGState(); ctx.clip(to: bg)
				ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: bg.minY), end: CGPoint(x: 0, y: bg.maxY), options: [])
				ctx.restoreGState()
			}
			accent.withAlphaComponent(0.35).setFill()
			UIRectFill(CGRect(x: 0, y: area.minY, width: bounds.width, height: 1.5))
		}
		for it in items where vis(it.id)
		{
			switch it.kind
			{
			case .trigger, .shoulder, .small, .touchpad:
				let pressed = isPressed(it.id)
				let r = it.kind == .small ? it.frame.insetBy(dx: it.size.width * 0.2, dy: 0) : it.frame
				body(ctx, UIBezierPath(roundedRect: r, cornerRadius: r.height * (it.kind == .touchpad ? 0.3 : 0.45)), pressed)
				if it.kind == .trigger, let lv = triggerLevel[it.id], pressed, lv < 0.999
				{
					ctx.saveGState()
					ctx.clip(to: CGRect(x: r.minX, y: r.maxY - r.height * lv, width: r.width, height: r.height * lv))
					UIColor(red: 143 / 255, green: 227 / 255, blue: 1, alpha: 0.5).setFill()
					UIBezierPath(roundedRect: r, cornerRadius: r.height * 0.45).fill()
					ctx.restoreGState()
				}
				let label = ["l2": "L2", "l1": "L1", "r2": "R2", "r1": "R1", "create": "", "options": "", "touchpad": ""][it.id] ?? ""
				if !label.isEmpty { text(label, it.center, r.height * 0.46) }
				if it.id == "options" { for i in -1...1 { line(ctx, CGPoint(x: it.center.x - r.width * 0.26, y: it.center.y + CGFloat(i) * r.height * 0.17), CGPoint(x: it.center.x + r.width * 0.26, y: it.center.y + CGFloat(i) * r.height * 0.17)) } }
				if it.id == "create" { line(ctx, CGPoint(x: it.center.x, y: it.center.y + r.height * 0.15), CGPoint(x: it.center.x, y: it.center.y - r.height * 0.18)) }
			case .ps, .menu, .click:
				let pressed = isPressed(it.id)
				body(ctx, UIBezierPath(ovalIn: it.frame), pressed)
				if it.kind == .ps { text("PS", it.center, it.size.height * 0.4) }
				else if it.kind == .click { text(it.id == "l3" ? "L3" : "R3", it.center, it.size.height * 0.32) }
				else { for i in -1...1 { UIColor.white.withAlphaComponent(0.9 * alphaK).setFill(); UIBezierPath(ovalIn: CGRect(x: it.center.x + CGFloat(i) * it.size.width * 0.21 - 2, y: it.center.y - 2, width: 4, height: 4)).fill() } }
			case .face:
				let off = it.size.width * 0.34, r = it.size.width * 0.165
				for (k, dx, dy) in [("pyramid", 0.0, -1.0), ("moon", 1.0, 0.0), ("cross", 0.0, 1.0), ("box", -1.0, 0.0)]
				{
					let c = CGPoint(x: it.center.x + CGFloat(dx) * off, y: it.center.y + CGFloat(dy) * off)
					body(ctx, UIBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), isPressed(k))
					glyph(ctx, k, c, r * 0.42, color: solid ? faceColor(k) : nil)
				}
			case .dpad:
				let r = it.size.width / 2, half = r * 0.27
				for (i, bit) in [Btn.up, Btn.right, Btn.down, Btn.left].enumerated() {
					ctx.saveGState()
					ctx.translateBy(x: it.center.x, y: it.center.y)
					ctx.rotate(by: CGFloat(i) * .pi / 2)
					let p = UIBezierPath(roundedRect: CGRect(x: -half, y: -r * 0.98, width: 2 * half, height: r * 0.54), cornerRadius: half * 0.5)
					body(ctx, p, dpadMask & bit != 0)
					line(ctx, CGPoint(x: -half * 0.42, y: -r * 0.66), CGPoint(x: 0, y: -r * 0.78))
					line(ctx, CGPoint(x: half * 0.42, y: -r * 0.66), CGPoint(x: 0, y: -r * 0.78))
					ctx.restoreGState()
				}
			case .stick:
				let i = it.id == "lstick" ? 0 : 1
				let s = sticks[i], ring = it.size.width / 2, knob = ring * 0.55
				let active = s.touch != nil
				// 141: горизонтально стік з'являється під пальцем, коли торкнувся, і зникає, коли відпустив
				if landscape && !active { continue }
				if solid { solidStick(ctx, s, ring, knob, active); continue }
				UIColor.white.withAlphaComponent((active ? 0.18 : 0.1) * alphaK).setFill()
				let ringPath = UIBezierPath(ovalIn: CGRect(x: s.origin.x - ring, y: s.origin.y - ring, width: 2 * ring, height: 2 * ring))
				ringPath.fill()
				UIColor.white.withAlphaComponent((active ? 0.8 : 0.47) * alphaK).setStroke(); ringPath.lineWidth = 1.2; ringPath.stroke()
				let travel = ring - knob * 0.8
				let k = CGPoint(x: s.origin.x + s.dx * travel, y: s.origin.y + s.dy * travel)
				body(ctx, UIBezierPath(ovalIn: CGRect(x: k.x - knob, y: k.y - knob, width: 2 * knob, height: 2 * knob)), s.click)
			}
		}
	}

	/** Об'ємна кнопка: тінь знизу, світло зверху ліворуч, натиснута — нижче, темніша, з кільцем підсвітки */
	private func solidBody(_ ctx: CGContext, _ p: UIBezierPath, _ pressed: Bool)
	{
		let b = p.bounds
		ctx.saveGState()
		ctx.translateBy(x: 0, y: pressed ? 0.6 : 2.2)
		UIColor(white: 0, alpha: pressed ? 0.35 : 0.6).setFill()
		p.fill()
		ctx.restoreGState()
		let hi = pressed ? UIColor(red: 52 / 255, green: 48 / 255, blue: 70 / 255, alpha: 1) : UIColor(red: 78 / 255, green: 74 / 255, blue: 98 / 255, alpha: 1)
		let lo = pressed ? UIColor(red: 24 / 255, green: 21 / 255, blue: 34 / 255, alpha: 1) : UIColor(red: 30 / 255, green: 27 / 255, blue: 42 / 255, alpha: 1)
		if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [hi.cgColor, lo.cgColor] as CFArray, locations: [0, 1])
		{
			ctx.saveGState(); ctx.addPath(p.cgPath); ctx.clip()
			ctx.drawLinearGradient(g, start: CGPoint(x: b.minX, y: b.minY), end: CGPoint(x: b.minX + b.width * 0.35, y: b.maxY), options: [])
			ctx.restoreGState()
		}
		if pressed { accent.withAlphaComponent(0.28).setStroke(); p.lineWidth = 4.5; p.stroke() }
		(pressed ? accent : UIColor(white: 1, alpha: 0.18)).setStroke()
		p.lineWidth = 1.1
		p.stroke()
	}

	/** Стік як на геймпаді: заглиблення в корпусі й гумовий ковпачок з увігнутою серединою */
	private func solidStick(_ ctx: CGContext, _ s: Stick, _ ring: CGFloat, _ knob: CGFloat, _ active: Bool)
	{
		let well = UIBezierPath(ovalIn: CGRect(x: s.origin.x - ring, y: s.origin.y - ring, width: 2 * ring, height: 2 * ring))
		UIColor(red: 16 / 255, green: 14 / 255, blue: 25 / 255, alpha: 1).setFill(); well.fill()
		(active ? accent.withAlphaComponent(0.6) : UIColor(white: 1, alpha: 0.14)).setStroke(); well.lineWidth = 1.1; well.stroke()
		let travel = ring - knob * 0.8
		let k = CGPoint(x: s.origin.x + s.dx * travel, y: s.origin.y + s.dy * travel)
		let cap = UIBezierPath(ovalIn: CGRect(x: k.x - knob, y: k.y - knob, width: 2 * knob, height: 2 * knob))
		solidBody(ctx, cap, s.click)
		let dish = UIBezierPath(ovalIn: CGRect(x: k.x - knob * 0.7, y: k.y - knob * 0.7, width: 1.4 * knob, height: 1.4 * knob))
		UIColor(red: 38 / 255, green: 35 / 255, blue: 52 / 255, alpha: 1).setFill(); dish.fill()
		UIColor(white: 1, alpha: 0.1).setStroke(); dish.lineWidth = 1; dish.stroke()
		if active && !s.click { accent.setStroke(); cap.lineWidth = 1.2; cap.stroke() }
	}

	private func body(_ ctx: CGContext, _ p: UIBezierPath, _ pressed: Bool)
	{
		if solid { solidBody(ctx, p, pressed); return }
		(pressed ? UIColor(red: 143 / 255, green: 227 / 255, blue: 1, alpha: 0.53 * alphaK) : UIColor.white.withAlphaComponent(0.16 * alphaK)).setFill()
		p.fill()
		(pressed ? UIColor(red: 143 / 255, green: 227 / 255, blue: 1, alpha: 0.94 * alphaK) : UIColor.white.withAlphaComponent(0.63 * alphaK)).setStroke()
		p.lineWidth = 1.2
		p.stroke()
	}

	private func line(_ ctx: CGContext, _ a: CGPoint, _ b: CGPoint)
	{
		ctx.setStrokeColor((solid ? solidInk : UIColor.white.withAlphaComponent(0.92 * alphaK)).cgColor)
		ctx.setLineWidth(1.6); ctx.setLineCap(.round)
		ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
	}

	private func glyph(_ ctx: CGContext, _ k: String, _ c: CGPoint, _ g: CGFloat, color: UIColor? = nil)
	{
		ctx.setStrokeColor((color ?? UIColor.white.withAlphaComponent(0.92 * alphaK)).cgColor)
		ctx.setLineWidth(solid ? 2 : 1.6)
		switch k
		{
		case "cross": ctx.move(to: CGPoint(x: c.x - g, y: c.y - g)); ctx.addLine(to: CGPoint(x: c.x + g, y: c.y + g)); ctx.move(to: CGPoint(x: c.x + g, y: c.y - g)); ctx.addLine(to: CGPoint(x: c.x - g, y: c.y + g))
		case "moon": ctx.addEllipse(in: CGRect(x: c.x - g * 1.1, y: c.y - g * 1.1, width: g * 2.2, height: g * 2.2))
		case "box": ctx.addRect(CGRect(x: c.x - g, y: c.y - g, width: 2 * g, height: 2 * g))
		default: ctx.move(to: CGPoint(x: c.x, y: c.y - g * 1.15)); ctx.addLine(to: CGPoint(x: c.x + g * 1.2, y: c.y + g * 0.85)); ctx.addLine(to: CGPoint(x: c.x - g * 1.2, y: c.y + g * 0.85)); ctx.closePath()
		}
		ctx.strokePath()
	}

	private func text(_ s: String, _ c: CGPoint, _ size: CGFloat)
	{
		let a: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: solid ? solidInk : UIColor.white.withAlphaComponent(0.92 * alphaK)]
		let t = NSAttributedString(string: s, attributes: a)
		let sz = t.size()
		t.draw(at: CGPoint(x: c.x - sz.width / 2, y: c.y - sz.height / 2))
	}

	// ── дотики ──
	private func isPressed(_ id: String) -> Bool
	{
		if id == "touchpad" { return touchpadTouch != nil || Date() < touchpadPressedUntil }
		if id == "l3" { return keyTouches.values.contains("l3") }
		return keyTouches.values.contains(id)
	}

	/** Кнопка під пальцем: для групи ✕○□△ — окрема кнопка */
	private func keyAt(_ p: CGPoint) -> String?
	{
		var best: (String, CGFloat)?
		func consider(_ id: String, _ c: CGPoint, _ r: CGRect)
		{
			let pad = max(r.width * 0.18, 6)
			guard r.insetBy(dx: -pad, dy: -pad).contains(p) else { return }
			let d = hypot(p.x - c.x, p.y - c.y)
			if best == nil || d < best!.1 { best = (id, d) }
		}
		for it in items where vis(it.id)
		{
			switch it.kind
			{
			case .trigger, .shoulder, .small, .ps, .menu, .click: consider(it.id, it.center, it.frame)
			case .face:
				let off = it.size.width * 0.34, r = it.size.width * 0.165
				for (k, dx, dy) in [("pyramid", 0.0, -1.0), ("moon", 1.0, 0.0), ("cross", 0.0, 1.0), ("box", -1.0, 0.0)]
				{
					let c = CGPoint(x: it.center.x + CGFloat(dx) * off, y: it.center.y + CGFloat(dy) * off)
					consider(k, c, CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
				}
			default: break
			}
		}
		return best?.0
	}

	private func dpadMaskAt(_ p: CGPoint) -> UInt32
	{
		let it = item("dpad")
		let dx = p.x - it.center.x, dy = p.y - it.center.y
		if hypot(dx, dy) < it.size.width * 0.08 { return 0 }
		var deg = atan2(dy, dx) * 180 / .pi
		if deg < 0 { deg += 360 }
		switch Int(((deg + 22.5).truncatingRemainder(dividingBy: 360)) / 45)
		{
		case 0: return Btn.right
		case 1: return Btn.right | Btn.down
		case 2: return Btn.down
		case 3: return Btn.down | Btn.left
		case 4: return Btn.left
		case 5: return Btn.left | Btn.up
		case 6: return Btn.up
		default: return Btn.up | Btn.right
		}
	}

	private func stickZone(_ i: Int) -> CGRect
	{
		let it = item(i == 0 ? "lstick" : "rstick")
		// 141: горизонтально стік ставиш будь-де на своїй половині екрана (кнопки мають перевагу)
		if landscape
		{
			let mid = area.midX
			return i == 0 ? CGRect(x: area.minX, y: area.minY, width: mid - area.minX, height: area.height)
				: CGRect(x: mid, y: area.minY, width: area.maxX - mid, height: area.height)
		}
		let grow = it.size.width * (landscape ? 1.9 : 1.3)
		var z = it.frame.insetBy(dx: -grow, dy: -grow).intersection(area)
		let mid = (item("lstick").center.x + item("rstick").center.x) / 2
		if i == 0 { z.size.width = min(z.width, mid - z.minX) } else { let r = z.maxX; z.origin.x = max(z.minX, mid); z.size.width = r - z.minX }
		return z
	}

	private var touchLogged = false

	override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?)
	{
		if !touchLogged
		{
			touchLogged = true
			Log.add(2, "Кнопки на екрані: перший дотик (видимість \(alpha), сховано \(isHidden), розмір \(Int(bounds.width))×\(Int(bounds.height)), видно кнопок \(items.filter { vis($0.id) }.count))")
		}
		reveal()
		for t in touches
		{
			let p = t.location(in: self)
			if let k = keyAt(p)
			{
				keyTouches[t] = k
				if k == "l2" || k == "r2" { triggerStartY[k] = p.y; triggerLevel[k] = Haptics.shared.analogTriggers ? 0.45 : 1 }
				feel(k, down: true)
				continue
			}
			let d = item("dpad")
			if dpadTouch == nil && vis("dpad") && hypot(p.x - d.center.x, p.y - d.center.y) <= d.size.width * 0.58
			{
				dpadTouch = t; dpadMask = dpadMaskAt(p); Haptics.shared.tap(.tick); continue
			}
			let tp = item("touchpad")
			if touchpadTouch == nil && vis("touchpad") && tp.frame.contains(p)
			{
				touchpadTouch = t; touchpadDownAt = Date(); touchpadDownPoint = p
				touchpadId = onTouchpad?(-1, tpX(p), tpY(p), false) ?? -1
				continue
			}
			for i in 0..<2 where sticks[i].touch == nil && vis(i == 0 ? "lstick" : "rstick") && stickZone(i).contains(p) {
				sticks[i].touch = t
				if landscape { sticks[i].origin = p } else { sticks[i].origin = item(i == 0 ? "lstick" : "rstick").center; moveStick(i, p) }
				sticks[i].click = Date().timeIntervalSince(sticks[i].lastUp) < 0.3
				if sticks[i].click { Haptics.shared.tap(.heavy) }
				break
			}
		}
		changed()
	}

	override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?)
	{
		for t in touches
		{
			let p = t.location(in: self)
			if let k = keyTouches[t]
			{
				if (k == "l2" || k == "r2") && Haptics.shared.analogTriggers
				{
					let lv = (0.45 + (p.y - (triggerStartY[k] ?? p.y)) / 42 * 0.55).clamped(0.15, 1)
					let was = triggerLevel[k] ?? 1
					if Int(lv * 4) > Int(was * 4) && lv < 0.98 { Haptics.shared.tap(.detent) }
					if lv >= 0.98 && was < 0.98 { Haptics.shared.tap(.triggerFull, side: k == "l2" ? 1 : 2) }
					triggerLevel[k] = lv
				}
				else if let n = keyAt(p), n != k, k != "menu", n != "menu"
				{
					feel(k, down: false); keyTouches[t] = n; feel(n, down: true)
				}
				continue
			}
			if t == dpadTouch
			{
				let m = dpadMaskAt(p)
				if m != dpadMask { dpadMask = m; if m != 0 { Haptics.shared.tap(.tick) } }
				continue
			}
			if t == touchpadTouch { _ = onTouchpad?(touchpadId, tpX(p), tpY(p), false); continue }
			for i in 0..<2 where sticks[i].touch == t { moveStick(i, p) }
		}
		changed()
	}

	override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { end(touches, cancelled: false) }
	override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { end(touches, cancelled: true) }

	private func end(_ touches: Set<UITouch>, cancelled: Bool)
	{
		for t in touches
		{
			let p = t.location(in: self)
			if let k = keyTouches.removeValue(forKey: t)
			{
				feel(k, down: false)
				triggerLevel[k] = nil
				if k == "menu" && !cancelled && item("menu").frame.insetBy(dx: -12, dy: -12).contains(p) { DispatchQueue.main.async { self.onMenu?() } }
				continue
			}
			if t == dpadTouch { dpadTouch = nil; dpadMask = 0; continue }
			if t == touchpadTouch
			{
				touchpadTouch = nil
				_ = onTouchpad?(touchpadId, 0, 0, true)
				touchpadId = -1
				if !cancelled && Date().timeIntervalSince(touchpadDownAt) < 0.25 && hypot(p.x - touchpadDownPoint.x, p.y - touchpadDownPoint.y) < 12
				{
					touchpadPressedUntil = Date().addingTimeInterval(0.11)
					Haptics.shared.tap(.heavy)
					DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { self.changed() }
				}
				continue
			}
			for i in 0..<2 where sticks[i].touch == t
			{
				sticks[i].touch = nil; sticks[i].dx = 0; sticks[i].dy = 0; sticks[i].click = false; sticks[i].edge = false
				sticks[i].origin = item(i == 0 ? "lstick" : "rstick").center
				sticks[i].lastUp = Date()
			}
		}
		changed()
		scheduleHide()
	}

	private func moveStick(_ i: Int, _ p: CGPoint)
	{
		let it = item(i == 0 ? "lstick" : "rstick")
		let travel = it.size.width / 2 * 0.56 * Sticks.travelK   // 138: хід стіка з налаштувань
		var dx = (p.x - sticks[i].origin.x) / travel, dy = (p.y - sticks[i].origin.y) / travel
		let len = hypot(dx, dy)
		if len > 1 { dx /= len; dy /= len }
		sticks[i].dx = dx; sticks[i].dy = dy
		if len >= 0.97 && !sticks[i].edge { sticks[i].edge = true; Haptics.shared.tap(.detent) }
		else if len < 0.8 { sticks[i].edge = false }
	}

	private func tpX(_ p: CGPoint) -> UInt16 { let r = item("touchpad").frame; return UInt16((((p.x - r.minX) / r.width).clamped(0, 1)) * 1919) }
	private func tpY(_ p: CGPoint) -> UInt16 { let r = item("touchpad").frame; return UInt16((((p.y - r.minY) / r.height).clamped(0, 1)) * 941) }

	private func feel(_ k: String, down: Bool)
	{
		switch k
		{
		case "l2", "r2": Haptics.shared.tap(down ? .triggerDown : .triggerUp, side: k == "l2" ? 1 : 2)
		case "l1", "r1", "create", "options", "ps", "l3", "r3": if down { Haptics.shared.tap(.click) }
		case "menu": if down { Haptics.shared.tap(.ui) }
		default: if down { Haptics.shared.tap(.tick) }
		}
	}

	private func q(_ v: CGFloat) -> Int16 { Int16((v.clamped(-1, 1) * 32767).rounded()) }

	private func changed()
	{
		var s = PadState()
		let bits: [String: UInt32] = ["cross": Btn.cross, "moon": Btn.moon, "box": Btn.box, "pyramid": Btn.pyramid, "l1": Btn.l1, "r1": Btn.r1,
			"create": Btn.share, "options": Btn.options, "ps": Btn.ps, "l3": Btn.l3, "r3": Btn.r3]
		for k in keyTouches.values
		{
			s.buttons |= bits[k] ?? 0
			if k == "l2" { s.l2 = max(s.l2, UInt8(((triggerLevel["l2"] ?? 1) * 255).rounded())) }
			if k == "r2" { s.r2 = max(s.r2, UInt8(((triggerLevel["r2"] ?? 1) * 255).rounded())) }
		}
		s.buttons |= dpadMask
		if sticks[0].click { s.buttons |= Btn.l3 }
		if sticks[1].click { s.buttons |= Btn.r3 }
		if Date() < touchpadPressedUntil { s.buttons |= Btn.touchpad }
		// 138: мертва зона й чутливість (трохи відхилив — персонаж іде, до краю — біжить)
		let (lx, ly) = Sticks.shape(sticks[0].dx, sticks[0].dy), (rx, ry) = Sticks.shape(sticks[1].dx, sticks[1].dy)
		s.lx = q(lx); s.ly = q(ly); s.rx = q(rx); s.ry = q(ry)
		onChange?(s)
		setNeedsDisplay()
	}

	func releaseAll()
	{
		keyTouches.removeAll(); dpadTouch = nil; dpadMask = 0; touchpadTouch = nil; triggerLevel.removeAll()
		for i in 0..<2 { sticks[i].touch = nil; sticks[i].dx = 0; sticks[i].dy = 0; sticks[i].click = false }
		changed()
	}

	// ── плавне ховання (лише горизонтально) ──
	private var shown = true

	private func anyTouch() -> Bool { !keyTouches.isEmpty || dpadTouch != nil || touchpadTouch != nil || sticks.contains { $0.touch != nil } }

	func scheduleHide()
	{
		hideWork?.cancel()
		let ah = Prefs.autoHide
		guard landscape, ah != 0, !anyTouch() else { if !landscape || ah == 0 { reveal() }; return }
		let w = DispatchWorkItem { [weak self] in
			guard let s = self, !s.anyTouch(), s.shown else { return }
			s.shown = false
			UIView.animate(withDuration: 0.55, delay: 0, options: [.curveEaseInOut, .allowUserInteraction]) { s.alpha = 0.01 }
		}
		hideWork = w
		DispatchQueue.main.asyncAfter(deadline: .now() + (ah < 0 ? 1.0 : Double(ah)), execute: w)
	}

	func reveal()
	{
		hideWork?.cancel()
		if !shown
		{
			shown = true
			UIView.animate(withDuration: 0.11, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) { self.alpha = 1 }
		}
	}

	/** Грають справжнім геймпадом: кнопки ховаються до першого дотику */
	func physicalInput()
	{
		// 128: вертикально кнопки завжди на екрані (під картинкою вони нічого не закривають)
		guard shown, landscape, Prefs.autoHide != 0, !anyTouch() else { return }
		hideWork?.cancel()
		shown = false
		UIView.animate(withDuration: 0.4) { self.alpha = 0.01 }
	}
}
