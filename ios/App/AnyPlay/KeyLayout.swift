// AnyPlay 145 для iPad: клавіатура й миша так само, як у програмі для Mac (gui/src/anyplayinput.cpp).
// Ті самі файли розкладок (web/keys/anyplay-controls-*.json): режими «Пішки», «Транспорт», «Авіація» зі своїми клавішами,
// режим перемикається сам за адаптивними курками (визначник з Mac через VehicleBridge) або вручну: U, F1, F2, F3.
// Клавіша ` — меню AnyPlay. Тут — головне з рушія Mac: утримання, коротке натискання, комбінації (зброя 1–9),
// перебір зброї коліщатком, обертання стіка (відмичка), інша дія в прицілі. Точного руху й зламу машини мишею поки нема.
import Foundation

final class KeyLayout
{
	static let shared = KeyLayout()

	struct Step
	{
		var buttons: UInt32 = 0
		var lx: Float = 0, ly: Float = 0, rx: Float = 0, ry: Float = 0
		var ms = 0
	}

	enum Kind { case hold, tap, macro, cycle, spin, none }

	struct Binding
	{
		var id = "", key = "", owner = "", profile = ""
		var kind = Kind.hold
		var out = Step()
		var steps: [Step] = []
		var dir = 1
		var when: UInt32 = 0
		var aimWhen: UInt32 = 0
		var aimOut = Step()
		var holdOpen = false
		var holdOut = Step()
		var holdMin = 0
		var spinL = 0, spinR = 0
		var pressedAt: Int64 = 0
	}

	struct Profile { var id: String; var name: String; var bindings: [Binding] }

	// аналогові курки в розкладках — окремі біти, як CHIAKI_CONTROLLER_ANALOG_BUTTON_L2/R2
	static let l2: UInt32 = 1 << 16, r2: UInt32 = 1 << 17
	static let menuKey = "`"

	private(set) var layout = "gta6"
	private(set) var profiles: [Profile] = []
	private(set) var current = "foot"
	private var active: [String: Binding] = [:]
	private var held: Set<String> = []
	private var taps: [(Int, Step)] = []
	private var nextTap = 0
	private var macro: [Step] = []
	private var macroIndex = -1
	private var macroWork: DispatchWorkItem?
	private var slot = -1
	private var spinTimer: Timer?
	private var vehicle: OpaquePointer?
	private var vehicleTimer: Timer?
	private let start = Date()
	var onChange: (() -> Void)?
	/** Режим змінився: текст для підказки на екрані */
	var onMode: ((String) -> Void)?

	private var now: Int64 { Int64(Date().timeIntervalSince(start) * 1000) }

	// ── завантаження ──

	private static let buttonNames: [String: UInt32] = [
		"CROSS": Btn.cross, "MOON": Btn.moon, "BOX": Btn.box, "PYRAMID": Btn.pyramid,
		"DPAD_LEFT": Btn.left, "DPAD_RIGHT": Btn.right, "DPAD_UP": Btn.up, "DPAD_DOWN": Btn.down,
		"L1": Btn.l1, "R1": Btn.r1, "L3": Btn.l3, "R3": Btn.r3, "OPTIONS": Btn.options, "SHARE": Btn.share,
		"TOUCHPAD": Btn.touchpad, "PS": Btn.ps, "L2": l2, "R2": r2]

	private static func button(_ name: Any?) -> UInt32 { buttonNames[(name as? String ?? "").uppercased()] ?? 0 }

	private static func step(_ o: [String: Any]) -> Step
	{
		var s = Step()
		for b in o["btn"] as? [Any] ?? [] { s.buttons |= button(b) }
		func pair(_ k: String) -> (Float, Float)?
		{
			guard let a = o[k] as? [Any], a.count == 2 else { return nil }
			return (Float((a[0] as? NSNumber)?.doubleValue ?? 0), Float((a[1] as? NSNumber)?.doubleValue ?? 0))
		}
		if let l = pair("l") { s.lx = l.0; s.ly = l.1 }
		if let r = pair("r") { s.rx = r.0; s.ry = r.1 }
		s.ms = (o["ms"] as? NSNumber)?.intValue ?? 0
		return s
	}

