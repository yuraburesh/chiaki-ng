// AnyPlay для iPhone та iPad: вхід у свій PSN, як на Android (AnyPlayPsn.kt) і комп'ютері.
// Пароль клієнт вводить лише на сторінці Sony; програма бере від Sony код входу, міняє його на ключі
// й передає серверу AnyPlay (/api/app/psn/link). Адміністратор потім додає профіль на приставку.
import UIKit
import WebKit

enum Psn
{
	private static let clientId = "ba495a24-818c-472b-b12d-ff231c1b5745"
	private static let clientSecret = "mvaiZkRsAsI1IBkY"
	private static let tokenURL = "https://auth.api.sonyentertainmentnetwork.com/2.0/oauth/token"
	static let redirectPage = "https://remoteplay.dl.playstation.net/remoteplay/redirect"
	private static let scope = "psn:clientapp referenceDataService:countryConfig.read pushNotification:webSocket.desktop.connect sessionManager:remotePlaySession.system.update"

	private static func randomDuid() -> String
	{
		var b = [UInt8](repeating: 0, count: 16)
		_ = SecRandomCopyBytes(kSecRandomDefault, b.count, &b)
		return "0000000700410080" + b.map { String(format: "%02x", $0) }.joined()
	}

	/** Сторінка входу Sony (або реєстрації, після якої Sony продовжує вхід) */
	static func pageURL(create: Bool) -> URL?
	{
		let q: [(String, String)] = [
			("service_entity", "urn:service-entity:psn"), ("response_type", "code"), ("client_id", clientId),
			("redirect_uri", redirectPage), ("scope", scope), ("request_locale", "en_US"), ("ui", "pr"),
			("service_logo", "ps"), ("layout_type", "popup"), ("smcid", "remoteplay"), ("PlatformPrivacyWs1", "minimal"),
			("duid", randomDuid())]
		var c = URLComponents()
		if create
		{
			c = URLComponents(string: "https://web.np.playstation.com/app/id/create_account/") ?? URLComponents()
			c.queryItems = (q + [("cid", UUID().uuidString.lowercased()), ("no_captcha", "true")]).map { URLQueryItem(name: $0.0, value: $0.1) }
			c.fragment = "/accountcreation/pc/personal_info"
		}
		else
		{
			c = URLComponents(string: "https://auth.api.sonyentertainmentnetwork.com/2.0/oauth/authorize") ?? URLComponents()
			c.queryItems = (q + [("prompt", "always")]).map { URLQueryItem(name: $0.0, value: $0.1) }
		}
		return c.url
	}

