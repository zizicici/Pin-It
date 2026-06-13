//
//  Settings.swift
//  Pin It
//
//  Created by Ci Zi on 2025/4/29.
//

import Foundation
import MoreKit

extension UserDefaults {
    enum Settings: String {
        case AutoBackup = "com.zizicici.pin.settings.AutoBackup"
        case BackupFolder = "com.zizicici.pin.settings.BackupFolder"
        case AutoStartLiveActivity = "com.zizicici.pin.settings.AutoStartLiveActivity"
        case AutoEndLiveActivity = "com.zizicici.pin.settings.AutoEndLiveActivity"
        case MaxPinnedPosts = "com.zizicici.pin.settings.MaxPinnedPosts"
        case ThanksEntryState = "com.zizicici.pin.settings.ThanksEntryState"
        case DeleteOperationConfirmation = "com.zizicici.pin.settings.DeleteOperationConfirmation"
        case ExpirationAction = "com.zizicici.pin.settings.ExpirationAction"
        case DefaultExpirationTime = "com.zizicici.pin.settings.DefaultExpirationTime"
        case DefaultStyle = "com.zizicici.pin.settings.DefaultStyle"
        case DefaultStyleSyncId = "com.zizicici.pin.settings.DefaultStyleSyncId"
        case DefaultStyleModificationTime = "com.zizicici.pin.settings.DefaultStyleModificationTime"
        case DefaultStylePendingCloudKitSyncId = "com.zizicici.pin.settings.DefaultStylePendingCloudKitSyncId"
        case DefaultStylePendingCloudKitModificationTime = "com.zizicici.pin.settings.DefaultStylePendingCloudKitModificationTime"
        case OnboardingSeedState = "com.zizicici.pin.settings.OnboardingSeedState"
        case CloudKitSync = "com.zizicici.pin.settings.CloudKitSync"
        case CloudKitSyncLastError = "com.zizicici.pin.settings.CloudKitSyncLastError"
        case CloudKitRemoteDataMayExist = "com.zizicici.pin.settings.CloudKitRemoteDataMayExist"
        case CloudKitPendingRemoteReset = "com.zizicici.pin.settings.CloudKitPendingRemoteReset"
        case CloudKitPendingRemoteClear = "com.zizicici.pin.settings.CloudKitPendingRemoteClear"
        case CloudKitPendingDisableCleanup = "com.zizicici.pin.settings.CloudKitPendingDisableCleanup"
        case CloudKitSyncDisabledByAccountChange = "com.zizicici.pin.settings.CloudKitSyncDisabledByAccountChange"
    }
}

extension Notification.Name {
    static let DefaultStyleDidChanged = Notification.Name(rawValue: "com.zizicici.pin.defaultStyle.didChanged")
    static let cloudKitSyncDidChange = Notification.Name(rawValue: "com.zizicici.pin.cloudKitSync.didChange")
    static let cloudKitSyncActivityChanged = Notification.Name(rawValue: "com.zizicici.pin.cloudKitSync.activityChanged")
}

enum AutoBackup: Int, CaseIterable, Codable {
    case enable
    case disable
}

enum CloudKitSync: Int, CaseIterable, Codable {
    case disable = 0
    case enable
}

extension CloudKitSync: UserDefaultSettable {
    static func getKey() -> String {
        UserDefaults.Settings.CloudKitSync.rawValue
    }

    static var defaultOption: Self {
        return .disable
    }

    func getName() -> String {
        switch self {
        case .enable:
            return String(localized: "settings.enable")
        case .disable:
            return String(localized: "settings.disable")
        }
    }

    static func getTitle() -> String {
        return String(localized: "settings.cloudKitSync.title")
    }

    static func getFooter() -> String? {
        var parts = [AppInfo.localized("settings.cloudKitSync.footer")]
        if let lastError {
            parts.append(lastError)
        }
        if pendingRemoteReset {
            parts.append(String(localized: "settings.cloudKitSync.pendingReset.footer"))
        }
        if current == .enable {
            parts.append(AppInfo.localized("settings.cloudKitSync.foregroundOnly.footer"))
            // The rebuild hint lives in the dedicated rebuild section's footer now.
        }
        return parts.joined(separator: "\n")
    }

