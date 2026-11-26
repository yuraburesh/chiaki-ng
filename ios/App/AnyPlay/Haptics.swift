// AnyPlay для iPhone та iPad: вібрація (як AnyPlayHaptics.kt на Android).
// iPhone має Taptic Engine з плавною силою: вібрація гри — безперервний відгук, сила змінюється на льоту.
// Справжній DualSense на iOS отримує вібрацію гри на свої моторчики, а ефекти курків гри — на адаптивні курки.
import CoreHaptics
import GameController
import UIKit

final class Haptics
{
	static let shared = Haptics()

	private let rumbleGain: [Float] = [0, 0.45, 0.75, 1]
	private let buttonGain: [Float] = [0, 0.6, 1]
	private var rumbleLevel: Int { (Prefs.feel["rumble"] as? Int ?? 2).clamped(0, 3) }
	private var buttonsLevel: Int { (Prefs.feel["buttons"] as? Int ?? 1).clamped(0, 2) }
	var analogTriggers: Bool { Prefs.feel["analog"] as? Bool ?? false }

	private var engine: CHHapticEngine?
	private var rumblePlayer: CHHapticAdvancedPatternPlayer?
	private var padEngine: CHHapticEngine?
	private var padPlayer: CHHapticAdvancedPatternPlayer?
	private weak var padController: GCController?
	private var rumbleNow: Float = 0
	private let light = UIImpactFeedbackGenerator(style: .light)
	private let medium = UIImpactFeedbackGenerator(style: .medium)
	private let heavy = UIImpactFeedbackGenerator(style: .heavy)
	private let rigid = UIImpactFeedbackGenerator(style: .rigid)

	private init()
	{
		if CHHapticEngine.capabilitiesForHardware().supportsHaptics
		{
			engine = try? CHHapticEngine()
			engine?.isAutoShutdownEnabled = true
			engine?.resetHandler = { [weak self] in try? self?.engine?.start(); self?.rumblePlayer = nil }
			try? engine?.start()
		}
	}

	// ── кнопки ──
	enum Tap { case ui, tick, click, heavy, detent, triggerDown, triggerUp, triggerFull }

	func ui() { tap(.ui) }

	func tap(_ t: Tap, side: Int = 0)
	{
		let g = buttonGain[buttonsLevel]
		guard g > 0 else { return }
		let eff = side == 1 ? effL : side == 2 ? effR : .none
		switch t
		{
		case .ui, .detent: light.impactOccurred(intensity: CGFloat(0.5 * g))
		case .tick: light.impactOccurred(intensity: CGFloat(0.8 * g))
		case .click: medium.impactOccurred(intensity: CGFloat(0.8 * g))
		case .heavy: heavy.impactOccurred(intensity: CGFloat(g))
		case .triggerDown:
			switch eff
			{
			case .resist: transient([(0, 1.0 * g, 0.2), (0.03, 0.7 * g, 0.1), (0.06, 0.4 * g, 0.1)])
			case .weapon: transient([(0, 0.3 * g, 0.5), (0.045, 1.0 * g, 0.9)])
			default: rigid.impactOccurred(intensity: CGFloat(0.75 * g))
			}
		case .triggerUp: if eff == .resist || buttonsLevel >= 2 { light.impactOccurred(intensity: CGFloat(0.4 * g)) }
		case .triggerFull: rigid.impactOccurred(intensity: CGFloat(g))
		}
	}

	/** Кілька коротких поштовхів: (час с, сила 0..1, різкість 0..1) */
	private func transient(_ list: [(Double, Float, Float)])
	{
		guard let e = engine else { heavy.impactOccurred(); return }
		let ev = list.map { CHHapticEvent(eventType: .hapticTransient, parameters: [
			CHHapticEventParameter(parameterID: .hapticIntensity, value: $0.1),
			CHHapticEventParameter(parameterID: .hapticSharpness, value: $0.2)], relativeTime: $0.0) }
		if let p = try? CHHapticPattern(events: ev, parameters: []), let pl = try? e.makePlayer(with: p) { try? pl.start(atTime: 0) }
	}

	// ── вібрація гри ──
	/** left — важкий мотор, right — легкий (0..255) */
	func rumble(left: Int, right: Int)
	{
		let g = rumbleGain[rumbleLevel]
		let s = Float(max(left, Int(Float(right) * 0.8))) / 255 * g
		let level = (s * 16).rounded() / 16
		if level == rumbleNow { return }
		rumbleNow = level
		// граємо справжнім геймпадом з моторчиками — віддача на нього, як на приставці
		if let c = GCController.current, c.haptics != nil, Date().timeIntervalSince(GamepadInput.shared.lastPadAt) < 20
		{
			setRumble(on: padEngineFor(c), player: &padPlayer, level: level)
			setRumble(on: engine, player: &rumblePlayer, level: 0)
			return
		}
		setRumble(on: engine, player: &rumblePlayer, level: level)
	}

	private func padEngineFor(_ c: GCController) -> CHHapticEngine?
	{
		if padController !== c || padEngine == nil
		{
			padEngine?.stop()
			padEngine = c.haptics?.createEngine(withLocality: .default)
			try? padEngine?.start()
			padPlayer = nil
			padController = c
		}
		return padEngine
	}

