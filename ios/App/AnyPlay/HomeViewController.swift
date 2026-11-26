// AnyPlay для iPhone та iPad: головний екран (як AnyPlayActivity на Android) — та сама сторінка app.html:
// вхід через Telegram, стан броні й кнопка «Грати», бронювання, оплата, баланс, друзі, якість, довідка.
import UIKit

final class HomeViewController: UIViewController, WebHost
{
	private var page: WebPage!
	private var state = "login"        // login, pairing, wait, play, no_console, update, other_device, offline
	private var session: [String: Any] = [:]
	private var busy = false
	private var skew: Int = 0
	private var pairShort = "", pairBot = "", pairLink = ""
	private var pairTask: Task<Void, Never>?
	private var refreshTimer: Timer?
	private var homeJson = "{}"
	private var loggedIn: Bool { !Cloud.token.isEmpty }
	private var isAdmin: Bool { session["admin"] as? Bool ?? false }

	override var prefersStatusBarHidden: Bool { false }
	override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

	override func viewDidLoad()
	{
		super.viewDidLoad()
		view.backgroundColor = UIColor(red: 0x2b / 255.0, green: 0x27 / 255.0, blue: 0x40 / 255.0, alpha: 1)
		state = loggedIn ? "wait" : "login"
		render(push: false)
		page = WebPage(page: "home", transparent: false, host: self)
		page.presenter = self
		view.addSubview(page.web)
		NotificationCenter.default.addObserver(self, selector: #selector(active), name: UIApplication.didBecomeActiveNotification, object: nil)
		CA.ensure()
	}

	override func viewDidLayoutSubviews()
	{
		super.viewDidLayoutSubviews()
		// сторінка сама відступає від вирізу й панелей (safe-area у CSS)
		page.web.frame = view.bounds
	}

	override func viewDidAppear(_ animated: Bool)
	{
		super.viewDidAppear(animated)
		active()
		refreshTimer?.invalidate()
		refreshTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
			guard let s = self, s.presentedViewController == nil else { return }
			Task { await s.refresh() }
		}
	}

	override func viewWillDisappear(_ animated: Bool)
	{
		super.viewWillDisappear(animated)
		refreshTimer?.invalidate()
	}

	@objc private func active()
	{
		if loggedIn && state != "pairing" { Task { await refresh() } }
	}

	// ── стан для сторінки ──
	func info() -> String { homeJson }

	private func render(push: Bool = true)
	{
		var o: [String: Any] = ["state": state, "loggedIn": loggedIn, "busy": busy, "admin": isAdmin, "skew": skew, "build": Cloud.build, "platform": "ios",
			"user": loggedIn ? (session["user"] as? String ?? "") : "", "quality": Quality.json,
			"pairShort": state == "pairing" ? pairShort : "", "pairBot": pairBot]
		var s: [String: Any] = [:]
		for k in ["next", "booking", "closed", "myPsn", "myPsnReady", "myPsnStatus", "otherDevice", "otherSeen", "canTakeover", "guest", "guestAccess", "guestWait", "guestFreeAt", "handoff", "handoffOffer"]
		{
			if let v = session[k] { s[k] = v }
		}
		if let c = session["console"] as? [String: Any] { s["console"] = ["psn": c["psn"] as? String ?? "", "own": c["own"] as? Bool ?? false] }
		if !isAdmin, let w = session["wallet"] { s["wallet"] = w }
		o["session"] = s
		homeJson = jsonText(o)
		if push, page != nil
		{
			page.push()
			page.eval("window.__anyplayHome && window.__anyplayHome(\(jsQuote(homeJson)))")
		}
	}

	private func refresh() async
	{
		let r = await Cloud.session()
		if r.status == 401
		{
			logout()
			toast("Доступ цього пристрою скасовано. Увійди через Telegram знову.")
			return
		}
		guard r.ok else
		{
			if state != "pairing" { state = "offline"; render() }
			return
		}
		session = r.json
		if let now = r.json["now"] as? Int { skew = now - Int(Date().timeIntervalSince1970) }
		switch r.str("state")
		{
		case "play", "no_console", "update", "other_device": state = r.str("state")
		default: state = "wait"
		}
		render()
	}