	private static func form(_ items: [(String, String)]) -> Data
	{
		var allowed = CharacterSet.alphanumerics
		allowed.insert(charactersIn: "-._~")
		return Data(items.map { $0.0 + "=" + ($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") }.joined(separator: "&").utf8)
	}

	private static func sony(_ method: String, _ url: String, body: Data?) async -> (Int, [String: Any])
	{
		guard let u = URL(string: url) else { return (0, [:]) }
		var r = URLRequest(url: u, timeoutInterval: 20)
		r.httpMethod = method
		r.setValue("Basic " + Data("\(clientId):\(clientSecret)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
		if let b = body
		{
			r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
			r.httpBody = b
		}
		do
		{
			let (data, resp) = try await URLSession.shared.data(for: r)
			return ((resp as? HTTPURLResponse)?.statusCode ?? 0, (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:])
		}
		catch { return (0, [:]) }
	}

	/** Код зі сторінки «redirect» → ключі Sony → сервер AnyPlay. nil — вдалося, інакше текст помилки */
	static func finish(code: String) async -> String?
	{
		let (status, tokens) = await sony("POST", tokenURL, body: form([("grant_type", "authorization_code"), ("code", code), ("scope", scope), ("redirect_uri", redirectPage)]))
		guard status == 200, let access = tokens["access_token"] as? String, let refresh = tokens["refresh_token"] as? String, !access.isEmpty else
		{
			return status == 0 ? "Немає зв'язку з Sony. Перевір інтернет і спробуй ще раз."
				: "Sony не прийняла цей вхід (код діє лише кілька хвилин). Спробуй увійти ще раз."
		}
		let (infoStatus, info) = await sony("GET", tokenURL + "/" + access, body: nil)
		let uid: Int64? = (info["user_id"] as? String).flatMap { Int64($0) } ?? (info["user_id"] as? NSNumber)?.int64Value
		guard infoStatus == 200, let userId = uid else { return "Sony не віддала дані акаунта. Спробуй увійти ще раз." }
		var le = userId.littleEndian
		let account = withUnsafeBytes(of: &le) { Data($0) }.base64EncodedString()
		let expires = (tokens["expires_in"] as? NSNumber)?.intValue ?? 3600
		let r = await Cloud.request("POST", "/api/app/psn/link", body: [
			"accountId": account, "onlineId": info["online_id"] as? String ?? "", "refresh_token": refresh, "auth_token": access,
			"expiry": Int(Date().timeIntervalSince1970) + expires])
		if !r.ok
		{
			return r.status == 0 ? "Немає зв'язку з сервером AnyPlay. Перевір інтернет і спробуй ще раз."
				: "Не вдалося передати вхід PSN (помилка \(r.status)). Спробуй ще раз."
		}
		return nil
	}
}

/** Вікно входу на сторінці Sony. onDone(nil) — вдалося, onDone(текст) — помилка; закрили самі — не кличемо */
final class PsnLoginViewController: UIViewController, WKNavigationDelegate
{
	private let create: Bool
	private let onDone: (String?) -> Void
	private var web: WKWebView!
	private let busy = UIView()
	private var finished = false

	init(create: Bool, onDone: @escaping (String?) -> Void)
	{
		self.create = create
		self.onDone = onDone
		super.init(nibName: nil, bundle: nil)
		modalPresentationStyle = .fullScreen
	}

	required init?(coder: NSCoder) { fatalError() }

	override func viewDidLoad()
	{
		super.viewDidLoad()
		view.backgroundColor = UIColor(red: 0x2b / 255.0, green: 0x27 / 255.0, blue: 0x40 / 255.0, alpha: 1)
		let close = UIButton(type: .system)
		close.setTitle("✕", for: .normal)
		close.titleLabel?.font = .systemFont(ofSize: 22)
		close.tintColor = .white
		close.addTarget(self, action: #selector(closeTap), for: .touchUpInside)
		let title = UILabel()
		title.text = create ? "РЕЄСТРАЦІЯ Й ВХІД У PSN" : "ВХІД У PSN: ПАРОЛЬ БАЧИТЬ ЛИШЕ SONY"
		title.textColor = .white
		title.font = .systemFont(ofSize: 14, weight: .semibold)
		title.adjustsFontSizeToFitWidth = true
		title.minimumScaleFactor = 0.7
		let bar = UIStackView(arrangedSubviews: [close, title])
		bar.spacing = 12
		bar.alignment = .center
		bar.translatesAutoresizingMaskIntoConstraints = false
		view.addSubview(bar)
		// попередній вхід не підставляємо: окреме сховище без cookie
		let cfg = WKWebViewConfiguration()
		cfg.websiteDataStore = .nonPersistent()
		web = WKWebView(frame: .zero, configuration: cfg)
		// звичайний Safari: Sony інколи не пускає «вбудовані» вікна
		web.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"
		web.navigationDelegate = self
		web.translatesAutoresizingMaskIntoConstraints = false
		view.addSubview(web)
		busy.backgroundColor = view.backgroundColor
		busy.isHidden = true
		busy.translatesAutoresizingMaskIntoConstraints = false
		let spin = UIActivityIndicatorView(style: .large)
		spin.color = .white
		spin.startAnimating()
		let note = UILabel()
		note.text = "Перевіряємо вхід у Sony…"
		note.textColor = .white
		let col = UIStackView(arrangedSubviews: [spin, note])
		col.axis = .vertical
		col.spacing = 14
		col.alignment = .center
		col.translatesAutoresizingMaskIntoConstraints = false
		busy.addSubview(col)
		view.addSubview(busy)
		let g = view.safeAreaLayoutGuide
		NSLayoutConstraint.activate([
			bar.topAnchor.constraint(equalTo: g.topAnchor, constant: 6),
			bar.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 14),
			bar.trailingAnchor.constraint(lessThanOrEqualTo: g.trailingAnchor, constant: -14),
			close.widthAnchor.constraint(equalToConstant: 36), close.heightAnchor.constraint(equalToConstant: 36),
			web.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 6),
			web.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			web.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			web.bottomAnchor.constraint(equalTo: view.bottomAnchor),
			busy.topAnchor.constraint(equalTo: web.topAnchor), busy.bottomAnchor.constraint(equalTo: web.bottomAnchor),
			busy.leadingAnchor.constraint(equalTo: web.leadingAnchor), busy.trailingAnchor.constraint(equalTo: web.trailingAnchor),
			col.centerXAnchor.constraint(equalTo: busy.centerXAnchor), col.centerYAnchor.constraint(equalTo: busy.centerYAnchor)])
		if let u = Psn.pageURL(create: create) { web.load(URLRequest(url: u)) }
	}

	@objc private func closeTap() { dismiss(animated: true) }

	/** Sony після входу веде на сторінку «redirect» з кодом — забираємо його й далі все робимо самі */
	private func handle(_ url: URL?) -> Bool
	{
		guard let u = url, u.absoluteString.hasPrefix(Psn.redirectPage) else { return false }
		if finished { return true }
		finished = true
		web.stopLoading()
		let code = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "code" }?.value ?? ""
		if code.isEmpty
		{
			dismiss(animated: true) { self.onDone("Sony не завершила вхід. Спробуй ще раз.") }
			return true
		}
		busy.isHidden = false
		Task { @MainActor in
			let error = await Psn.finish(code: code)
			self.dismiss(animated: true) { self.onDone(error) }
		}
		return true
	}

	func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void)
	{
		decisionHandler(handle(action.request.url) ? .cancel : .allow)
	}

	func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!)
	{
		_ = handle(webView.url)
	}

	func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error)
	{
		_ = handle((error as NSError).userInfo[NSURLErrorFailingURLErrorKey] as? URL)
	}
}
