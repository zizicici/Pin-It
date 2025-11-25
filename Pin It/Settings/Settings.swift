//
//  Settings.swift
//  Pin It
//
//  Created by Ci Zi on 2025/4/29.
//

import Foundation

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
    }
}

extension Notification.Name {
    static let SettingsUpdate = Notification.Name(rawValue: "com.zizicici.common.settings.updated")
}

protocol SettingsOption: Hashable, Equatable {
    func getName() -> String
    static func getHeader() -> String?
    static func getFooter() -> String?
    static func getTitle() -> String
    static func getOptions() -> [Self]
    static var current: Self { get }
    static func setCurrent(_ value: Self) throws
}

extension SettingsOption {
    static func getHeader() -> String? {
        return nil
    }
    
    static func getFooter() -> String? {
        return nil
    }
}

extension SettingsOption {
    static func == (lhs: Self, rhs: Self) -> Bool {
        if type(of: lhs) != type(of: rhs) {
            return false
        } else {
            return lhs.hashValue == rhs.hashValue
        }
    }
}

protocol UserDefaultSettable: SettingsOption {
    static func getKey() -> UserDefaults.Settings
    static var defaultOption: Self { get }
}

extension UserDefaultSettable where Self: RawRepresentable, Self.RawValue == Int {
    static func getValue() -> Self {
        if let intValue = UserDefaults(suiteName: appGroupId)?.getInt(forKey: getKey().rawValue), let value = Self(rawValue: intValue) {
            return value
        } else {
            return defaultOption
        }
    }
    
    static func setValue(_ value: Self) {
        UserDefaults(suiteName: appGroupId)?.set(value.rawValue, forKey: getKey().rawValue)
        UserDefaults(suiteName: appGroupId)?.synchronize()
        NotificationCenter.default.post(name: NSNotification.Name.SettingsUpdate, object: nil)
    }
    
    static func getOptions<T: CaseIterable>() -> [T] {
        return Array(T.allCases)
    }
    
    static var current: Self {
        get {
            return getValue()
        }
    }
}

extension UserDefaults {
    func getInt(forKey key: String) -> Int? {
        return object(forKey: key) as? Int
    }
    
    func getBool(forKey key: String) -> Bool? {
        return object(forKey: key) as? Bool
    }
    
    func getString(forKey key: String) -> String? {
        return object(forKey: key) as? String
    }
}

enum AutoBackup: Int, CaseIterable, Codable {
    case enable
    case disable
}

extension AutoBackup: UserDefaultSettable {
    static func getKey() -> UserDefaults.Settings {
        return .AutoBackup
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
    
    static func setCurrent(_ value: AutoBackup) throws {
        setValue(value)
    }
}

enum AutoStartLiveActivity: Int, CaseIterable, Codable {
    case withContent = 0
    case appLaunch
    case disable
}

extension AutoStartLiveActivity: UserDefaultSettable {
    static func getKey() -> UserDefaults.Settings {
        .AutoStartLiveActivity
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
    
    static func setCurrent(_ value: AutoStartLiveActivity) throws {
        setValue(value)
    }
}

enum AutoEndLiveActivity: Int, CaseIterable, Codable {
    case noContent = 0
    case disable
}

extension AutoEndLiveActivity: UserDefaultSettable {
    static func getKey() -> UserDefaults.Settings {
        .AutoEndLiveActivity
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
    
    static func setCurrent(_ value: AutoEndLiveActivity) throws {
        setValue(value)
    }
}

enum MaxPinnedPosts: Int, CaseIterable, Codable {
    case unlimited = 0
    case one
}

extension MaxPinnedPosts: UserDefaultSettable {
    static func getKey() -> UserDefaults.Settings {
        .MaxPinnedPosts
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
    static func getKey() -> UserDefaults.Settings {
        .ThanksEntryState
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
    
    static func setCurrent(_ value: Self) throws {
        setValue(value)
    }
}

enum DeleteOperationConfirmation: Int, CaseIterable, Codable {
    case enable = 0
    case disable
    case disableUntilAppBackgrounds
}

extension DeleteOperationConfirmation: UserDefaultSettable {
    static func getKey() -> UserDefaults.Settings {
        .DeleteOperationConfirmation
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
    
    static func setCurrent(_ value: Self) throws {
        setValue(value)
    }
}

enum ExpirationAction: Int, CaseIterable, Codable {
    case unpin = 0
    case delete
}

extension ExpirationAction: UserDefaultSettable {
    static func getKey() -> UserDefaults.Settings {
        return .ExpirationAction
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
    
    static func setCurrent(_ value: Self) throws {
        setValue(value)
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
    static func getKey() -> UserDefaults.Settings {
        return .DefaultExpirationTime
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
    
    static func setCurrent(_ value: Self) throws {
        setValue(value)
    }
    
    static func getFooter() -> String? {
        return String(localized: "settings.defaultExpirationTime.footer")
    }
}

enum SettingsError: Swift.Error {
    case needsPro
    
    var message: String {
        switch self {
        case .needsPro:
            return String(localized: "error.needsPro.message")
        }
    }
}
