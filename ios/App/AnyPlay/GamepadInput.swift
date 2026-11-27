// AnyPlay для iPhone та iPad: справжній геймпад (DualSense, DualShock 4, Xbox, MFi) через GameController.
// iOS розпізнає DualSense повністю: кнопки на своїх місцях, тачпад, вібрація й адаптивні курки (див. Haptics).
import GameController
import UIKit

final class GamepadInput
{
	static let shared = GamepadInput()

	/** Коли востаннє грали геймпадом (вібрація гри тоді йде на нього, екранні кнопки ховаються) */
	private(set) var lastPadAt = Date.distantPast
	/** Усе разом: геймпад, клавіатура й миша (134) */
	var state: PadState { padState.merged(keyState).merged(mouseState) }
	private var padState = PadState()
	/** 138: справжній геймпад зараз щось натискає (кнопка, курок або стік помітно відхилено) */
	var gamepadActive: Bool { padState.buttons != 0 || padState.l2 > 30 || padState.r2 > 30 || [padState.lx, padState.ly, padState.rx, padState.ry].contains { abs(Int($0)) > 8000 } }
	private var keyState = PadState()
	private var mouseState = PadState()
	var onChange: ((PadState) -> Void)?
	private var started = false

	func start()
	{
		if started { return }
		started = true
		GCController.shouldMonitorBackgroundEvents = false
		NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] n in
			if let c = n.object as? GCController { self?.attach(c) }
		}
		NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
			Log.add(3, "Геймпад відключився")
			self?.padState = PadState()
			if let s = self?.state { self?.onChange?(s) }
		}
		GCController.controllers().forEach(attach)
		// 134: клавіатура (Bluetooth чи чохол-клавіатура iPad) і миша/трекпад, як у програмі на комп'ютері
		NotificationCenter.default.addObserver(forName: .GCKeyboardDidConnect, object: nil, queue: .main) { [weak self] _ in Log.add(2, "Клавіатура підключилась"); self?.attachKeyboard() }
		// 141: для діагностики — коли клавіатура чи геймпад відпадають
		NotificationCenter.default.addObserver(forName: .GCKeyboardDidDisconnect, object: nil, queue: .main) { [weak self] _ in Log.add(3, "Клавіатура відключилась"); self?.downKeys = []; KeyLayout.shared.releaseAll(); self?.keyState = PadState() }
		Log.add(2, "Під час старту: клавіатура \(GCKeyboard.coalesced != nil ? "є" : "немає"), геймпадів \(GCController.controllers().count), мишей \(GCMouse.mice().count)")
		NotificationCenter.default.addObserver(forName: .GCMouseDidConnect, object: nil, queue: .main) { [weak self] n in
			if let m = n.object as? GCMouse { self?.attachMouse(m) }
		}
		attachKeyboard()
		GCMouse.mice().forEach(attachMouse)
	}

	/** Відпустити все (програму згорнули: інакше натиснута до цього клавіша «залипала») */
	func reset()
	{
		padState = PadState(); keyState = PadState(); mouseState = PadState(); downKeys = []
		KeyLayout.shared.releaseAll()
		accX = 0; accY = 0; smX = 0; smY = 0; mouseTimer?.invalidate(); mouseTimer = nil
		onChange?(state)
	}

	var keyboardConnected: Bool { GCKeyboard.coalesced != nil }

	// ── 145: клавіатура й миша — розкладка як на Mac (KeyLayout: режими «Пішки», «Транспорт», «Авіація»), ` — меню AnyPlay ──
	/** Натиснули ` (меню AnyPlay) */
	var onMenuKey: (() -> Void)?

	private func attachKeyboard()
	{
		KeyLayout.shared.onChange = { [weak self] in
			guard let self = self else { return }
			self.keyState = KeyLayout.shared.padState()
			self.lastPadAt = Date()
			self.onChange?(self.state)
		}
		GCKeyboard.coalesced?.keyboardInput?.keyChangedHandler = { [weak self] _, _, code, pressed in
			DispatchQueue.main.async { self?.key(code.rawValue, down: pressed, from: "GameController") }
		}
	}

	private var downKeys: Set<Int> = []
	private var keyLogged = false

	/** Клавіша (HID-код) з GameController або з UIKit (GameViewController.pressesBegan): обидва шляхи разом, повтори відкидаються */
	func uiPress(_ code: Int, down: Bool) { key(code, down: down, from: "UIKit") }

	private func key(_ code: Int, down: Bool, from: String)
	{
		if down == downKeys.contains(code) { return }
		if down { downKeys.insert(code) } else { downKeys.remove(code) }
		guard let name = KeyLayout.name(hid: code) else { return }
		if !keyLogged && down { keyLogged = true; Log.add(2, "Клавіатура: перше натискання \(name) (через \(from))") }
		if name == KeyLayout.menuKey { if down { onMenuKey?() }; return }
		KeyLayout.shared.press(name, down)
	}

	// ── миша/трекпад: рух — правий стік (як на Mac: швидкість → відхилення, згладжування, мертва зона), кнопки й коліщатко — з розкладки ──
	private var accX: CGFloat = 0, accY: CGFloat = 0
	private var smX: CGFloat = 0, smY: CGFloat = 0
	private var mouseTimer: Timer?
	private var mouseTick = Date()
	private var lastWheel = Date.distantPast
	private var mouseLogged = false

	private func attachMouse(_ m: GCMouse)
	{
		guard let mi = m.mouseInput else { return }
		Log.add(2, "Миша/трекпад підключились")
		mi.mouseMovedHandler = { [weak self] _, dx, dy in
			DispatchQueue.main.async { self?.mouseMoved(CGFloat(dx), CGFloat(-dy)) }
		}
		mi.leftButton.pressedChangedHandler = { _, _, p in DispatchQueue.main.async { KeyLayout.shared.press("MouseLeft", p) } }
		mi.rightButton?.pressedChangedHandler = { _, _, p in DispatchQueue.main.async { KeyLayout.shared.press("MouseRight", p) } }
		mi.middleButton?.pressedChangedHandler = { _, _, p in DispatchQueue.main.async { KeyLayout.shared.press("MouseMiddle", p) } }
		mi.scroll.valueChangedHandler = { [weak self] _, _, y in
			DispatchQueue.main.async {
				guard let self = self, abs(y) > 0.5, Date().timeIntervalSince(self.lastWheel) > 0.18 else { return }
				self.lastWheel = Date()
				KeyLayout.shared.wheel(y > 0 ? "WheelUp" : "WheelDown")
			}
		}
	}

	private func mouseMoved(_ dx: CGFloat, _ dy: CGFloat)
	{
		if !mouseLogged { mouseLogged = true; Log.add(2, "Миша/трекпад: перший рух (\(dx), \(dy))") }
		accX += dx; accY += dy
		if mouseTimer == nil
		{
			mouseTick = Date()
			mouseTimer = Timer.scheduledTimer(withTimeInterval: 0.008, repeats: true) { [weak self] _ in self?.mouseStep() }
		}
	}

	/** Те саме, що StreamSession::UpdateMouseRightStick на Mac */
	private func mouseStep()
	{
		let full: CGFloat = 4000, dead: CGFloat = 0.15, stop = full * 0.0015
		let dt = min(0.1, max(0.001, CGFloat(Date().timeIntervalSince(mouseTick))))
		mouseTick = Date()
		let gain = CGFloat(Prefs.mouseSpeed) * 2.5   // трекпад iPad дає менші кроки, ніж миша на Mac
		let sx = accX / dt * gain, sy = accY / dt * gain
		accX = 0; accY = 0
		let raw = hypot(sx, sy), prev = hypot(smX, smY)
		let activity = min(max(raw, prev) / (full * 0.25), 1)
		let smoothMs = 60 + (30 - 60) * activity
		let a = 1 - exp(-dt * 1000 / smoothMs)
		smX += (sx - smX) * a; smY += (sy - smY) * a
		let speed = hypot(smX, smY)
		var nx: Int16 = 0, ny: Int16 = 0
		if speed <= stop
		{
			smX = 0; smY = 0
			mouseTimer?.invalidate(); mouseTimer = nil
		}
		else
		{
			let len = min(speed / full, 1)
			let out = dead * min(len / 0.01, 1) + (1 - dead) * len
			let k = out / speed
			nx = Int16(((smX * k).clamped(-1, 1) * 32767).rounded())
			ny = Int16(((smY * k).clamped(-1, 1) * 32767).rounded())
		}
		if nx != mouseState.rx || ny != mouseState.ry
		{
			mouseState.rx = nx; mouseState.ry = ny
			onChange?(state)
		}
	}

	var connected: Bool { GCController.controllers().contains { $0.extendedGamepad != nil } }

	private func attach(_ c: GCController)
	{
		guard let g = c.extendedGamepad else { return }
		// 139: кнопки PS, Options, Create і тачпад — у гру, а не системі iPad (PS відкривав «Ігри» Apple у Safari)
		for e in [g.buttonHome, g.buttonMenu, g.buttonOptions] as [GCControllerElement?] { e?.preferredSystemGestureState = .disabled }
		// 142: і всі інші елементи геймпада (на новіших iPadOS кнопка PS — окремий елемент профілю)
		for e in c.physicalInputProfile.allElements { e.preferredSystemGestureState = .disabled }
		Log.add(2, "Геймпад: \(c.vendorName ?? "?"), кнопку PS забрали в системи (\(g.buttonHome?.preferredSystemGestureState == .disabled ? "так" : "ні"))")
		if let ds = g as? GCDualSenseGamepad { ds.touchpadButton.preferredSystemGestureState = .disabled }
		if let d4 = g as? GCDualShockGamepad { d4.touchpadButton.preferredSystemGestureState = .disabled }
		g.valueChangedHandler = { [weak self] gp, _ in self?.read(gp) }
	}

	private func axis(_ v: Float) -> Int16 { Int16((v.clamped(-1, 1) * 32767).rounded()) }

	private func read(_ g: GCExtendedGamepad)
	{
		var s = PadState()
		func b(_ on: Bool, _ bit: UInt32) { if on { s.buttons |= bit } }
		b(g.buttonA.isPressed, Btn.cross)
		b(g.buttonB.isPressed, Btn.moon)
		b(g.buttonX.isPressed, Btn.box)
		b(g.buttonY.isPressed, Btn.pyramid)
		b(g.leftShoulder.isPressed, Btn.l1)
		b(g.rightShoulder.isPressed, Btn.r1)
		b(g.leftThumbstickButton?.isPressed ?? false, Btn.l3)
		b(g.rightThumbstickButton?.isPressed ?? false, Btn.r3)
		b(g.buttonMenu.isPressed, Btn.options)
		b(g.buttonOptions?.isPressed ?? false, Btn.share)
		b(g.buttonHome?.isPressed ?? false, Btn.ps)
		b(g.dpad.up.isPressed, Btn.up)
		b(g.dpad.down.isPressed, Btn.down)
		b(g.dpad.left.isPressed, Btn.left)
		b(g.dpad.right.isPressed, Btn.right)
		if let ds = g as? GCDualSenseGamepad { b(ds.touchpadButton.isPressed, Btn.touchpad) }
		else if let d4 = g as? GCDualShockGamepad { b(d4.touchpadButton.isPressed, Btn.touchpad) }
		s.l2 = UInt8((g.leftTrigger.value.clamped(0, 1) * 255).rounded())
		s.r2 = UInt8((g.rightTrigger.value.clamped(0, 1) * 255).rounded())
		// 138: мертва зона й чутливість з налаштувань; у PS5 вгору — від'ємне
		let (lx, ly) = Sticks.shape(CGFloat(g.leftThumbstick.xAxis.value), CGFloat(-g.leftThumbstick.yAxis.value))
		let (rx, ry) = Sticks.shape(CGFloat(g.rightThumbstick.xAxis.value), CGFloat(-g.rightThumbstick.yAxis.value))
		s.lx = axis(Float(lx)); s.ly = axis(Float(ly)); s.rx = axis(Float(rx)); s.ry = axis(Float(ry))
		if s.buttons & Btn.ps != 0 && padState.buttons & Btn.ps == 0 { Log.add(2, "Геймпад: PS дійшла до програми") }
		padState = s
		lastPadAt = Date()
		onChange?(state)
	}
}


