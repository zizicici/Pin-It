//
//  AppDelegate.swift
//  Pin It
//
//  Created by Ci Zi on 2025/10/13.
//

import UIKit
import TipKit
#if !DEBUG
import FirebaseCore
#endif
import Kingfisher
import StoreKit

extension UserDefaults {
    enum Support: String {
        case AppReviewRequestDate = "com.zizicici.common.support.AppReviewRequestDate"
    }
}

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Override point for customization after application launch.
        
#if !DEBUG
        FirebaseApp.configure()
#endif
        
        try? Tips.configure()
        
        _ = AppDatabase.shared
        _ = PinInfoManager.shared
        _ = PostSyncManager.shared
        _ = OnboardingManager.shared
        _ = User.shared
        
        resetSettingsIfNeeded()
        
        DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 5.0) {
            self.requestAppReview()
        }
        
        NotificationCenter.default.addObserver(self, selector: #selector(resetSettingsIfNeeded), name: UIApplication.didEnterBackgroundNotification, object: nil)
        
        return true
    }

    // MARK: UISceneSession Lifecycle

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        // Called when a new scene session is being created.
        // Use this method to select a configuration to create the new scene with.
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
        // Called when the user discards a scene session.
        // If any sessions were discarded while the application was not running, this will be called shortly after application:didFinishLaunchingWithOptions.
        // Use this method to release any resources that were specific to the discarded scenes, as they will not return.
    }
    
    @objc
    func resetSettingsIfNeeded() {
        if DeleteOperationConfirmation.current == .disableUntilAppBackgrounds {
            try? DeleteOperationConfirmation.setCurrent(DeleteOperationConfirmation.defaultOption)
        }
        KingfisherManager.shared.cache.clearCache()
    }
}

extension AppDelegate {
    func requestAppReview() {
        do {
            guard let creationDate = try AppDatabase.getDatabaseCreationDate() else { return }
            guard let daysSinceCreation = Calendar.current.dateComponents([.day], from: creationDate, to: Date()).day else { return }
            guard daysSinceCreation >= 5 else { return }
            
            let userDefaultsFlag: Bool
            let userDefaultsKey = UserDefaults.Support.AppReviewRequestDate.rawValue
            if let storeddaysSince1970 = UserDefaults.standard.getInt(forKey: userDefaultsKey) {
                let daysSince1970 = Int(Date().timeIntervalSince1970 / (24 * 60 * 60))
                userDefaultsFlag = (daysSince1970 - storeddaysSince1970) >= 180
            } else {
                userDefaultsFlag = true
            }
            
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene, userDefaultsFlag {
                let daysSince1970 = Int(Date().timeIntervalSince1970 / (24 * 60 * 60))
                UserDefaults.standard.set(daysSince1970, forKey: userDefaultsKey)
                AppStore.requestReview(in: windowScene)
            }
        } catch {
            print("\(error.localizedDescription)")
        }
    }
}