	private func setRumble(on e: CHHapticEngine?, player: inout CHHapticAdvancedPatternPlayer?, level: Float)
	{
		guard let e = e else { return }
		if level <= 0.03
		{
			try? player?.stop(atTime: 0)
			player = nil
			return
		}
		let intensity = 0.2 + 0.8 * level
		if player == nil
		{
			let ev = CHHapticEvent(eventType: .hapticContinuous, parameters: [
				CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
				CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.25)], relativeTime: 0, duration: 30)
			guard let p = try? CHHapticPattern(events: [ev], parameters: []), let pl = try? e.makeAdvancedPlayer(with: p) else { return }
			pl.loopEnabled = true
			try? pl.start(atTime: 0)
			player = pl
		}
		try? player?.sendParameters([CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: intensity, relativeTime: 0)], atTime: 0)
	}

	func stopRumble()
	{
		rumbleNow = 0
		try? rumblePlayer?.stop(atTime: 0); rumblePlayer = nil
		try? padPlayer?.stop(atTime: 0); padPlayer = nil
		resetTriggers()
	}

	// ── курки DualSense ──
	enum Trigger { case none, resist, weapon, vibrate }
	private(set) var effL = Trigger.none
	private(set) var effR = Trigger.none

	/** Ефекти курків від гри (тип і 10 байтів для L2 і R2), як parse() на Android */
	func triggerEffects(typeL: Int, typeR: Int, data: [UInt8])
	{
		let l = Array(data.prefix(10)), r = Array(data.dropFirst(10).prefix(10))
		let pl = parse(typeL, l), pr = parse(typeR, r)
		effL = pl.0; effR = pr.0
		// справжній DualSense: ті самі ефекти на його адаптивні курки
		if let ds = GCController.current?.extendedGamepad as? GCDualSenseGamepad
		{
			apply(ds.leftTrigger, pl)
			apply(ds.rightTrigger, pr)
		}
	}

	func resetTriggers()
	{
		effL = .none; effR = .none
		if let ds = GCController.current?.extendedGamepad as? GCDualSenseGamepad
		{
			ds.leftTrigger.setModeOff()
			ds.rightTrigger.setModeOff()
		}
	}

	private func parse(_ type: Int, _ b: [UInt8]) -> (Trigger, Float, Float, Float)
	{
		func u(_ i: Int) -> Int { i < b.count ? Int(b[i]) : 0 }
		func zones(_ from: Int) -> Float
		{
			var bits: UInt64 = 0
			for i in 0..<4 { bits |= UInt64(u(from + i)) << (8 * UInt64(i)) }
			var m: UInt64 = 0
			for z in 0..<10 { m = max(m, (bits >> (3 * UInt64(z))) & 7) }
			return Float(m + 1) / 8
		}
		switch type
		{
		case 0x21, 0x22: return (.resist, zones(2), 0.2, 0)
		case 0x01, 0x11: return (.resist, Float(u(1)) / 255, Float(u(0)) / 255, 0)
		case 0x25, 0x02, 0x12: return (.weapon, Float((u(2) & 7) + 1) / 8, 0.3, 0.6)
		case 0x26: return (.vibrate, zones(2), 0.1, Float(u(8)))
		case 0x06: return (.vibrate, Float(u(1)) / 255, 0.1, Float(u(0)))
		default: return (.none, 0, 0, 0)
		}
	}

	private func apply(_ t: GCDualSenseAdaptiveTrigger, _ p: (Trigger, Float, Float, Float))
	{
		switch p.0
		{
		case .none: t.setModeOff()
		case .resist: t.setModeFeedbackWithStartPosition(p.2.clamped(0, 0.9), resistiveStrength: max(0.2, p.1))
		case .weapon: t.setModeWeaponWithStartPosition(p.2, endPosition: max(p.2 + 0.1, p.3), resistiveStrength: max(0.3, p.1))
		case .vibrate: t.setModeVibrationWithStartPosition(p.2, amplitude: max(0.2, p.1), frequency: (p.3 / 255).clamped(0.05, 1))
		}
	}

	/** «Спробувати» в налаштуваннях */
	func demo(_ what: String)
	{
		switch what
		{
		case "rumble":
			let g = rumbleGain[rumbleLevel]
			guard g > 0, let e = engine else { return }
			let ev = [(0.0, 0.22, 0.25 * g), (0.34, 0.26, 0.6 * g), (0.72, 0.42, 1.0 * g)].map {
				CHHapticEvent(eventType: .hapticContinuous, parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: Float($0.2)),
					CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.2)], relativeTime: $0.0, duration: $0.1) }
			if let p = try? CHHapticPattern(events: ev, parameters: []), let pl = try? e.makePlayer(with: p) { try? pl.start(atTime: 0) }
		case "buttons":
			tap(.tick)
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { self.tap(.click) }
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.48) { self.tap(.heavy) }
		case "trigger":
			let g = buttonGain[max(1, buttonsLevel)]
			transient([(0, 1.0 * g, 0.2), (0.03, 0.7 * g, 0.1), (0.06, 0.4 * g, 0.1), (0.4, 0.3 * g, 0.5), (0.445, 1.0 * g, 0.9)])
		default: break
		}
	}
}