    static func setCurrent(_ value: CloudKitSync) throws {
        let oldValue = getValue()
        guard oldValue != value else { return }

        // Enabling sync is a Pro feature. Defense-in-depth: the UI routes non-Pro
        // users to the paywall before reaching here, and lifetime membership never
        // lapses, so launch-time syncIfEnabled() (which reads the stored flag, not
        // this setter) stays valid.
        if value == .enable, User.shared.proTier() == .none {
            throw SettingsError.needsPro
        }

        setLastError(nil, postsUpdate: false)
        if value == .enable {
            // A stale flag would otherwise resurface the "disabled by account
            // change" alert even though sync is running again.
            userDefaults.removeObject(forKey: UserDefaults.Settings.CloudKitSyncDisabledByAccountChange.rawValue)
        }
        if value == .disable {
            // Set BEFORE sync is durably disabled: the actual cleanup runs a
            // main-queue hop later (.cloudKitSyncDidChange → AppDelegate →
            // disableSyncAndClearLocalState). A kill between the disable write
            // and that hop would otherwise leave the stored engine state behind
            // with no flag — and the next re-enable would silently skip offline
            // reconciliation. Two deliberate costs: a kill after the flag but
            // before the disable write yields one spurious cleanup pass, and a
            // fast disable→enable toggle (cleanup never ran) makes the next
            // sync pay a cleanup-and-reconcile pass — which is also the only
            // thing that ships edits made while sync was briefly off.
            setPendingDisableCleanup(true)
        }
        userDefaults.set(value.rawValue, forKey: getKey())
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .SettingsUpdate, object: nil)
            NotificationCenter.default.post(name: .cloudKitSyncDidChange, object: nil)
        }
    }

    static func disableAfterAccountChange() {
        // Called from the sync engine's background executor. The value write must
        // stay synchronous (the sync loop checks `current` immediately after), so
        // bypass MoreKit's setValue and post only from main.
        userDefaults.set(CloudKitSync.disable.rawValue, forKey: getKey())
        setLastError(String(localized: "settings.cloudKitSync.error.accountChanged"), postsUpdate: false)
        userDefaults.set(true, forKey: UserDefaults.Settings.CloudKitSyncDisabledByAccountChange.rawValue)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .SettingsUpdate, object: nil)
        }
    }

    static var disabledByAccountChange: Bool {
        userDefaults.bool(forKey: UserDefaults.Settings.CloudKitSyncDisabledByAccountChange.rawValue)
    }

    /// Mirror of the user's last default-style change wall-clock time, written
    /// regardless of whether sync is on. Lets re-enable reconciliation ship the
    /// real timestamp instead of the moment the user toggled sync back on.
    static var defaultStyleLocalModificationTime: Int64 {
        let value = userDefaults.object(forKey: UserDefaults.Settings.DefaultStyleModificationTime.rawValue)
        if let int = value as? Int64 { return int }
        if let number = value as? NSNumber { return number.int64Value }
        return 0
    }

    static func setDefaultStyleLocalModificationTime(_ value: Int64) {
        userDefaults.set(NSNumber(value: value), forKey: UserDefaults.Settings.DefaultStyleModificationTime.rawValue)
    }

    static func consumeDisabledByAccountChange() -> Bool {
        let value = disabledByAccountChange
        if value {
            userDefaults.removeObject(forKey: UserDefaults.Settings.CloudKitSyncDisabledByAccountChange.rawValue)
        }
        return value
    }

    static var lastError: String? {
        userDefaults.getString(forKey: UserDefaults.Settings.CloudKitSyncLastError.rawValue)
    }

    static func setLastError(_ message: String?, postsUpdate: Bool = true) {
        let normalized = (message?.isEmpty == false) ? message : nil
        // Every sync pass ends in setLastError; an unchanged value (usually
        // nil → nil) must not broadcast .SettingsUpdate, or each no-op sync
        // rebuilds the settings page, main menu, and every visible cell menu.
        guard normalized != lastError else { return }
        if let normalized {
            userDefaults.set(normalized, forKey: UserDefaults.Settings.CloudKitSyncLastError.rawValue)
        } else {
            userDefaults.removeObject(forKey: UserDefaults.Settings.CloudKitSyncLastError.rawValue)
        }

        guard postsUpdate else { return }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .SettingsUpdate, object: nil)
        }
    }

    static var remoteDataMayExist: Bool {
        userDefaults.bool(forKey: UserDefaults.Settings.CloudKitRemoteDataMayExist.rawValue)
    }

    static var pendingRemoteReset: Bool {
        userDefaults.bool(forKey: UserDefaults.Settings.CloudKitPendingRemoteReset.rawValue)
    }

    /// Set for the duration of "clear CloudKit data": from just before the zone
    /// deletion until the new reset marker and the local cleanup have landed.
    /// If it survives to the next launch, the clear was interrupted mid-flight —
    /// the zone may be missing its reset marker, which peers would misread as
    /// accidental loss and re-upload everything.
    static var pendingRemoteClear: Bool {
        userDefaults.bool(forKey: UserDefaults.Settings.CloudKitPendingRemoteClear.rawValue)
    }

    static func setPendingRemoteClear(_ value: Bool) {
        if value {
            userDefaults.set(true, forKey: UserDefaults.Settings.CloudKitPendingRemoteClear.rawValue)
        } else {
            userDefaults.removeObject(forKey: UserDefaults.Settings.CloudKitPendingRemoteClear.rawValue)
        }
    }

    /// The disable-time state cleanup runs as a deferred asyncWrite (it must not
    /// block the main thread). If the app is killed before that write lands, the
    /// stored engine state survives the disable — and a later re-enable would
    /// skip offline reconciliation and silently never push edits/deletes made
    /// while sync was off. This flag is set synchronously at disable time and
    /// consumed once the cleanup actually commits, so the next sync can finish
    /// an interrupted cleanup first.
    static var pendingDisableCleanup: Bool {
        userDefaults.bool(forKey: UserDefaults.Settings.CloudKitPendingDisableCleanup.rawValue)
    }

    static func setPendingDisableCleanup(_ value: Bool) {
        if value {
            userDefaults.set(true, forKey: UserDefaults.Settings.CloudKitPendingDisableCleanup.rawValue)
        } else {
            userDefaults.removeObject(forKey: UserDefaults.Settings.CloudKitPendingDisableCleanup.rawValue)
        }
    }

    static func markRemoteDataMayExist() {
        userDefaults.set(true, forKey: UserDefaults.Settings.CloudKitRemoteDataMayExist.rawValue)
    }

    static func clearRemoteDataMayExist() {
        userDefaults.removeObject(forKey: UserDefaults.Settings.CloudKitRemoteDataMayExist.rawValue)
    }

    static func setPendingRemoteReset(_ value: Bool) {
        guard value != pendingRemoteReset else { return }
        if value {
            userDefaults.set(true, forKey: UserDefaults.Settings.CloudKitPendingRemoteReset.rawValue)
        } else {
            userDefaults.removeObject(forKey: UserDefaults.Settings.CloudKitPendingRemoteReset.rawValue)
        }
        // The settings footer surfaces this state; setLastError dedupes nil→nil
        // and no longer refreshes the page incidentally.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .SettingsUpdate, object: nil)
        }
    }
}

