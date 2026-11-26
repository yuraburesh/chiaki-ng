// AnyPlay для iPhone та iPad: сторінка assets/anyplay/app.html (та сама, що на Android) у WKWebView.
// На Android сторінка кличе window.AnyPlay синхронно (info(), quality()…). У WKWebView виклики до програми лише
// асинхронні, тож тут невеликий шар JS: синхронні читання беруть останні значення, які програма сама кладе в сторінку
// (__apSet), а дії йдуть повідомленнями. Відповіді на запити до сервера — як на Android: window.__anyplayResp.
import UIKit
import WebKit

protocol WebHost: AnyObject
{
	/** JSON зі станом для сторінки (головний екран або гра) */
	func info() -> String
	/** Команда сторінки (вхід, гра, вихід тощо) */
	func action(_ name: String, _ arg: String)
	func qualityChanged()
	func pictureChanged()
}

extension WebHost
{
	func qualityChanged() {}
	func pictureChanged() {}
}

/** Рядок як літерал JS */
func jsQuote(_ s: String) -> String
{
	let d = try? JSONSerialization.data(withJSONObject: [s])
	let t = d.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
	return String(t.dropFirst().dropLast())
}

func jsonText(_ o: Any) -> String
{
	(try? JSONSerialization.data(withJSONObject: o)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
}

final class WebPage: NSObject, WKScriptMessageHandler, WKNavigationDelegate
{
	let web: WKWebView
	weak var host: WebHost?
	weak var presenter: UIViewController?
	var onClose: (() -> Void)?
	private let haptic = UIImpactFeedbackGenerator(style: .light)

	init(page: String, transparent: Bool, host: WebHost?)
	{
		self.host = host
		let cfg = WKWebViewConfiguration()
		cfg.allowsInlineMediaPlayback = true
		let uc = WKUserContentController()
		cfg.userContentController = uc
		web = WKWebView(frame: .zero, configuration: cfg)
		super.init()
		uc.add(WeakHandler(self), name: "anyplay")
		uc.addUserScript(WKUserScript(source: WebPage.shim(initial: WebPage.state(host)), injectionTime: .atDocumentStart, forMainFrameOnly: true))
		// 133: на iPad сторінка в 1,5 раза більша через meta viewport (сторінка вважає екран вужчим, а iPad
		// збільшує її на весь екран). pageZoom тут не годиться: розмітка лишалась на повну ширину і вилазила за край
		if UIDevice.current.userInterfaceIdiom == .pad
		{
			uc.addUserScript(WKUserScript(source: WebPage.padFit, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
		}
		web.isOpaque = !transparent
		web.backgroundColor = transparent ? .clear : UIColor(red: 0x2b / 255.0, green: 0x27 / 255.0, blue: 0x40 / 255.0, alpha: 1)
		web.scrollView.backgroundColor = web.backgroundColor
		web.scrollView.contentInsetAdjustmentBehavior = .never
		web.scrollView.bounces = false
		web.navigationDelegate = self
		if let url = Bundle.main.url(forResource: "app", withExtension: "html", subdirectory: "web")
		{
			var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
			c?.fragment = page
			web.loadFileURL(c?.url ?? url, allowingReadAccessTo: url.deletingLastPathComponent())
		}
	}

	/** Поточні значення для синхронних читань сторінки */
	private static func state(_ host: WebHost?) -> [String: String]
	{
		[
			"info": host?.info() ?? "{}",
			"quality": jsonText(Quality.json),
			"picture": jsonText(Prefs.picture),
			"feel": jsonText(Prefs.feel.merging(["amp": true]) { a, _ in a }),
			"hud": String(Prefs.hud),
			"live": jsonText(["supported": false])
		]
	}

	/** Оновити значення в сторінці (стан програми змінився) */
	func push()
	{
		var js = ""
		let st = WebPage.state(host)
		for (k, v) in st { js += "window.__apSet&&window.__apSet(\(jsQuote(k)),\(jsQuote(v)));" }
		web.evaluateJavaScript(js, completionHandler: nil)
	}

	func eval(_ js: String) { web.evaluateJavaScript(js, completionHandler: nil) }

	private static let padFit = """
	(function(){
	  function fit(){
	    var o = typeof window.orientation === 'number' ? Math.abs(window.orientation) === 90 : (window.matchMedia && matchMedia('(orientation: landscape)').matches);
	    var sw = screen.width, sh = screen.height, dw = o ? Math.max(sw, sh) : Math.min(sw, sh);
	    var k = 1.5, w = Math.round(dw / k);
	    var m = document.querySelector('meta[name=viewport]');
	    if(!m){ m = document.createElement('meta'); m.name = 'viewport'; document.head.appendChild(m); }
	    m.setAttribute('content', 'width=' + w + ', initial-scale=' + k + ', minimum-scale=' + k + ', maximum-scale=' + k + ', user-scalable=no, viewport-fit=cover');
	  }
	  fit();
	  window.addEventListener('orientationchange', function(){ setTimeout(fit, 60); setTimeout(fit, 400); });
	})();
	"""

	private static func shim(initial: [String: String]) -> String
	{
		"""
		(function(){
		const st = \(jsonText(initial));
		window.__apSet = function(k, v){ st[k] = v; };
		const post = function(m){ try { window.webkit.messageHandlers.anyplay.postMessage(m); } catch(e) {} };
		const J = function(k){ try { return JSON.parse(st[k] || '{}'); } catch(e) { return {}; } };
		window.AnyPlay = {
		  req: function(id, method, path, body){ post({t: 'req', id: id, method: method, path: path, body: body || ''}); },
		  info: function(){ return st.info; },
		  action: function(n, a){ post({t: 'action', n: String(n), a: String(a == null ? '' : a)}); },
		  haptic: function(){ post({t: 'haptic'}); },
		  copy: function(x){ post({t: 'copy', x: String(x)}); },
		  open: function(u){ post({t: 'open', u: String(u)}); },
		  close: function(){ post({t: 'close'}); },
		  share: function(x){ post({t: 'share', x: String(x)}); },
		  watch: function(c){ post({t: 'watch', c: String(c)}); },
		  page: function(p){ post({t: 'page', p: String(p)}); },
		  psnLogin: function(c){ post({t: 'psnLogin', c: !!c}); },
		  quality: function(){ return st.quality; },
		  setQuality: function(c){
		    const q = J('quality'); q.auto = c < 0; if(c >= 0) q.level = c;
		    q.name = (q.auto ? 'Авто: ' : '') + ((q.levels || [])[q.level] || {}).title;
		    st.quality = JSON.stringify(q); post({t: 'setQuality', c: c}); return st.quality; },
		  picture: function(){ return st.picture; },
		  setPicture: function(j){ const p = Object.assign(J('picture'), JSON.parse(j || '{}')); st.picture = JSON.stringify(p); post({t: 'setPicture', j: st.picture}); return st.picture; },
		  resetPicture: function(){ const p = Object.assign(J('picture'), {brightness: 0, contrast: 0, saturation: 0, warmth: 0}); st.picture = JSON.stringify(p); post({t: 'setPicture', j: st.picture}); return st.picture; },
		  feel: function(){ return st.feel; },
		  setFeel: function(j){ const f = Object.assign(J('feel'), JSON.parse(j || '{}')); st.feel = JSON.stringify(f); post({t: 'setFeel', j: st.feel}); return st.feel; },
		  feelTest: function(w){ post({t: 'feelTest', w: String(w)}); },
		  hud: function(){ return +st.hud || 0; },
		  setHud: function(n){ st.hud = String(n); post({t: 'setHud', n: +n}); return +n; },
		  live: function(){ return st.live; },
		  liveDo: function(n, a){ post({t: 'liveDo', n: String(n), a: String(a)}); }
		};
		})();
		"""
	}

	func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage)
	{
		guard let m = message.body as? [String: Any], let t = m["t"] as? String else { return }
		switch t
		{
		case "req":
			let id = m["id"] as? Int ?? 0
			let method = (m["method"] as? String) == "POST" ? "POST" : "GET"
			let path = m["path"] as? String ?? ""
			guard Cloud.pagePaths.contains(where: { path.hasPrefix($0) }), !path.contains("..") else { return }
			let body = m["body"] as? String ?? ""
			Task { @MainActor in
				let (status, text) = await Cloud.requestRaw(method, path, body: body)
				self.eval("window.__anyplayResp(\(id), \(status), \(jsQuote(text)))")
			}
		case "action":
			host?.action(m["n"] as? String ?? "", m["a"] as? String ?? "")
		case "haptic":
			Haptics.shared.ui()
		case "copy":
			UIPasteboard.general.string = m["x"] as? String
		case "open":
			if let s = m["u"] as? String, s.hasPrefix("https://") || s.hasPrefix("tg:"), let u = URL(string: s) { UIApplication.shared.open(u) }
		case "close":
			onClose?()
		case "share":
			guard let text = m["x"] as? String, let p = presenter else { return }
			let a = UIActivityViewController(activityItems: [text], applicationActivities: nil)
			a.popoverPresentationController?.sourceView = web
			a.popoverPresentationController?.sourceRect = CGRect(x: web.bounds.midX, y: web.bounds.midY, width: 1, height: 1)
			p.present(a, animated: true)
		case "watch":
			// 128: «Дивитись» — у програмі, як на Android (без геймпада — з екранними кнопками помічника)
			let code = String((m["c"] as? String ?? "").uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(12))
			if !code.isEmpty { presenter?.present(ServerPageViewController(path: "/app/watch.html?r=" + code + (GamepadInput.shared.connected ? "" : "&pad=1"), watch: true), animated: true) }
		case "page":
			// 128: друзі й подарунки (book.html) — у програмі, як на комп'ютері
			let path = m["p"] as? String ?? ""
			if path.hasPrefix("/app/book.html"), !path.contains("..") { presenter?.present(ServerPageViewController(path: path), animated: true) }
		case "psnLogin":
			// 128: вхід у свій PSN на сторінці Sony, як на Android і комп'ютері
			let vc = PsnLoginViewController(create: m["c"] as? Bool ?? false) { [weak self] error in
				self?.alert(error ?? "Вхід у PSN виконано. Адміністратор додасть твій профіль на приставку: це кілька хвилин.")
				self?.eval("window.__anyplayEvent && window.__anyplayEvent('psn')")
			}
			presenter?.present(vc, animated: true)
		case "setQuality":
			if Quality.select(m["c"] as? Int ?? -1) { host?.qualityChanged() }
			push()
		case "setPicture":
			if let j = m["j"] as? String, let o = (try? JSONSerialization.jsonObject(with: Data(j.utf8))) as? [String: Any] { Prefs.picture = o }
			host?.pictureChanged()
		case "setFeel":
			if let j = m["j"] as? String, var o = (try? JSONSerialization.jsonObject(with: Data(j.utf8))) as? [String: Any]
			{
				o.removeValue(forKey: "amp")
				Prefs.feel = o
			}
		case "feelTest":
			Haptics.shared.demo(m["w"] as? String ?? "")
		case "setHud":
			Prefs.hud = m["n"] as? Int ?? 0
		default:
			break
		}
	}

	func alert(_ text: String)
	{
		guard let p = presenter else { return }
		let a = UIAlertController(title: nil, message: text, preferredStyle: .alert)
		a.addAction(UIAlertAction(title: "Зрозуміло", style: .default))
		p.present(a, animated: true)
	}

	// посилання на сторонні сайти — у Safari, сторінка лише своя
	func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void)
	{
		if let u = action.request.url, u.isFileURL { decisionHandler(.allow); return }
		if let u = action.request.url { UIApplication.shared.open(u) }
		decisionHandler(.cancel)
	}

	/** «Назад» на сторінці (жест чи кнопка програми): true — сторінка обробила сама */
	func back(_ done: @escaping (Bool) -> Void)
	{
		web.evaluateJavaScript("window.__anyplayBack ? window.__anyplayBack() : false") { r, _ in done((r as? Bool) == true) }
	}

	func detach()
	{
		web.configuration.userContentController.removeScriptMessageHandler(forName: "anyplay")
	}
}

/** WKUserContentController тримає обробник сильно: розриваємо цикл */
private final class WeakHandler: NSObject, WKScriptMessageHandler
{
	weak var target: WKScriptMessageHandler?
	init(_ t: WKScriptMessageHandler) { target = t }
	func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage)
	{
		target?.userContentController(uc, didReceive: message)
	}
}