/** Кнопки PS5 (як ChiakiControllerButton) */
enum Btn
{
	static let cross: UInt32 = 1 << 0, moon: UInt32 = 1 << 1, box: UInt32 = 1 << 2, pyramid: UInt32 = 1 << 3
	static let left: UInt32 = 1 << 4, right: UInt32 = 1 << 5, up: UInt32 = 1 << 6, down: UInt32 = 1 << 7
	static let l1: UInt32 = 1 << 8, r1: UInt32 = 1 << 9, l3: UInt32 = 1 << 10, r3: UInt32 = 1 << 11
	static let options: UInt32 = 1 << 12, share: UInt32 = 1 << 13, touchpad: UInt32 = 1 << 14, ps: UInt32 = 1 << 15
}

/** 138: чутливість стіків (як AnyPlaySticks.kt на Android): мертва зона, крива відгуку, хід екранного стіка. Зберігається в Prefs.feel */
enum Sticks
{
	private static let exps: [CGFloat] = [2.2, 1.6, 1]          // плавно, звичайно, різко
	private static let deads: [CGFloat] = [0.03, 0.08, 0.15]    // мала, середня, велика
	private static let travels: [CGFloat] = [0.8, 1, 1.4]       // короткий, середній, довгий
	private static var curve = 1, dead = 1, travel = 1

