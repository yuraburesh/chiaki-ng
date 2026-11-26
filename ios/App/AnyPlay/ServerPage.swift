// AnyPlay для iPhone та iPad: сторінки сервера всередині програми, як на Android (AnyPlayPage.kt) і комп'ютері:
// «Друзі й подарунки» (webapp/book.html) і «Дивитись» (webapp/watch.html: гра друга, голос, чат).
// Вхід без Telegram: сторінка нашого сервера отримує window.AnyPlayApp = {token, platform, build}. Скрипт перевіряє адресу,
// тож на будь-якому іншому сайті його немає; посилання на інші сайти відкриваються в Safari.
import UIKit
import WebKit

final class ServerPageViewController: UIViewController, WKNavigationDelegate, WKUIDelegate
{
	private let path: String
	private let watch: Bool
	private var web: WKWebView!

	/** path — з / на початку, лише /app/… */
	init(path: String, watch: Bool = false)
	{
		self.path = path
		self.watch = watch
		super.init(nibName: nil, bundle: nil)
		modalPresentationStyle = .fullScreen
	}

	required init?(coder: NSCoder) { fatalError() }

	private static var own: URLComponents? { URLComponents(string: Cloud.server) }

	private static func isOwn(_ u: URL?) -> Bool
	{
		guard let u = u, let o = own else { return false }
		return u.scheme == o.scheme && u.host == o.host && u.path.hasPrefix("/app/")
	}

	private func appScript() -> String
	{
		let app = jsonText(["token": Cloud.token, "platform": "ios", "build": Cloud.build, "native": false])
		let o = ServerPageViewController.own
		let w = jsonText(["host": o?.host ?? "", "protocol": (o?.scheme ?? "https") + ":"])
		return "(function(){var w=\(w);if(location.protocol!==w.protocol||location.hostname!==w.host)return;"
			+ "try{Object.defineProperty(window,'AnyPlayApp',{value:Object.freeze(\(app)),writable:false,configurable:false});}catch(e){}})();"
	}

	override func viewDidLoad()
	{
		super.viewDidLoad()
		view.backgroundColor = UIColor(red: 0x2b / 255.0, green: 0x27 / 255.0, blue: 0x40 / 255.0, alpha: 1)
		let cfg = WKWebViewConfiguration()
		cfg.allowsInlineMediaPlayback = true
		cfg.mediaTypesRequiringUserActionForPlayback = []   // відео й голоси друзів грають одразу
		cfg.userContentController.addUserScript(WKUserScript(source: appScript(), injectionTime: .atDocumentStart, forMainFrameOnly: true))
		web = WKWebView(frame: .zero, configuration: cfg)
		web.isOpaque = false
		web.backgroundColor = view.backgroundColor
		web.scrollView.backgroundColor = view.backgroundColor
		web.navigationDelegate = self
		web.uiDelegate = self
		web.translatesAutoresizingMaskIntoConstraints = false
		view.addSubview(web)
		let close = UIButton(type: .system)
		close.setTitle("✕", for: .normal)
		close.titleLabel?.font = .systemFont(ofSize: 20, weight: .medium)
		close.tintColor = .white
		close.backgroundColor = UIColor(white: 0, alpha: 0.35)
		close.layer.cornerRadius = 18
		close.addTarget(self, action: #selector(closeTap), for: .touchUpInside)
		close.translatesAutoresizingMaskIntoConstraints = false
		view.addSubview(close)
		let g = view.safeAreaLayoutGuide
		NSLayoutConstraint.activate([
			web.topAnchor.constraint(equalTo: g.topAnchor), web.bottomAnchor.constraint(equalTo: view.bottomAnchor),
			web.leadingAnchor.constraint(equalTo: view.leadingAnchor), web.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			close.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -10), close.topAnchor.constraint(equalTo: g.topAnchor, constant: 8),
			close.widthAnchor.constraint(equalToConstant: 36), close.heightAnchor.constraint(equalToConstant: 36)])
		if watch { UIApplication.shared.isIdleTimerDisabled = true }   // дивимось гру: екран не гасне
		if path.hasPrefix("/app/"), !path.contains(".."), let u = URL(string: Cloud.server + path) { web.load(URLRequest(url: u)) }
	}

	override func viewWillDisappear(_ animated: Bool)
	{
		super.viewWillDisappear(animated)
		if watch { UIApplication.shared.isIdleTimerDisabled = false }
	}

	@objc private func closeTap() { dismiss(animated: true) }

	// лише сторінки нашого сервера; інше — у Safari
	func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void)
	{
		guard let u = action.request.url else { decisionHandler(.cancel); return }
		if ServerPageViewController.isOwn(u) || u.scheme == "about" || u.scheme == "blob" || u.scheme == "data" { decisionHandler(.allow); return }
		if action.targetFrame?.isMainFrame == false { decisionHandler(.allow); return }
		if u.scheme == "https" || u.scheme == "tg" { UIApplication.shared.open(u) }
		decisionHandler(.cancel)
	}

	// target=_blank: теж у Safari
	func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView?
	{
		if let u = action.request.url, u.scheme == "https" || u.scheme == "tg" { UIApplication.shared.open(u) }
		return nil
	}

	// мікрофон для голосу з друзями — лише нашому серверу (iOS ще спитає дозволу сам)
	func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
		type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void)
	{
		decisionHandler(origin.host == ServerPageViewController.own?.host && type == .microphone ? .grant : .deny)
	}

	func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void)
	{
		let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
		a.addAction(UIAlertAction(title: "Зрозуміло", style: .default) { _ in completionHandler() })
		present(a, animated: true)
	}

	func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void)
	{
		let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
		a.addAction(UIAlertAction(title: "Скасувати", style: .cancel) { _ in completionHandler(false) })
		a.addAction(UIAlertAction(title: "Так", style: .default) { _ in completionHandler(true) })
		present(a, animated: true)
	}
}