	/** Розкладка: gta6 (типово), gta5, universal — як на Mac */
	func load(_ id: String)
	{
		let file = id == "gta5" ? "anyplay-controls" : "anyplay-controls-" + id
		guard let path = Bundle.main.path(forResource: file, ofType: "json", inDirectory: "web/keys"),
			let data = FileManager.default.contents(atPath: path),
			let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else
		{
			Log.add(3, "Клавіатура: розкладку \(id) не знайдено")
			return
		}
		layout = id
		var list: [Profile] = []
		for p in j["profiles"] as? [[String: Any]] ?? []
		{
			let pid = p["id"] as? String ?? ""
			var prof = Profile(id: pid, name: p["name"] as? String ?? pid, bindings: [])
			for bo in p["bindings"] as? [[String: Any]] ?? []
			{
				var b = Binding()
				b.id = bo["id"] as? String ?? ""
				b.key = bo["key"] as? String ?? ""
				b.owner = pid
				switch bo["do"] as? String ?? "hold"
				{
				case "tap": b.kind = .tap
				case "macro": b.kind = .macro
				case "cycle": b.kind = .cycle
				case "spin": b.kind = .spin
				case "none", "precise", "hold_stick", "hotwire": b.kind = .none
				default: b.kind = .hold
				}
				b.out = KeyLayout.step(bo)
				b.steps = (bo["steps"] as? [[String: Any]] ?? []).map(KeyLayout.step)
				b.dir = ((bo["dir"] as? NSNumber)?.intValue ?? 1) < 0 ? -1 : 1
				b.when = KeyLayout.button(bo["when"])
				if let aim = bo["aim"] as? [String: Any] { b.aimWhen = KeyLayout.button(aim["when"]); b.aimOut = KeyLayout.step(aim) }
				if let hold = bo["hold"] as? [String: Any], !hold.isEmpty
				{
					b.holdOpen = true; b.holdOut = KeyLayout.step(hold); b.holdMin = max(0, (hold["ms"] as? NSNumber)?.intValue ?? 300)
				}
				if let spin = bo["spin"] as? [String: Any]
				{
					b.spinL = max(-1, min(1, (spin["l"] as? NSNumber)?.intValue ?? 0))
					b.spinR = max(-1, min(1, (spin["r"] as? NSNumber)?.intValue ?? 0))
				}
				b.profile = bo["profile"] as? String ?? ""
				if b.key == KeyLayout.menuKey { b.key = "" }
				prof.bindings.append(b)
			}
			list.append(prof)
		}
		profiles = list
		current = j["start"] as? String ?? "foot"
		releaseAll()
		Log.add(2, "Клавіатура: розкладка \(id), режим \(current)")
	}