	/** Перечитати з Prefs.feel (на старті й після зміни в налаштуваннях) */
	static func reload()
	{
		let f = Prefs.feel
		func v(_ k: String) -> Int { ((f[k] as? NSNumber)?.intValue ?? 1).clamped(0, 2) }
		curve = v("stickCurve"); dead = v("stickDead"); travel = v("stickTravel")
	}

	static var travelK: CGFloat { travels[travel] }

	/** Відхилення (-1..1) → що йде в гру: мертва зона й крива за довжиною, напрямок той самий */
	static func shape(_ x: CGFloat, _ y: CGFloat) -> (CGFloat, CGFloat)
	{
		let len = hypot(x, y), d = deads[dead]
		if len <= d { return (0, 0) }
		let n = ((len - d) / (1 - d)).clamped(0, 1)
		let k = pow(n, exps[curve]) / len
		return ((x * k).clamped(-1, 1), (y * k).clamped(-1, 1))
	}
}

extension GamepadInput
{
	/** 145: iPadOS 27 сам вирішує, що робить кнопка PS (Home) у програмах: Налаштування → Загальні → Ігровий контролер.
	 *  Там «у програмах» треба віддати її програмі, тоді наш вибір (кнопка йде в гру) діє. Відкриваємо цей екран;
	 *  на старіших iOS або без такого виклику — просто Налаштування */
	static func openHomeButtonSettings()
	{
		let sel = NSSelectorFromString("openControllerHomeButtonSettingsForActivity:")
		if let m = class_getClassMethod(GCController.self, sel)
		{
			typealias F = @convention(c) (AnyClass, Selector, Int) -> Void
			let f = unsafeBitCast(method_getImplementation(m), to: F.self)
			f(GCController.self, sel, 0)   // customizeInAppAction
			Log.add(2, "Кнопка PS: відкрили налаштування контролера")
			return
		}
		if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
	}
}
