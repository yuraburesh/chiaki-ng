// AnyPlay для iPhone та iPad: справжній геймпад (DualSense, DualShock 4, Xbox, MFi) через GameController.
// iOS розпізнає DualSense повністю: кнопки на своїх місцях, тачпад, вібрація й адаптивні курки (див. Haptics).
import GameController

final class GamepadInput
{
	static let shared = GamepadInput()

	/** Коли востаннє грали геймпадом (вібрація гри тоді йде на нього, екранні кнопки ховаються) */
	private(set) var lastPadAt = Date.distantPast
	private(set) var state = PadState()
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
			self?.state = PadState()
			if let s = self?.state { self?.onChange?(s) }
		}
		GCController.controllers().forEach(attach)
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
		s.lx = axis(g.leftThumbstick.xAxis.value)
		s.ly = axis(-g.leftThumbstick.yAxis.value)     // у PS5 вгору — від'ємне
		s.rx = axis(g.rightThumbstick.xAxis.value)
		s.ry = axis(-g.rightThumbstick.yAxis.value)
		state = s
		lastPadAt = Date()
		onChange?(s)
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
