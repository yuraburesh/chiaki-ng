// AnyPlay для iPhone та iPad: екран гри (як StreamActivity на Android, перша версія).
// Сервер дає ключ PSN → шукаємо приставку → пробиваємо з'єднання → відео, звук, керування.
// Вертикально картинка 16:9 угорі, кнопки під нею; горизонтально картинка на весь екран, кнопки поверх.
import UIKit
import GameController

final class GameViewController: UIViewController, SessionDelegate, WebHost
{
	private let target: PlayReady
	private let admin: Bool
	private let videoView = VideoView()
	private let pad = GamepadOverlay()
	private var session: Session?
	private let loading = UIView()
	private let loadingText = UILabel()
	private let spinner = UIActivityIndicatorView(style: .large)
	private let hud = UILabel()
	private var menu: WebPage?
	private var banner: UIView?
	private var timers: [Timer] = []
	private var touchState = PadState()
	private var lastSent = PadState()
	private var inputLogged = false
	private var blockLogged = false
	private var endAt: Date?            // кінець гри за годинником телефона
	private var continues = false
	private var guest = false
	private var reminded = false
	private var ended = false
	private var connected = false
	private var menuCombo = false
	private var extraButtons: UInt32 = 0

	// ── 145: головна під час гри ──
	/** Гра, з якої вийшли на головну, не закриваючи її */
	static weak var parked: GameViewController?
	/** 147: гра, що зараз іде (для закриття програми) */
	static weak var active: GameViewController?

	func terminateNow()
	{
		guard !ended else { return }
		ended = true
		Log.add(2, "Програму закрили посеред гри: відпускаємо приставку")
		timers.forEach { $0.invalidate() }
		session?.closeNow()
		session = nil
	}
	private var parkedAway = false

	private func park()
	{
		guard !ended else { return }
		parkedAway = true
		GameViewController.parked = self
		pad.releaseAll(); touchState = PadState(); KeyLayout.shared.releaseAll()
		sendController()
		Log.add(2, "Вийшли на головну, гра триває")
		presentingViewController?.dismiss(animated: true) { [onFinish] in onFinish?() }
	}

	/** Повернутись у гру з головної */
	func unpark()
	{
		parkedAway = false
		if GameViewController.parked === self { GameViewController.parked = nil }
		videoView.resume()
		session?.requestIDR()
		becomeFirstResponder()
		Log.add(2, "Повернулись з головної в гру")
	}

	var isRunning: Bool { !ended && session != nil }

	private var hoverLast: CGPoint?
	@objc private func hovered(_ g: UIHoverGestureRecognizer)
	{
		let p = g.location(in: view)
		switch g.state
		{
		case .began: hoverLast = p
		case .changed:
			if let l = hoverLast, menu == nil { GamepadInput.shared.pointerDelta(p.x - l.x, p.y - l.y) }
			hoverLast = p
		default: hoverLast = nil
		}
	}

	/** 152: iPadOS 27 віддає кнопку PS (Home) системі, і програма сама змінити це не може (так влаштувала Apple).
	 *  Тому один раз, коли грають геймпадом, пропонуємо відкрити саме той екран Параметрів, де це вмикається */
	private func askHomeButtonOnce()
	{
		let key = "askedHomeButton152"
		guard !UserDefaults.standard.bool(forKey: key), GamepadInput.shared.connected, presentedViewController == nil else { return }
		if #available(iOS 27.0, *) {} else { return }
		UserDefaults.standard.set(true, forKey: key)
		let a = UIAlertController(title: "Кнопка PS на геймпаді",
			message: "iPad забирає кнопку PS собі (відкриває свої панелі). Щоб вона працювала як на приставці, у Параметрах, що відкриються, для кнопки Home у програмах обери передавати її програмі. Це треба зробити лише раз.\n\nБез цього меню приставки відкривається так: Create + Options разом, далі «Кнопка PS».",
			preferredStyle: .alert)
		a.addAction(UIAlertAction(title: "Не зараз", style: .cancel))
		a.addAction(UIAlertAction(title: "Відкрити Параметри", style: .default) { _ in GamepadInput.openHomeButtonSettings() })
		present(a, animated: true)
	}