	// ── команди сторінки ──
	func action(_ name: String, _ arg: String)
	{
		switch name
		{
		case "login": if state == "login" { login(openTg: true) }
		case "loginCode": if state == "login" { login(openTg: false) }
		case "openTg": if state == "pairing", let u = URL(string: pairLink) { UIApplication.shared.open(u) }
		case "cancelLogin": pairTask?.cancel(); state = loggedIn ? "wait" : "login"; render()
		case "play": play(takeover: false)
		case "takeover": if !isAdmin { play(takeover: true) }
		case "retry", "refresh": if loggedIn && state != "pairing" { Task { await refresh() } }
		case "bot", "update": if let u = URL(string: Cloud.botURL) { UIApplication.shared.open(u) }
		// 129: CRM у самій програмі (та сама сторінка, що в боті)
		case "crm": if isAdmin { present(ServerPageViewController(path: "/app/admin.html"), animated: true) }
		case "adminState": page.eval("window.__anyplayAdmin && window.__anyplayAdmin(\(jsQuote(jsonText(["kind": "state", "online": ""]))))")
		case "adminPsnLogin", "adminLink", "adminSharedLink":
			let kind = name == "adminPsnLogin" ? "login" : name
			let uid = ((try? JSONSerialization.jsonObject(with: Data(arg.utf8))) as? [String: Any])?["userId"] ?? 0
			page.eval("window.__anyplayAdmin && window.__anyplayAdmin(\(jsQuote(jsonText(["kind": kind, "ok": false, "userId": uid, "text": "Прив'язка приставки на iPhone ще не працює: зроби це з телефона на Android або з комп'ютера."]))))")
		case "layout": page.alert("Розташування кнопок на iPhone з'явиться в наступній версії. Зараз кнопки стоять типово, як на Android.")
		case "logout":
			let a = UIAlertController(title: nil, message: "Вийти з AnyPlay на цьому пристрої?", preferredStyle: .alert)
			a.addAction(UIAlertAction(title: "Скасувати", style: .cancel))
			a.addAction(UIAlertAction(title: "Вийти", style: .destructive) { [weak self] _ in self?.logout() })
			present(a, animated: true)
		case "handoffChanged": Task { await refresh() }
		default: break
		}
	}

	func qualityChanged() { render() }

	private func logout()
	{
		pairTask?.cancel()
		Cloud.token = ""
		session = [:]
		state = "login"
		render()
	}

	private func login(openTg: Bool)
	{
		state = "pairing"; pairShort = ""; pairBot = ""; pairLink = ""
		render()
		pairTask?.cancel()
		pairTask = Task { @MainActor in
			let start = await Cloud.pairStart()
			let code = start.str("code"), link = start.str("link")
			guard start.ok, !code.isEmpty, !link.isEmpty else
			{
				state = "login"; render()
				toast("Сервер AnyPlay недоступний. Перевір інтернет і спробуй ще раз.")
				return
			}
			pairShort = start.str("short"); pairBot = start.str("bot"); pairLink = link
			render()
			if openTg || pairShort.isEmpty, let u = URL(string: link) { await UIApplication.shared.open(u) }
			for _ in 0..<150
			{
				try? await Task.sleep(nanoseconds: 2_000_000_000)
				if Task.isCancelled { return }
				let r = await Cloud.pairPoll(code)
				let token = r.str("token")
				if !token.isEmpty
				{
					Cloud.token = token
					state = "wait"; render()
					toast("Вхід виконано ✓")
					await refresh()
					return
				}
				if r.status == 404
				{
					state = "login"; render()
					toast("Посилання для входу застаріло. Спробуй ще раз.")
					return
				}
			}
			state = "login"; render()
			toast("Час на вхід вийшов. Натисни «Увійти через Telegram» ще раз.")
		}
	}

	private func play(takeover: Bool)
	{
		guard !busy else { return }
		busy = true
		render()
		Quality.prepare()
		Task { @MainActor in
			let r = takeover ? await Cloud.request("POST", "/api/app/session", body: ["takeover": true]) : await Cloud.session()
			var result: PlayTarget
			if !r.ok { result = .error("Немає зв'язку з сервером AnyPlay. Спробуй ще раз за хвилину.", "AP-HTTP \(r.status)") }
			else if r.str("state") == "other_device"
			{
				session = r.json
				if r.json["canTakeover"] as? Bool == true
				{
					busy = false; state = "other_device"; render()
					confirm("Гра вже йде на «\(r.str("otherDevice"))». Продовжити гру тут? Там гра зупиниться, твій час не змінюється.", yes: "Грати тут") { self.play(takeover: true) }
					return
				}
				result = .error("Зараз ти граєш на «\(r.str("otherDevice"))». Закрий гру там (меню AnyPlay → «Вийти з гри»), і тут з'явиться «Грати».", "")
			}
			else if r.str("state") != "play" { result = .error("Зараз грати не можна: час броні ще не настав або вже минув.", "") }
			else
			{
				let json = r.json
				result = await Task.detached { PlayTarget.find(json) }.value
			}
			busy = false
			render()
			switch result
			{
			case .ready(let t):
				let g = GameViewController(target: t, admin: isAdmin)
				g.onFinish = { [weak self] in Task { await self?.refresh() } }
				present(g, animated: true)
			case .error(let text, let code):
				page.alert(code.isEmpty ? text : text + "\n\nКод для підтримки: " + code)
			}
		}
	}

	private func confirm(_ text: String, yes: String, _ act: @escaping () -> Void)
	{
		let a = UIAlertController(title: nil, message: text, preferredStyle: .alert)
		a.addAction(UIAlertAction(title: "Скасувати", style: .cancel))
		a.addAction(UIAlertAction(title: yes, style: .default) { _ in act() })
		present(a, animated: true)
	}

	private func toast(_ text: String)
	{
		page?.eval("typeof toast === 'function' && toast(\(jsQuote(text)))")
	}
}