	/** Гра почалась: визначник транспорту з нуля */
	func startGame()
	{
		let want = Prefs.feel["keyLayout"] as? String ?? "gta6"
		if profiles.isEmpty || want != layout { load(want) }
		current = "foot"
		releaseAll()
		if let v = vehicle { ap_vehicle_free(v) }
		vehicle = ap_vehicle_new(layout, false, now)
		vehicleTimer?.invalidate()
		vehicleTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tickVehicle() }
	}

	func stopGame()
	{
		vehicleTimer?.invalidate(); vehicleTimer = nil
		spinTimer?.invalidate(); spinTimer = nil
		if let v = vehicle { ap_vehicle_free(v); vehicle = nil }
		releaseAll()
	}

	func releaseAll()
	{
		active.removeAll(); held.removeAll(); taps.removeAll()
		macro.removeAll(); macroIndex = -1; macroWork?.cancel()
		spinTimer?.invalidate(); spinTimer = nil
	}

	// ── пошук ──

	private func find(_ name: String) -> Binding?
	{
		if name.isEmpty || name == KeyLayout.menuKey { return nil }
		var global: Binding?
		for p in profiles where p.id == current || p.id == "global"
		{
			for b in p.bindings where b.key.caseInsensitiveCompare(name) == .orderedSame
			{
				if p.id == current { return b }
				if global == nil { global = b }
			}
		}
		return global
	}

	private func allowed(_ b: Binding) -> Bool { b.when == 0 || output().buttons & b.when != 0 }
	private func aimNow(_ b: Binding) -> Bool { b.aimWhen != 0 && output().buttons & b.aimWhen != 0 }

	// ── натискання ──

	/** true — клавіша наша (у гру напряму не йде) */
	@discardableResult
	func press(_ name: String, _ down: Bool) -> Bool
	{
		if name.isEmpty || name == KeyLayout.menuKey { return false }
		if down { held.insert(name) } else { held.remove(name) }
		if !down
		{
			guard var b = active[name] else { return find(name) != nil }
			if b.holdMin > 0 && b.pressedAt > 0
			{
				let left = Int64(b.holdMin) - (now - b.pressedAt)
				if left > 0
				{
					let at = b.pressedAt
					DispatchQueue.main.asyncAfter(deadline: .now() + Double(left) / 1000) { [weak self] in
						guard let self = self, let again = self.active[name], again.pressedAt == at else { return }
						self.active.removeValue(forKey: name)
						self.changed()
					}
					b.pressedAt = at
					return true
				}
			}
			active.removeValue(forKey: name)
			if b.kind == .spin { updateSpin() }
			changed()
			return true
		}
		if active[name] != nil { return true }   // автоповтор
		guard var b = find(name) else { return false }
		noteGameEvent(b)
		if !allowed(b) { return true }
		if b.holdOpen && !aimNow(b)
		{
			// клавіша зброї: колесо відкрите на її секторі, поки тримаєш; відпустив — гра бере цю зброю
			macro.removeAll(); macroIndex = -1; macroWork?.cancel()
			b.kind = .hold; b.out = b.holdOut; b.pressedAt = now
			active[name] = b
			changed()
			return true
		}
		if aimNow(b) { b.kind = .hold; b.out = b.aimOut; b.profile = "" }
		switch b.kind
		{
		case .hold: active[name] = b
		case .spin: b.pressedAt = now; active[name] = b; updateSpin()
		case .tap: addTap(b.out, 90)
		case .macro: startMacro(b.steps)
		case .cycle: cycle(b)
		case .none: break
		}
		if !b.profile.isEmpty { switchProfile(b.profile) }
		changed()
		return true
	}

	/** Коліщатко миші: WheelUp / WheelDown */
	func wheel(_ name: String)
	{
		guard let b = find(name), allowed(b) else { return }
		noteGameEvent(b)
		if aimNow(b) { addTap(b.aimOut, 90) }
		else if b.kind == .macro { startMacro(b.steps) }
		else if b.kind == .cycle { cycle(b) }
		else if b.kind != .none && b.kind != .spin { addTap(b.out, 90) }
		if !b.profile.isEmpty { switchProfile(b.profile) }
		changed()
	}

	private func addTap(_ s: Step, _ ms: Int)
	{
		let id = nextTap; nextTap += 1
		taps.append((id, s))
		DispatchQueue.main.asyncAfter(deadline: .now() + Double(ms) / 1000) { [weak self] in
			guard let self = self else { return }
			self.taps.removeAll { $0.0 == id }
			self.changed()
		}
	}

	private func startMacro(_ steps: [Step])
	{
		macroWork?.cancel()
		macro = steps; macroIndex = -1
		nextMacroStep()
	}

	private func nextMacroStep()
	{
		macroIndex += 1
		if macroIndex >= macro.count { macro.removeAll(); macroIndex = -1; changed(); return }
		let w = DispatchWorkItem { [weak self] in self?.nextMacroStep() }
		macroWork = w
		DispatchQueue.main.asyncAfter(deadline: .now() + Double(max(1, macro[macroIndex].ms)) / 1000, execute: w)
		changed()
	}

	private func cycle(_ b: Binding)
	{
		let slots = profiles.first { $0.id == b.owner }?.bindings.filter { $0.kind == .macro && $0.id.hasPrefix("slot") } ?? []
		guard !slots.isEmpty else { return }
		slot = ((slot + b.dir) % slots.count + slots.count) % slots.count
		startMacro(slots[slot].steps)
	}

	private func updateSpin()
	{
		let any = active.values.contains { $0.kind == .spin }
		if any && spinTimer == nil
		{
			spinTimer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] _ in self?.changed() }
		}
		else if !any { spinTimer?.invalidate(); spinTimer = nil }
	}

	// ── режими ──

	private func switchProfile(_ target: String)
	{
		let id = target == "toggle" ? (current == "foot" ? "vehicle" : "foot") : target
		setProfile(id, manual: true)
	}

	private func setProfile(_ id: String, manual: Bool)
	{
		guard id != current, profiles.contains(where: { $0.id == id }) else { return }
		let was = current
		current = id
		if manual, let v = vehicle { ap_vehicle_manual(v, id != "foot", now) }
		// затиснуті W A S D, газ і гальмо одразу діють у новому режимі
		let keep = held
		active.removeAll(); taps.removeAll(); macro.removeAll(); macroIndex = -1
		spinTimer?.invalidate(); spinTimer = nil
		for k in keep
		{
			guard var b = find(k), b.kind == .hold, allowed(b) else { continue }
			if aimNow(b) { b.out = b.aimOut }
			active[k] = b
		}
		Log.add(2, "Клавіатура: режим \(was) → \(id)\(manual ? " (вручну)" : "")")
		onMode?(profiles.first { $0.id == id }?.name ?? id)
		changed()
	}

	// ── визначник транспорту (як AnyPlayInput::NoteGameEvent і TickVehicle на Mac) ──

	private func noteGameEvent(_ b: Binding)
	{
		guard let v = vehicle else { return }
		let t = now, global = b.owner == "global"
		if global && b.id == "pause" { ap_vehicle_event(v, Int32(AP_VEH_MENU_TOGGLE), t) }
		else if global && (b.id == "map" || b.id == "ps") { ap_vehicle_event(v, Int32(AP_VEH_MENU_ON), t) }
		else if !global && b.kind != .none { ap_vehicle_event(v, Int32(AP_VEH_MENU_OFF), t) }
		if !global { ap_vehicle_event(v, Int32(AP_VEH_ACTIVITY), t) }
		var pyramid = b.kind == .hold && b.out.buttons & Btn.pyramid != 0
		var wheel = b.kind == .cycle || b.holdOpen || (b.kind != .macro && b.out.buttons & Btn.l1 != 0)
		if b.kind == .macro { for s in b.steps { pyramid = pyramid || s.buttons & Btn.pyramid != 0; wheel = wheel || s.buttons & Btn.l1 != 0 } }
		if !global && pyramid { ap_vehicle_event(v, Int32(AP_VEH_INTERACT), t) }
		if !global && wheel && b.owner == "foot" { ap_vehicle_event(v, Int32(AP_VEH_WEAPON), t) }
		if !global && b.kind == .hold && b.out.buttons & Btn.box != 0 { ap_vehicle_event(v, Int32(AP_VEH_BOX), t) }
		if b.kind == .spin { ap_vehicle_event(v, Int32(AP_VEH_MINIGAME), t) }
		flushVehicleLog()
	}

	func noteTriggers(_ tl: Int, _ tr: Int, _ data: [UInt8])
	{
		guard let v = vehicle else { return }
		var d = data
		if d.count < 20 { d += [UInt8](repeating: 0, count: 20 - d.count) }
		d.withUnsafeBufferPointer { ap_vehicle_triggers(v, UInt8(truncatingIfNeeded: tl), UInt8(truncatingIfNeeded: tr), $0.baseAddress, now) }
		tickVehicle()
	}

	func noteRumble(_ l: Int, _ r: Int)
	{
		guard let v = vehicle else { return }
		ap_vehicle_rumble(v, UInt8(clamping: l), UInt8(clamping: r), now)
	}

	private func tickVehicle()
	{
		guard let v = vehicle, layout != "universal" else { return }
		let t = now, o = output()
		ap_vehicle_aiming(v, current == "foot" && o.buttons & (KeyLayout.l2 | KeyLayout.r2) != 0, t)
		ap_vehicle_moving(v, current == "vehicle" && (o.buttons & (KeyLayout.l2 | KeyLayout.r2) != 0 || o.lx != 0 || o.ly != 0), t)
		if active.values.contains(where: { $0.kind == .spin }) { ap_vehicle_event(v, Int32(AP_VEH_MINIGAME), t) }
		let verdict = ap_vehicle_tick(v, t)
		flushVehicleLog()
		if verdict > 0 && current == "foot" { setProfile("vehicle", manual: false) }
		else if verdict < 0 && current != "foot" { setProfile("foot", manual: false) }
	}

	private func flushVehicleLog()
	{
		guard let v = vehicle else { return }
		var buf = [CChar](repeating: 0, count: 512)
		ap_vehicle_take_log(v, &buf, Int32(buf.count))
		let s = String(cString: buf)
		if !s.isEmpty { Log.add(2, "Транспорт: " + s) }
	}

	// ── що йде в гру ──

	func output() -> Step
	{
		var sum = Step()
		func add(_ s: Step) { sum.buttons |= s.buttons; sum.lx += s.lx; sum.ly += s.ly; sum.rx += s.rx; sum.ry += s.ry }
		for b in active.values where b.kind != .spin { add(b.out) }
		for t in taps { add(t.1) }
		if macroIndex >= 0 && macroIndex < macro.count { add(macro[macroIndex]) }
		let t = now
		for b in active.values where b.kind == .spin
		{
			let turns = Double((t - b.pressedAt) % 800) / 800
			func spin(_ dir: Int) -> (Float, Float) { let a = 2 * Double.pi * turns * (dir < 0 ? -1 : 1); return (Float(sin(a)), Float(-cos(a))) }
			if b.spinL != 0 { (sum.lx, sum.ly) = spin(b.spinL) }
			if b.spinR != 0 { (sum.rx, sum.ry) = spin(b.spinR) }
		}
		return sum
	}

	/** Стан геймпада з клавіатури (і кнопок миші) */
	func padState() -> PadState
	{
		let o = output()
		var s = PadState()
		s.buttons = o.buttons & 0xFFFF
		if o.buttons & KeyLayout.l2 != 0 { s.l2 = 255 }
		if o.buttons & KeyLayout.r2 != 0 { s.r2 = 255 }
		func ax(_ v: Float) -> Int16 { Int16((max(-1, min(1, v)) * 32767).rounded()) }
		s.lx = ax(o.lx); s.ly = ax(o.ly); s.rx = ax(o.rx); s.ry = ax(o.ry)
		return s
	}

	var modeName: String { profiles.first { $0.id == current }?.name ?? current }

	private func changed() { onChange?() }

	// ── назви клавіш, як у файлах розкладок (за фізичним місцем: українська розкладка не заважає) ──

	static func name(hid c: Int) -> String?
	{
		switch c
		{
		case 4...29: return String(UnicodeScalar(UInt8(65 + c - 4)))
		case 30...38: return String(c - 29)
		case 39: return "0"
		case 40, 88: return "Enter"
		case 41: return "Esc"
		case 42: return "Backspace"
		case 43: return "Tab"
		case 44: return "Space"
		case 45: return "-"
		case 46: return "="
		case 47: return "["
		case 48: return "]"
		case 49: return "\\"
		case 51: return ";"
		case 52: return "'"
		case 53, 100: return "`"
		case 54: return ","
		case 55: return "."
		case 56: return "/"
		case 57: return "CapsLock"
		case 58...69: return "F\(c - 57)"
		case 74: return "Home"
		case 79: return "Right"
		case 80: return "Left"
		case 81: return "Down"
		case 82: return "Up"
		case 89...97: return "Num\(c - 88)"
		case 98: return "Num0"
		case 224, 228: return "Ctrl"
		case 225, 229: return "Shift"
		case 226, 230: return "Alt"
		case 227, 231: return "Cmd"
		default: return nil
		}
	}
}