	private var hintLabel: UILabel?
	private func showHint(_ text: String)
	{
		hintLabel?.removeFromSuperview()
		let l = UILabel()
		l.text = "  " + text + "  "
		l.font = .systemFont(ofSize: 15, weight: .semibold)
		l.textColor = .white
		l.backgroundColor = UIColor(red: 34 / 255, green: 29 / 255, blue: 46 / 255, alpha: 0.85)
		l.layer.cornerRadius = 12
		l.layer.masksToBounds = true
		l.sizeToFit()
		l.frame.size.height = 34
		l.center = CGPoint(x: view.bounds.midX, y: view.safeAreaInsets.top + 46)
		l.isUserInteractionEnabled = false
		view.addSubview(l)
		hintLabel = l
		UIView.animate(withDuration: 0.4, delay: 1.8, options: []) { l.alpha = 0 } completion: { _ in l.removeFromSuperview() }
	}
	private var busyRetries = 0
	private var watchFrames: UInt64 = 0
	private var watchAt = Date()
	private var watchShown = false
	private var navHeld: Set<String> = []
	private var heldFromMenu: UInt32 = 0

	/** 139: стрілки чи стік — пункт меню, ✕ — натиснути, ○ — назад (на першому екрані — повернутись у гру) */
	private func menuNav(_ p: PadState)
	{
		let t: Int16 = 20000
		var now: Set<String> = []
		if p.buttons & Btn.up != 0 || p.ly < -t || p.ry < -t { now.insert("up") }
		if p.buttons & Btn.down != 0 || p.ly > t || p.ry > t { now.insert("down") }
		if p.buttons & Btn.left != 0 || p.lx < -t || p.rx < -t { now.insert("left") }
		if p.buttons & Btn.right != 0 || p.lx > t || p.rx > t { now.insert("right") }
		if p.buttons & Btn.cross != 0 { now.insert("ok") }
		if p.buttons & Btn.moon != 0 { now.insert("back") }
		for c in ["up", "down", "left", "right", "ok", "back"] where now.contains(c) && !navHeld.contains(c)
		{
			menu?.eval("window.__anyplayPad && window.__anyplayPad('\(c)')")
		}
		navHeld = now
	}
	private var statPrev: (Date, UInt64, UInt64, UInt64)?
	private var lossNow: Double = 0
	var onFinish: (() -> Void)?

	init(target: PlayReady, admin: Bool)
	{
		self.target = target
		self.admin = admin
		guest = target.guest
		super.init(nibName: nil, bundle: nil)
		modalPresentationStyle = .fullScreen
	}

	required init?(coder: NSCoder) { fatalError() }

