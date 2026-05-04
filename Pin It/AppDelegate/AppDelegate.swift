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
import MoreKit

extension UserDefaults {
    enum Support: String {
        case AppReviewRequestDate = "com.zizicici.common.support.AppReviewRequestDate"
    }
}

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    private var isPresentingCloudKitAccountChangeAlert = false

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Override point for customization after application launch.
        
#if !DEBUG
        FirebaseApp.configure()
#endif
        
        try? Tips.configure()

        MoreKit.configure(
            productID: "com.zizicici.pin.pro",
            appGroupID: appGroupId,
            membershipKey: "com.zizicici.pin.Store.LifetimeMembership"
        )
        MoreKitAppearance.shared = MoreKitAppearance(
            backgroundColor: AppColor.background,
            tintColor: .systemRed
        )

        _ = AppDatabase.shared
        let dataManager = DataManager.shared
        DispatchQueue.global(qos: .utility).async {
            dataManager.cleanupUnreferencedImageCache()
        }
        _ = PinInfoManager.shared
        _ = PostSyncManager.shared
        if CloudKitSync.current == .enable {
            if CloudKitSync.pendingRemoteReset {
                CloudKitRecordSyncManager.shared.rebuildCloudKitDataAfterLocalReset()
            } else {
                CloudKitRecordSyncManager.shared.syncIfEnabled()
            }
        } else {
            OnboardingManager.shared.setupOnboardingDataIfNeeded()
        }
        _ = User.shared
        
        resetSettingsIfNeeded()
        
        DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 5.0) {
            self.requestAppReview()
        }
        
        NotificationCenter.default.addObserver(self, selector: #selector(resetSettingsIfNeeded), name: UIApplication.didEnterBackgroundNotification, object: nil)
        
        NotificationCenter.default.addObserver(self, selector: #selector(clearExpiredPosts), name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(cloudKitSyncSettingDidChange), name: .cloudKitSyncDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(presentCloudKitAccountChangeAlertIfNeeded), name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(presentCloudKitAccountChangeAlertIfNeeded), name: .SettingsUpdate, object: nil)

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
    
    @objc
    func clearExpiredPosts() {
        DataManager.shared.clearExpiredPosts()
    }

    @objc
    func cloudKitSyncSettingDidChange() {
        if CloudKitSync.current == .enable {
            if CloudKitSync.pendingRemoteReset {
                CloudKitRecordSyncManager.shared.rebuildCloudKitDataAfterLocalReset()
            } else {
                CloudKitRecordSyncManager.shared.syncIfEnabled()
            }
        } else {
            CloudKitRecordSyncManager.shared.disableSyncAndClearLocalState()
        }
    }

    @objc
    func presentCloudKitAccountChangeAlertIfNeeded() {
        // Listen on .SettingsUpdate (manager fires this when account change is detected)
        // and didBecomeActive (covers the case where the change happened while the app
        // was backgrounded). Either edge can fire first, so this method must be
        // re-entrant: if presentation fails (UIKit rejects, or we're mid-transition),
        // the flag stays set and the next observer fires retries.
        DispatchQueue.main.async {
            guard !self.isPresentingCloudKitAccountChangeAlert,
                  CloudKitSync.disabledByAccountChange,
                  let topViewController = Self.topMostViewController(),
                  !(topViewController is UIAlertController) else {
                return
            }
            self.isPresentingCloudKitAccountChangeAlert = true
            let alert = UIAlertController(
                title: String(localized: "settings.cloudKitSync.alert.accountChanged.title"),
                message: String(localized: "settings.cloudKitSync.alert.accountChanged.message"),
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(
                title: String(localized: "settings.cloudKitSync.alert.accountChanged.dismiss"),
                style: .default
            ) { [weak self] _ in
                // Only consume the flag once the user has actually acknowledged.
                _ = CloudKitSync.consumeDisabledByAccountChange()
                self?.isPresentingCloudKitAccountChangeAlert = false
            })
            topViewController.present(alert, animated: ConsideringUser.animated) { [weak self, weak alert] in
                // If UIKit rejected the presentation (presentingViewController stays
                // nil), back out the re-entry guard so a future observer can retry.
                if alert?.presentingViewController == nil {
                    self?.isPresentingCloudKitAccountChangeAlert = false
                }
            }
        }
    }

    private static func topMostViewController() -> UIViewController? {
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let rootViewController = windowScene.keyWindow?.rootViewController else {
            return nil
        }
        var top = rootViewController
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
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
