// AnyPlay для iPhone та iPad: запуск програми
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate
{
	var window: UIWindow?

	func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool
	{
		let w = UIWindow(frame: UIScreen.main.bounds)
		w.rootViewController = HomeViewController()
		w.overrideUserInterfaceStyle = .dark
		w.makeKeyAndVisible()
		window = w
		GamepadInput.shared.start()
		return true
	}
}
