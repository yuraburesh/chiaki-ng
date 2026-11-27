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
	private var mouseDX: CGFloat = 0, mouseDY: CGFloat = 0
	private var mouseDecay: Timer?
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
			self?.padState = PadState()
			if let s = self?.state { self?.onChange?(s) }
		}
		GCController.controllers().forEach(attach)
		// 134: клавіатура (Bluetooth чи чохол-клавіатура iPad) і миша/трекпад, як у програмі на комп'ютері
		NotificationCenter.default.addObserver(forName: .GCKeyboardDidConnect, object: nil, queue: .main) { [weak self] _ in self?.attachKeyboard() }
		NotificationCenter.default.addObserver(forName: .GCMouseDidConnect, object: nil, queue: .main) { [weak self] n in
			if let m = n.object as? GCMouse { self?.attachMouse(m) }
		}
		attachKeyboard()
		GCMouse.mice().forEach(attachMouse)
	}

	/** Відпустити все (програму згорнули: інакше натиснута до цього клавіша «залипала») */
	func reset()
	{
		padState = PadState(); keyState = PadState(); mouseState = PadState()
		mouseDX = 0; mouseDY = 0
		onChange?(state)
	}

	var keyboardConnected: Bool { GCKeyboard.coalesced != nil }

	// ── клавіатура: WASD рух, стрілки огляд, Space ✕, X ○, E □, F △, Q L1, R R1, / L2, правий Shift R2 (і миша) ──
	private func attachKeyboard()
	{
		GCKeyboard.coalesced?.keyboardInput?.keyChangedHandler = { [weak self] kb, _, _, _ in self?.readKeys(kb) }
	}

	private func readKeys(_ k: GCKeyboardInput)
	{
		func on(_ c: GCKeyCode) -> Bool { k.button(forKeyCode: c)?.isPressed ?? false }
		var s = PadState()
		func b(_ pressed: Bool, _ bit: UInt32) { if pressed { s.buttons |= bit } }
		b(on(.spacebar) || on(.returnOrEnter), Btn.cross)
		b(on(.keyX) || on(.deleteOrBackspace), Btn.moon)
		b(on(.keyE), Btn.box)
		b(on(.keyF), Btn.pyramid)
		b(on(.keyQ), Btn.l1)
		b(on(.keyR), Btn.r1)
		b(on(.leftShift), Btn.l3)
		b(on(.keyC), Btn.r3)
		b(on(.escape), Btn.options)
		b(on(.keyM), Btn.share)
		b(on(.keyP), Btn.ps)
		b(on(.keyN) || on(.keyV), Btn.touchpad)
		b(on(.one), Btn.up)
		b(on(.two), Btn.down)
		b(on(.three), Btn.left)
		b(on(.four), Btn.right)
		if on(.slash) || on(.keyZ) { s.l2 = 255 }
		if on(.rightShift) || on(.keyT) { s.r2 = 255 }
		func ax(_ neg: Bool, _ pos: Bool) -> Int16 { neg == pos ? 0 : (neg ? -32767 : 32767) }
		s.lx = ax(on(.keyA), on(.keyD))
		s.ly = ax(on(.keyW), on(.keyS))
		s.rx = ax(on(.leftArrow), on(.rightArrow))
		s.ry = ax(on(.upArrow), on(.downArrow))
		DispatchQueue.main.async {
			self.keyState = s
			self.lastPadAt = Date()
			self.onChange?(self.state)
		}
	}

	// ── миша/трекпад: рух — огляд (правий стік), ліва кнопка R2, права L2 ──
	private func attachMouse(_ m: GCMouse)
	{
		guard let mi = m.mouseInput else { return }
		mi.mouseMovedHandler = { [weak self] _, dx, dy in
			DispatchQueue.main.async { self?.mouseMoved(CGFloat(dx), CGFloat(-dy)) }
		}
		mi.leftButton.pressedChangedHandler = { [weak self] _, _, p in
			DispatchQueue.main.async { guard let self = self else { return }; self.mouseState.r2 = p ? 255 : 0; self.onChange?(self.state) }
		}
		mi.rightButton?.pressedChangedHandler = { [weak self] _, _, p in
			DispatchQueue.main.async { guard let self = self else { return }; self.mouseState.l2 = p ? 255 : 0; self.onChange?(self.state) }
		}
	}

	private func mouseMoved(_ dx: CGFloat, _ dy: CGFloat)
	{
		// швидкість руху миші → відхилення стіка; без руху стік плавно повертається в центр
		mouseDX = (mouseDX * 0.5 + dx * 0.06).clamped(-1, 1)
		mouseDY = (mouseDY * 0.5 + dy * 0.06).clamped(-1, 1)
		mouseState.rx = Int16((mouseDX * 32767).rounded())
		mouseState.ry = Int16((mouseDY * 32767).rounded())
		lastPadAt = Date()
		onChange?(state)
		if mouseDecay == nil
		{
			mouseDecay = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] t in
				guard let self = self else { t.invalidate(); return }
				self.mouseDX *= 0.7; self.mouseDY *= 0.7
				if abs(self.mouseDX) < 0.02 && abs(self.mouseDY) < 0.02
				{
					self.mouseDX = 0; self.mouseDY = 0
					t.invalidate(); self.mouseDecay = nil
				}
				self.mouseState.rx = Int16((self.mouseDX * 32767).rounded())
				self.mouseState.ry = Int16((self.mouseDY * 32767).rounded())
				self.onChange?(self.state)
			}
		}
	}

	var connected: Bool { GCController.controllers().contains { $0.extendedGamepad != nil } }

	private func attach(_ c: GCController)
	{
		guard let g = c.extendedGamepad else { return }
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
