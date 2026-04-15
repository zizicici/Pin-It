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
    }
}

extension Notification.Name {
    static let DefaultStyleDidChanged = Notification.Name(rawValue: "com.zizicici.pin.defaultStyle.didChanged")
}

enum AutoBackup: Int, CaseIterable, Codable {
    case enable
    case disable
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