extension AutoBackup: UserDefaultSettable {
    static func getKey() -> String {
        return UserDefaults.Settings.AutoBackup.rawValue
    }

    static var defaultOption: AutoBackup {
        return .disable
    }

    func getName() -> String {
        return "\(rawValue)"
    }

    static func getTitle() -> String {
        return ""
    }
}

enum AutoStartLiveActivity: Int, CaseIterable, Codable {
    case withContent = 0
    case appLaunch
    case disable
}

extension AutoStartLiveActivity: UserDefaultSettable {
    static func getKey() -> String {
        UserDefaults.Settings.AutoStartLiveActivity.rawValue
    }

    static var defaultOption: AutoStartLiveActivity {
        return .withContent
    }

    func getName() -> String {
        switch self {
        case .withContent:
            return String(localized: "settings.autoStartLiveActivity.enableOnlyWithContent")
        case .appLaunch:
            return String(localized: "settings.autoStartLiveActivity.appLaunch")
        case .disable:
            return String(localized: "settings.disable")
        }
    }

    static func getTitle() -> String {
        return String(localized: "settings.autoStartLiveActivity.title")
    }
}

enum AutoEndLiveActivity: Int, CaseIterable, Codable {
    case noContent = 0
    case disable
}

extension AutoEndLiveActivity: UserDefaultSettable {
    static func getKey() -> String {
        UserDefaults.Settings.AutoEndLiveActivity.rawValue
    }

    static var defaultOption: AutoEndLiveActivity {
        return .noContent
    }

    func getName() -> String {
        switch self {
        case .noContent:
            return String(localized: "settings.autoEndLiveActivity.noContent")
        case .disable:
            return String(localized: "settings.disable")
        }
    }

    static func getTitle() -> String {
        return String(localized: "settings.autoEndLiveActivity.title")
    }
}

enum MaxPinnedPosts: Int, CaseIterable, Codable {
    case unlimited = 0
    case one
}

