import os.log
import Foundation

let logger = Logger(subsystem: "Pin", category: "debugging")
let appGroupId = "group.com.zizicici.pin"
let cloudKitContainerIdentifier = "iCloud.com.zizicici.pin"

enum AppInfo {
    static var displayName: String {
        if let displayName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
           !displayName.isEmpty {
            return displayName
        }
        if let bundleName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String,
           !bundleName.isEmpty {
            return bundleName
        }
        return "Pin It"
    }

    static func localized(_ key: String.LocalizationValue) -> String {
        String(format: String(localized: key), displayName)
    }
}
