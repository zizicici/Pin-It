//
//  SceneDelegate.swift
//  Pin It
//
//  Created by Ci Zi on 2025/10/13.
//

import UIKit
import os.log

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        // Use this method to optionally configure and attach the UIWindow `window` to the provided UIWindowScene `scene`.
        // If using a storyboard, the `window` property will automatically be initialized and attached to the scene.
        // This delegate does not imply the connecting scene or session are new (see `application:configurationForConnectingSceneSession` instead).
        guard let windowScene = (scene as? UIWindowScene) else { return }
        
        window = UIWindow(windowScene: windowScene)
        
        let tabbarController = UITabBarController()
        tabbarController.view.tintColor = .systemRed
        tabbarController.tabBar.tintColor = .systemRed
        tabbarController.viewControllers = [UINavigationController(rootViewController: MainViewController()), UINavigationController(rootViewController: SettingsViewController()), UINavigationController(rootViewController: MoreViewController())]
        
        window?.rootViewController = tabbarController
        window?.makeKeyAndVisible()
        
        if let context = connectionOptions.urlContexts.first {
            logger.log("\(#function)")
            handle(context)
            handleInbox()
        }
    }
    
    func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
        logger.log("\(#function)")
        handle(contexts.first)
        handleInbox()
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        // Called as the scene is being released by the system.
        // This occurs shortly after the scene enters the background, or when its session is discarded.
        // Release any resources associated with this scene that can be re-created the next time the scene connects.
        // The scene may re-connect later, as its session was not necessarily discarded (see `application:didDiscardSceneSessions` instead).
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        // Called when the scene has moved from an inactive state to an active state.
        // Use this method to restart any tasks that were paused (or not yet started) when the scene was inactive.
    }

    func sceneWillResignActive(_ scene: UIScene) {
        // Called when the scene will move from an active state to an inactive state.
        // This may occur due to temporary interruptions (ex. an incoming phone call).
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        // Called as the scene transitions from the background to the foreground.
        // Use this method to undo the changes made on entering the background.
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        // Called as the scene transitions from the foreground to the background.
        // Use this method to save data, release shared resources, and store enough scene-specific state information
        // to restore the scene back to its current state.
    }
    
    func handle(_ context: UIOpenURLContext?) {
        guard let context = context else { return }
        if context.url.absoluteString == BoardLiveActivity.url {
            guard let tabbarController = window?.rootViewController as? UITabBarController else { return }
            
            switch User.shared.proTier() {
            case .lifetime:
                tabbarController.selectedViewController = tabbarController.viewControllers?
                    .first { ($0 as? UINavigationController)?.viewControllers.first is MainViewController }
            case .none:
                tabbarController.selectedViewController = tabbarController.viewControllers?
                    .first { ($0 as? UINavigationController)?.viewControllers.first is SettingsViewController }
            }
        }
    }

    func handleInbox() {
        logger.log("\(#function)")
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else {
            logger.log("no container URL")
            return
        }
        
        let inboxURL = containerURL.appendingPathComponent("inbox")
        
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: inboxURL,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else {
            logger.log("no contents")
            return
        }
        if let file = files.sorted(by: { $0.path() < $1.path() }).first {
            logger.log("found \(file)")
            let fileName = file.lastPathComponent
            switch fileName {
            case _ where fileName.hasSuffix("text"):
                if let data = try? Data(contentsOf: file) {
                    if let text = String(data: data, encoding: .utf8) {
                        logger.log("it's a text")
                        if let tabBarController = window?.rootViewController as? UITabBarController, let mainViewController = (tabBarController.viewControllers?.first as? UINavigationController)?.viewControllers.first as? MainViewController {
                            mainViewController.showEditor(with: text)
                        }
                    }
                }
            case _ where fileName.hasSuffix("image"):
                if let data = try? Data(contentsOf: file) {
                    if let image = UIImage(data: data) {
                        logger.log("it's an image")
                        if let tabBarController = window?.rootViewController as? UITabBarController, let mainViewController = (tabBarController.viewControllers?.first as? UINavigationController)?.viewControllers.first as? MainViewController {
                            mainViewController.showEditor(with: image)
                        }
                    }
                }
            default:
                break
            }
        }
        clearInbox()
    }
    
    func clearInbox() {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else {
            logger.log("no container URL")
            return
        }
        
        let inboxURL = containerURL.appendingPathComponent("inbox")
        
        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: inboxURL,
                includingPropertiesForKeys: nil,
                options: .skipsHiddenFiles
            )
            for file in files {
                try FileManager.default.removeItem(at: file)
            }
            logger.log("Cleaned up \(files.count) files from inbox")
        } catch {
            logger.log("Failed to clean up inbox: \(error)")
        }
    }
}