extension MaxPinnedPosts: UserDefaultSettable {
    static func getKey() -> String {
        UserDefaults.Settings.MaxPinnedPosts.rawValue
    }
    
    static var defaultOption: Self {
        return .one
    }
    
    func getName() -> String {
        switch self {
        case .unlimited:
            return String(localized: "settings.maxPinnedPosts.unlimited")
        case .one:
            return String(localized: "settings.maxPinnedPosts.one")
        }
    }
    
    static func getTitle() -> String {
        return String(localized: "settings.maxPinnedPosts.title")
    }
    
    static func setCurrent(_ value: MaxPinnedPosts) throws {
        switch User.shared.proTier() {
        case .lifetime:
            setValue(value)
        case .none:
            switch value {
            case .unlimited:
                throw SettingsError.needsPro
            case .one:
                setValue(value)
            }
        }
    }
}

enum ThanksEntryState: Int, CaseIterable, Codable {
    case hidden = 0
    case display
}

extension ThanksEntryState: UserDefaultSettable {
    static func getKey() -> String {
        UserDefaults.Settings.ThanksEntryState.rawValue
    }

    static var defaultOption: Self {
        return .display
    }

    func getName() -> String {
        return "\(rawValue)"
    }

    static func getTitle() -> String {
        return ""
    }
}

enum DeleteOperationConfirmation: Int, CaseIterable, Codable {
    case enable = 0
    case disable
    case disableUntilAppBackgrounds
}

extension DeleteOperationConfirmation: UserDefaultSettable {
    static func getKey() -> String {
        UserDefaults.Settings.DeleteOperationConfirmation.rawValue
    }

    static var defaultOption: Self {
        return .enable
    }

    func getName() -> String {
        switch self {
        case .enable:
            return String(localized: "settings.enable")
        case .disable:
            return String(localized: "settings.disable")
        case .disableUntilAppBackgrounds:
            return String(localized: "settings.deleteOperationConfirmation.disableUntilAppBackgrounds")
        }
    }

    static func getTitle() -> String {
        return String(localized: "settings.deleteOperationConfirmation.title")
    }
}

enum ExpirationAction: Int, CaseIterable, Codable {
    case unpin = 0
    case delete
}

extension ExpirationAction: UserDefaultSettable {
    static func getKey() -> String {
        UserDefaults.Settings.ExpirationAction.rawValue
    }

    static var defaultOption: Self {
        return .unpin
    }

    func getName() -> String {
        switch self {
        case .unpin:
            return String(localized: "settings.expirationAction.unpin")
        case .delete:
            return String(localized: "settings.expirationAction.delete")
        }
    }

    static func getTitle() -> String {
        return String(localized: "settings.expirationAction.title")
    }

    static func getFooter() -> String? {
        return String(localized: "settings.expirationAction.footer")
    }
}

enum DefaultExpirationTime: Int, CaseIterable, Codable {
    case `none` = -1
    case min5 = 300
    case min10 = 600
    case min30 = 1800
    case hour1 = 3600
    case hour6 = 21600
    case hour12 = 43200
    case day1 = 86400
    case day2 = 172800
    case day3 = 259200
    case day4 = 345600
    case day5 = 432000
    case day6 = 518400
    case day7 = 604800

    var duration: Duration? {
        if rawValue > 0 {
            return Duration.seconds(rawValue)
        } else {
            return nil
        }
    }
    
    func localized() -> String? {
        guard let duration = duration else {
            return nil
        }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.maximumUnitCount = 2
        
        let totalSeconds = duration.components.seconds
        return formatter.string(from: TimeInterval(totalSeconds))
    }
}

extension DefaultExpirationTime: UserDefaultSettable {
    static func getKey() -> String {
        UserDefaults.Settings.DefaultExpirationTime.rawValue
    }

    static var defaultOption: Self {
        return .none
    }

    func getName() -> String {
        switch self {
        case .none:
            return String(localized: "settings.defaultExpirationTime.none")
        default:
            return localized() ?? ""
        }
    }

    static func getTitle() -> String {
        return String(localized: "settings.defaultExpirationTime.title")
    }

    static func getFooter() -> String? {
        return String(localized: "settings.defaultExpirationTime.footer")
    }
}

enum SettingsError: Swift.Error, LocalizedError {
    case needsPro

    var errorDescription: String? {
        switch self {
        case .needsPro:
            return String(localized: "error.needsPro.message")
        }
    }

    var message: String {
        switch self {
        case .needsPro:
            return String(localized: "error.needsPro.message")
        }
    }
}