	override var prefersStatusBarHidden: Bool { true }
	override var prefersHomeIndicatorAutoHidden: Bool { true }
	// 134: миша/трекпад на iPad крутять камеру (як на комп'ютері): вказівник захоплює гра
	override var prefersPointerLocked: Bool { true }
	override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
	override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }

	override func viewDidLoad()
	{
		super.viewDidLoad()
		GameViewController.active = self
		Sticks.reload()
		view.backgroundColor = .black
		view.addSubview(videoView)
		pad.onChange = { [weak self] s in self?.touchState = s; self?.sendController() }
		pad.onMenu = { [weak self] in self?.showMenu("menu") }
		pad.onTouchpad = { [weak self] id, x, y, up in self?.session?.touch(id: id, x: x, y: y, up: up) ?? -1 }
		pad.isHidden = !Prefs.controls
		view.addSubview(pad)

		// 128: статистика — тонкий рядок угорі
		hud.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
		hud.textColor = UIColor(white: 1, alpha: 0.88)
		hud.backgroundColor = UIColor(red: 34 / 255, green: 29 / 255, blue: 46 / 255, alpha: 0.72)
		hud.layer.cornerRadius = 10
		hud.layer.masksToBounds = true
		hud.textAlignment = .center
		hud.isHidden = true
		hud.numberOfLines = 1
		hud.adjustsFontSizeToFitWidth = true
		hud.minimumScaleFactor = 0.75
		hud.isUserInteractionEnabled = false
		view.addSubview(hud)

		loading.backgroundColor = UIColor(red: 0x2b / 255.0, green: 0x27 / 255.0, blue: 0x40 / 255.0, alpha: 1)
		loadingText.textColor = .white
		loadingText.font = .systemFont(ofSize: 16, weight: .medium)
		loadingText.numberOfLines = 0
		loadingText.textAlignment = .center
		spinner.color = .white
		spinner.startAnimating()
		loading.addSubview(spinner)
		loading.addSubview(loadingText)
		view.addSubview(loading)
		setLoading("Шукаємо приставку…")

		GamepadInput.shared.start()
		GamepadInput.shared.onChange = { [weak self] _ in
			// 138: ховаємо кнопки лише від справжнього геймпада (не від руху миші чи клавіатури)
			if GamepadInput.shared.gamepadActive { self?.pad.physicalInput() }
			self?.sendController()
		}
		// 145: клавіатура й миша як на Mac; ` — меню AnyPlay; режим «Пішки/Транспорт/Авіація» — підказка на екрані
		KeyLayout.shared.startGame()
		// 152: події геймпада — лише в GameController (iPad не перетворює їх на свої дії інтерфейсу)
		if #available(iOS 18.0, *) { view.addInteraction(GCEventInteraction()) }
		// 150: трекпад без захоплення курсора — рух курсора над грою теж крутить камеру
		let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
		view.addGestureRecognizer(hover)
		KeyLayout.shared.onMode = { [weak self] name in self?.showHint(name) }
		GamepadInput.shared.onMenuKey = { [weak self] in
			guard let self = self else { return }
			if self.menu != nil { self.closeMenu() } else { self.showMenu("menu") }
		}
		videoView.onNeedKeyFrame = { [weak self] in self?.session?.requestIDR() }
		NotificationCenter.default.addObserver(self, selector: #selector(background), name: UIApplication.didEnterBackgroundNotification, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(foreground), name: UIApplication.didBecomeActiveNotification, object: nil)
		UIApplication.shared.isIdleTimerDisabled = true
		connect()
		timers.append(Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.heartbeat() })
		timers.append(Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() })
	}

	// 141: клавіатура через UIKit (додатково до GameController)
	override var canBecomeFirstResponder: Bool { true }

	override func viewDidAppear(_ animated: Bool)
	{
		super.viewDidAppear(animated)
		becomeFirstResponder()
	}

	private func keyPresses(_ presses: Set<UIPress>, down: Bool) -> Bool
	{
		var handled = false
		for p in presses
		{
			guard let k = p.key, !k.modifierFlags.contains(.command) else { continue }
			GamepadInput.shared.uiPress(k.keyCode.rawValue, down: down)
			handled = true
		}
		return handled
	}

	override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) { if !keyPresses(presses, down: true) { super.pressesBegan(presses, with: event) } }
	override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) { if !keyPresses(presses, down: false) { super.pressesEnded(presses, with: event) } }
	override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) { if !keyPresses(presses, down: false) { super.pressesCancelled(presses, with: event) } }

	override func viewDidLayoutSubviews()
	{
		super.viewDidLayoutSubviews()
		let b = view.bounds
		let portrait = b.height > b.width
		if portrait && Prefs.controls
		{
			let top = view.safeAreaInsets.top
			videoView.frame = CGRect(x: 0, y: top, width: b.width, height: b.width * 9 / 16)
			pad.videoBottom = videoView.frame.maxY
		}
		else
		{
			videoView.frame = b
			pad.videoBottom = 0
		}
		pad.frame = b
		loading.frame = b
		spinner.center = CGPoint(x: b.midX, y: b.midY - 30)
		loadingText.frame = CGRect(x: 24, y: b.midY, width: b.width - 48, height: 80)
		menu?.web.frame = b
		layoutHud()
	}

	private func setLoading(_ text: String?)
	{
		if let t = text
		{
			loadingText.text = t
			loading.isHidden = false
			view.bringSubviewToFront(loading)
		}
		else
		{
			UIView.animate(withDuration: 0.25, animations: { self.loading.alpha = 0 }) { _ in self.loading.isHidden = true; self.loading.alpha = 1 }
		}
	}

	// ── з'єднання ──
	private func connect()
	{
		let s = Session(video: videoView)
		s.delegate = self
		session = s
		if switchView != nil { videoView.resetKeepImage() } else { videoView.reset() }
		connected = false
		let profile = Quality.profile
		if let err = s.create(target: target, profile: profile)
		{
			end(err)
			return
		}
		if target.lanAddr != nil
		{
			// 136: домашня мережа — без PSN, одразу гра
			loadingText.text = "Приставка поруч, підключаємось напряму…"
			if s.start() != 0 { end("Не вдалося почати гру. Спробуй ще раз.") }
			return
		}
		let duid = target.duid
		DispatchQueue.global(qos: .userInitiated).async {
			let watch = Timer(timeInterval: 0.5, repeats: true) { [weak self, weak s] _ in
				guard let st = s?.psnStep else { return }
				let text = ["Шукаємо приставку…", "Перевіряємо роутер…", "Зв'язуємося з PSN…", "Готуємо з'єднання…", "Чекаємо приставку…", "З'єднуємося з приставкою…", "Запускаємо гру…"][min(max(st, 0), 6)]
				self?.loadingText.text = text
			}
			DispatchQueue.main.async { RunLoop.main.add(watch, forMode: .common) }
			let r = s.psnConnect(duid: duid)
			DispatchQueue.main.async {
				watch.invalidate()
				guard self.session === s, !self.ended else { return }
				if r != 0
				{
					self.end("Не вдалося з'єднатися з приставкою (крок \(s.psnStep), помилка \(r)). Перевір інтернет і спробуй ще раз.")
					return
				}
				self.loadingText.text = "Запускаємо гру…"
				if s.start() != 0 { self.end("Не вдалося почати гру. Спробуй ще раз.") }
			}
		}
	}

	func sessionConnected()
	{
		connected = true
		if switchView != nil { switchFrames = videoView.shownCount; finishSwitch() }
		askHomeButtonOnce()
		watchAt = Date(); watchShown = false
		Log.add(2, "Курсор захоплено: \(view.window?.windowScene?.pointerLockState?.isLocked == true ? "так" : "ні")")
		Log.add(2, "Кнопки на екрані: показ \(Prefs.controls), ховати \(Prefs.autoHide), сховані \(Prefs.padHidden.sorted()), прозорість \(Prefs.padAlpha), розмір \(Prefs.padScale); клавіатура \(GamepadInput.shared.keyboardConnected), розкладка \(KeyLayout.shared.layout)")
		setLoading(nil)
		Haptics.shared.resetTriggers()
		heartbeat()
	}

	func sessionQuit(reason: Int, text: String)
	{
		guard !ended else { return }
		Log.add(3, "Трансляція закрилась: \(reason) \(text)")
		if backgrounded
		{
			session?.close(); session = nil; connected = false
			return
		}
		let why = Session.quitText(reason) + " " + text
		// 143: попередня гра ще не закрилась на приставці (перезапуск програми) — приставка звільняється за кілька секунд
		if why.contains("already in use") && busyRetries < 4
		{
			busyRetries += 1
			Log.add(2, "Приставка ще зайнята попередньою грою: спроба \(busyRetries) за 5 с")
			session?.close(); session = nil; connected = false
			setLoading("Приставка ще закриває попередню гру. Пробуємо ще раз…")
			DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.reconnectFresh() }
			return
		}
		if why.lowercased().contains("shutting down")
		{
			end("Приставку вимкнули або перевели в режим спокою. Увімкни її і натисни «Грати» ще раз.")
			return
		}
		let msg = Session.quitIsError(reason)
			? "Приставка завершила трансляцію (\(Session.quitText(reason))). Так буває, коли PS5 перезапускається або до неї підключився інший пристрій."
			: "Трансляцію завершено."
		end(msg)
	}

	func sessionRumble(left: Int, right: Int) { Haptics.shared.rumble(left: left, right: right); KeyLayout.shared.noteRumble(left, right) }
	// 130: адаптивні курки — окрема фішка, вмикається у «Вібрації»; вимкнено — курки звичайні
	func sessionTriggers(typeL: Int, typeR: Int, data: [UInt8])
	{
		KeyLayout.shared.noteTriggers(typeL, typeR, data)   // 145: клавіатура сама перемикає «пішки / транспорт»
		if Prefs.feel["adaptive"] as? Bool ?? false { Haptics.shared.triggerEffects(typeL: typeL, typeR: typeR, data: data) }
		else { Haptics.shared.triggerEffects(typeL: 0, typeR: 0, data: []) }
	}

	private func sendController()
	{
		if parkedAway { if let s = session, connected, lastSent != PadState() { lastSent = PadState(); s.setController(PadState()) }; return }
		guard connected, let s = session else
		{
			if !blockLogged && (touchState != PadState() || GamepadInput.shared.state != PadState())
			{
				blockLogged = true
				Log.add(3, "Ввід: натискання не пішло в гру — з'єднання ще не готове (connected \(connected), сесія \(session != nil))")
			}
			return
		}
		var st = touchState
		if menu != nil { st = PadState() }   // поки відкрите меню, екранні кнопки в гру не йдуть
		// 139: Create + Options разом на геймпаді (Tab на клавіатурі) — меню AnyPlay; у гру ця пара не йде
		var phys = GamepadInput.shared.state
		let pair = Btn.share | Btn.options
		if phys.buttons & pair == pair
		{
			if !menuCombo
			{
				menuCombo = true
				Haptics.shared.tap(.ui)
				if menu != nil { closeMenu() } else { DispatchQueue.main.async { self.showMenu("menu") } }
			}
		}
		else if phys.buttons & pair == 0 { menuCombo = false }
		if menuCombo { phys.buttons &= ~pair }
		// 139: меню відкрите — геймпад і клавіатура керують меню, а не грою
		if menu != nil { menuNav(phys); heldFromMenu = phys.buttons; phys = PadState() }
		else
		{
			navHeld = []
			// кнопка, якою закрили меню (○), не йде в гру, поки її не відпустять
			heldFromMenu &= phys.buttons
			phys.buttons &= ~heldFromMenu
		}
		var merged = st.merged(phys)
		merged.buttons |= extraButtons
		if merged == lastSent { return }
		lastSent = merged
		s.setController(merged)
		if !inputLogged && merged != PadState()
		{
			inputLogged = true
			Log.add(2, "Ввід: перше натискання пішло в гру (кнопки 0x\(String(merged.buttons, radix: 16)), з екрана: \(st != PadState()), геймпад/клавіатура: \(GamepadInput.shared.state != PadState()))")
		}
	}

	// ── сервер: час гри, кінець, телеметрія ──
	private func heartbeat()
	{
		guard !ended else { return }
		let stats = statsJson()
		Task { @MainActor in
			let r = await Cloud.heartbeat(streaming: true, stats: stats)
			if r.status == 401 { end("Доступ скасовано адміністратором."); return }
			guard r.ok else { return }
			if let left = r.json["left"] as? Double { endAt = Date().addingTimeInterval(left) }
			else if let left = r.json["left"] as? Int { endAt = Date().addingTimeInterval(Double(left)) }
			continues = r.json["continues"] as? Bool ?? false
			if r.json["sendLog"] as? Bool == true { Cloud.uploadLog(reason: "request", note: "Адміністратор попросив журнал (гра)") }
			guest = r.json["guest"] as? Bool ?? guest
			if (r.json["continue"] as? Bool) == false
			{
				let reason = r.str("reason"), text = r.str("text")
				end(!text.isEmpty ? text : reason == "kicked" ? "Сеанс завершив адміністратор AnyPlay." : "Час твоєї броні вийшов. Дякуємо за гру!")
			}
		}
	}

	private func statsJson() -> [String: Any]?
	{
		guard connected, let s = session else { return nil }
		let (fin, bytes, _) = s.counters()
		let p = Quality.profile
		return ["platform": "ios", "build": Cloud.build, "input": GamepadInput.shared.connected ? "gamepad" : "touch", "layout": "universal", "mode": "",
			"quality": Quality.level, "auto": Quality.auto, "width": p.width, "height": p.height, "codec": "h265",
			"fpsStream": 0, "fpsShown": 0, "bitrate": Double(bytes) * 8 / 1e6 / max(1, Date().timeIntervalSince(startedAt)), "loss": lossNow * 100,
			"dropped": 0, "local": false, "frames": fin]
	}

	private let startedAt = Date()

	private func tick()
	{
		guard let s = session, connected else { return }
		lossNow = s.packetLoss
		// статистика (як на комп'ютері): кадри, швидкість, пінг, втрати
		let (fin, bytes, lost) = s.counters()
		let now = Date()
		// 142: приставку вимкнули чи пропав інтернет — кадри перестали йти. Не висіти з чорним екраном:
		// за 5 с показати, що чекаємо, за 25 с — завершити з поясненням
		if !backgrounded
		{
			if fin != watchFrames { watchFrames = fin; watchAt = now; if watchShown { watchShown = false; setLoading(nil) } }
			else
			{
				let quiet = now.timeIntervalSince(watchAt)
				if quiet > 5 && !watchShown && menu == nil { watchShown = true; setLoading("Немає картинки від приставки. Чекаємо…") }
				if quiet > 25
				{
					Log.add(3, "Від приставки \(Int(quiet)) с немає кадрів: трансляцію закрито")
					end("Зв'язок з приставкою пропав: вона вимкнулась або перестав працювати інтернет.")
					return
				}
			}
		}
		else { watchAt = now }
		if Prefs.hud > 0, let prev = statPrev
		{
			let dt = max(0.5, now.timeIntervalSince(prev.0))
			let fps = Int(Double(fin - prev.1) / dt)
			let mbps = Double(bytes - prev.2) * 8 / dt / 1e6
			let target = max(1, Int(Quality.profile.fps))
			let fpsColor: UIColor = fps >= target * 9 / 10 ? UIColor(red: 201 / 255, green: 245 / 255, blue: 216 / 255, alpha: 1)
				: fps >= target * 6 / 10 ? UIColor(red: 1, green: 217 / 255, blue: 160 / 255, alpha: 1) : UIColor(red: 1, green: 154 / 255, blue: 154 / 255, alpha: 1)
			let mute = UIColor(white: 1, alpha: 0.55), ink = UIColor(white: 1, alpha: 0.92)
			let t = NSMutableAttributedString()
			func add(_ label: String?, _ value: String, _ c: UIColor)
			{
				if t.length > 0 { t.append(NSAttributedString(string: "   ")) }
				if let l = label { t.append(NSAttributedString(string: l + " ", attributes: [.foregroundColor: mute])) }
				t.append(NSAttributedString(string: value.replacingOccurrences(of: ".", with: ","), attributes: [.foregroundColor: c]))
			}
			if Prefs.hud == 2
			{
				add("Кадри", "\(fps)/\(target)", fpsColor)
				add("Швидкість", String(format: "%.1f Мбіт/с", mbps), ink)
				add("Пінг", "\(s.rttMs) мс", ink)
				add("Втрати", String(format: "%.1f%%", lossNow * 100), ink)
				add("Пропущено", "\(Int(lost - prev.3))", mute)
				add(nil, "\(Quality.profile.height)p H.265", mute)
			}
			else
			{
				add(nil, "\(fps) FPS", fpsColor)
				add(nil, String(format: "%.1f Мбіт/с", mbps), ink)
				add(nil, "\(s.rttMs) мс", ink)
				add(nil, String(format: "%.1f%%", lossNow * 100), ink)
			}
			hud.attributedText = t
			hud.isHidden = menu != nil
			layoutHud()
		}
		else { hud.isHidden = true }
		statPrev = (now, fin, bytes, lost)
		// нагадування за 10 хвилин до кінця
		if let e = endAt, !admin, !guest, !continues
		{
			let left = e.timeIntervalSinceNow
			if left > 11 * 60 { reminded = false }
			else if left > 0 && left <= 10 * 60 && !reminded && menu == nil { reminded = true; showBanner(Int((left + 59) / 60)) }
		}
	}

	private func layoutHud()
	{
		guard !hud.isHidden else { return }
		let safe = view.safeAreaInsets
		let maxW = view.bounds.width - safe.left - safe.right - 16
		let size = hud.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: 20))
		let w = min(maxW, size.width + 18)
		let x = safe.left + (view.bounds.width - safe.left - safe.right - w) / 2
		let y = view.bounds.height > view.bounds.width ? max(videoView.frame.minY, safe.top) + 6 : max(6, safe.top)
		hud.frame = CGRect(x: x, y: y, width: w, height: 20)
		view.bringSubviewToFront(hud)
	}

	private func showBanner(_ minutes: Int)
	{
		banner?.removeFromSuperview()
		let b = UIButton(type: .system)
		b.setTitle("Лишилось \(minutes) хв. Продовжити бронювання?", for: .normal)
		b.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
		b.setTitleColor(UIColor(red: 1, green: 0.85, blue: 0.63, alpha: 1), for: .normal)
		b.backgroundColor = UIColor(red: 42 / 255, green: 38 / 255, blue: 57 / 255, alpha: 0.95)
		b.layer.cornerRadius = 8
		b.contentEdgeInsets = UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
		b.addAction(UIAction { [weak self] _ in self?.banner?.removeFromSuperview(); self?.showMenu("menu:extend") }, for: .touchUpInside)
		b.sizeToFit()
		b.center = CGPoint(x: view.bounds.midX, y: view.safeAreaInsets.top + b.bounds.height / 2 + 12)
		view.addSubview(b)
		banner = b
		DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak b] in b?.removeFromSuperview() }
	}

	// ── меню під час гри: та сама сторінка, що на Android ──
	private func showMenu(_ page: String)
	{
		guard menu == nil, !ended else { return }
		pad.releaseAll()
		let m = WebPage(page: page, transparent: true, host: self)
		m.presenter = self
		m.onClose = { [weak self] in self?.closeMenu() }
		m.web.frame = view.bounds
		m.web.alpha = 0
		view.addSubview(m.web)
		UIView.animate(withDuration: 0.18) { m.web.alpha = 1 }
		menu = m
		hud.isHidden = true
	}

	private func closeMenu()
	{
		guard let m = menu else { return }
		menu = nil
		m.detach()
		UIView.animate(withDuration: 0.15, animations: { m.web.alpha = 0 }) { _ in m.web.removeFromSuperview(); self.becomeFirstResponder() }
		sendController()
	}

	func info() -> String
	{
		let left = endAt.map { Int(max(0, $0.timeIntervalSinceNow)) } ?? -1
		return jsonText(["left": left, "loss": lossNow, "controls": Prefs.controls, "admin": admin, "guest": guest, "helperOf": "",
			"quality": Quality.name, "autoHide": Prefs.autoHide])
	}

	func action(_ name: String, _ arg: String)
	{
		switch name
		{
		case "controls":
			Prefs.controls.toggle()
			pad.isHidden = !Prefs.controls
			view.setNeedsLayout()
			closeMenu()
		case "exit":
			closeMenu()
			finish()
		case "psSettings": GamepadInput.openHomeButtonSettings()
		case "psTap":
			// 146: кнопка PS з меню AnyPlay — працює одразу, без налаштувань iPad (iPadOS 27 забирає PS геймпада собі)
			closeMenu()
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
				guard let self = self else { return }
				self.extraButtons = Btn.ps; self.sendController()
				Log.add(2, "Кнопка PS з меню AnyPlay")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.extraButtons = 0; self?.sendController() }
			}
		case "home":
			// 145: на головну, а гра лишається: «Грати» на головній повертає в неї без нового підключення
			closeMenu()
			park()
		case "autohide":
			Prefs.autoHide = Int(arg) ?? -1
			pad.scheduleHide()
		case "layout":
			// 137: «Джойстик» — які кнопки на екрані, L3/R3, розмір, прозорість
			let v = PadSettingsViewController()
			v.onClose = { [weak self] in self?.pad.reloadPrefs() }
			present(v, animated: true)
		case "refresh":
			heartbeat()
		default:
			break
		}
	}

	// 151: нова якість діє з нового підключення (так влаштована PS5). Щоб це не виглядало як вимкнули й увімкнули:
	// остання картинка лишається, плавно розмивається, посередині «Міняємо якість…», нова картинка проступає крізь розмиття
	private var switchView: UIVisualEffectView?

	func qualityChanged()
	{
		closeMenu()
		guard !ended else { return }
		let lan = target.lanAddr != nil
		Log.add(2, "Якість: \(Quality.name), плавне перепідключення (\(lan ? "домашня мережа" : "PSN"))")
		if switchView == nil
		{
			let v = UIVisualEffectView(effect: nil)
			v.frame = view.bounds
			v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
			let spin = UIActivityIndicatorView(style: .medium)
			spin.color = .white
			spin.startAnimating()
			let l = UILabel()
			l.text = "Міняємо якість: \(Quality.name). Кілька секунд…"
			l.textColor = .white
			l.font = .systemFont(ofSize: 15, weight: .medium)
			l.textAlignment = .center
			l.numberOfLines = 0
			let col = UIStackView(arrangedSubviews: [spin, l])
			col.axis = .vertical
			col.spacing = 10
			col.alignment = .center
			col.alpha = 0
			col.translatesAutoresizingMaskIntoConstraints = false
			v.contentView.addSubview(col)
			NSLayoutConstraint.activate([col.centerXAnchor.constraint(equalTo: v.contentView.centerXAnchor), col.centerYAnchor.constraint(equalTo: v.contentView.centerYAnchor),
				col.widthAnchor.constraint(lessThanOrEqualTo: v.contentView.widthAnchor, constant: -48)])
			view.insertSubview(v, aboveSubview: pad)
			switchView = v
			UIView.animate(withDuration: 0.35) { v.effect = UIBlurEffect(style: .dark); col.alpha = 1 }
		}
		session?.close()
		session = nil
		connected = false
		// приставці потрібна мить, щоб закрити попередню трансляцію; через PSN — довше
		DispatchQueue.main.asyncAfter(deadline: .now() + (lan ? 0.8 : 2.5)) { [weak self] in self?.reconnectFresh() }
	}

	/** Нова картинка пішла — розмиття плавно тане */
	private func finishSwitch(_ tries: Int = 0)
	{
		guard let v = switchView else { return }
		if videoView.shownCount == switchFrames && tries < 40
		{
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.finishSwitch(tries + 1) }
			return
		}
		switchView = nil
		UIView.animate(withDuration: 0.45, animations: { v.effect = nil; v.contentView.alpha = 0 }) { _ in v.removeFromSuperview() }
	}
	private var switchFrames: UInt64 = 0

	/** Нове підключення зі свіжим ключем від сервера */
	private func reconnectFresh()
	{
		guard !ended else { return }
		Task { @MainActor in
			let r = await Cloud.session()
			guard r.ok, r.str("state") == "play" else { end("Час твоєї броні вийшов. Дякуємо за гру!"); return }
			connect()
		}
	}

	// ── кінець ──
	// 134: згорнули — у фоні iOS не дає тримати трансляцію, тож закриваємо її, але гра не виходить на головну:
	// повернувся, і програма сама підключається знову. Кнопки й клавіші відпускаємо, щоб нічого не «залипало»
	private var backgrounded = false

	// 136: з'єднання тримаємо й у фоні (як Android): програма грає звук гри, тож iOS не присипляє її (фоновий режим
	// «звук»). Повернувся до 10 хв — гра одразу далі, без нового підключення. Довше — закриваємо й підключаємось знову
	private var bgTimer: Timer?

	@objc private func background()
	{
		guard !ended else { return }
		backgrounded = true
		videoView.paused = true
		pad.releaseAll()
		touchState = PadState()
		GamepadInput.shared.reset()
		sendController()
		Haptics.shared.stopRumble()
		Log.add(2, "Програму згорнуто: з'єднання з приставкою тримаємо до 10 хв")
		bgTimer?.invalidate()
		bgTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: false) { [weak self] _ in self?.stopInBackground() }
	}

	private func stopInBackground()
	{
		guard backgrounded, !ended else { return }
		Log.add(2, "У фоні понад 10 хв: трансляцію закрито")
		closeMenu()
		session?.close()
		session = nil
		connected = false
		setLoading("Повертаємось у гру…")
		Task { _ = await Cloud.heartbeat(streaming: false) }
	}

	@objc private func foreground()
	{
		guard !ended, backgrounded else { return }
		backgrounded = false
		bgTimer?.invalidate(); bgTimer = nil
		GamepadInput.shared.reset()
		if let s = session, connected
		{
			Log.add(2, "Повернулись у гру: з'єднання збережене")
			videoView.resume()
			s.requestIDR()
			// ключовий кадр інколи губиться: просимо ще раз, якщо картинка не пішла
			let before = videoView.shownCount
			DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
				guard let self = self, self.session === s, self.videoView.shownCount == before else { return }
				Log.add(3, "Після повернення картинки нема: ще раз просимо ключовий кадр")
				s.requestIDR()
			}
			return
		}
		Log.add(2, "Повернулись у гру: підключаємось знову")
		setLoading("Повертаємось у гру…")
		session?.close()
		session = nil
		connected = false
		// приставці потрібна мить, щоб закрити попередню трансляцію
		DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.reconnectFresh() }
	}

	private func end(_ text: String)
	{
		guard !ended else { return }
		ended = true
		Log.add(3, "Гра закінчилась: " + text)
		Cloud.uploadLog(reason: "error", note: "Гра закінчилась: " + text)
		cleanup()
		let a = UIAlertController(title: nil, message: text, preferredStyle: .alert)
		a.addAction(UIAlertAction(title: "Зрозуміло", style: .default) { [weak self] _ in self?.dismissGame() })
		if presentedViewController == nil { present(a, animated: true) } else { dismissGame() }
	}

	private func finish()
	{
		guard !ended else { return }
		ended = true
		cleanup()
		dismissGame()
	}

	private func cleanup()
	{
		timers.forEach { $0.invalidate() }
		timers.removeAll()
		closeMenu()
		session?.close()
		session = nil
		Haptics.shared.stopRumble()
		GamepadInput.shared.onChange = nil
		GamepadInput.shared.onMenuKey = nil
		KeyLayout.shared.stopGame()
		if GameViewController.parked === self { GameViewController.parked = nil }
		UIApplication.shared.isIdleTimerDisabled = false
		Task { _ = await Cloud.heartbeat(streaming: false) }
	}

	private func dismissGame()
	{
		dismiss(animated: true) { [onFinish] in onFinish?() }
	}
}
