// AnyPlay для iPhone та iPad: запуск програми.
// Вікно створює сцена (SceneDelegate): нові iOS не запускають програму без сцен («UIScene life cycle is required»).
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate
{
	func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool
	{
		GamepadInput.shared.start()
		return true
	}

	func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration
	{
		let c = UISceneConfiguration(name: "Default", sessionRole: session.role)
		c.delegateClass = SceneDelegate.self
		return c
	}
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate
{
	var window: UIWindow?

	func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions)
	{
		guard let ws = scene as? UIWindowScene else { return }
		let w = UIWindow(windowScene: ws)
		w.rootViewController = HomeViewController()
		w.overrideUserInterfaceStyle = .dark
		w.makeKeyAndVisible()
		window = w
	}
}
