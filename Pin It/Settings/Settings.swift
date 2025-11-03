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
    static var current: Self { get set}
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
            return lhs.getName() == rhs.getName()
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
        set {
            setValue(newValue)
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
        return ""
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
}
