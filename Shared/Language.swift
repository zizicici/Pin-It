//
//  Language.swift
//  Pin It
//
//  Created by Ci Zi on 2025/11/13.
//

import Foundation

struct Language {
    enum LanguageType {
        case zh
        case en
        case ja
        case ko
        case ar
    }
    
    static func type() -> LanguageType? {
        guard let preferredLocalization = Bundle.main.preferredLocalizations.first else {
            return nil
        }
        switch preferredLocalization {
        case "ko":
            return .ko
        case "ja":
            return .ja
        case "zh-Hans", "zh-Hant", "zh-HK":
            return .zh
        case "ar":
            return .ar
        default:
            return .en
        }
    }
}
