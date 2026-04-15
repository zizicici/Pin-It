//
//  PostStyle+OptionItem.swift
//  Pin It
//
//  Created by Ci Zi on 2025/11/26.
//

import Foundation
import MoreKit

extension PostStyle: OptionItem {
    static var noneTitle: String {
        return String(format: String(localized: "style.default%@"), DefaultStyle.getValue().getName())
    }
    
    static var sectionTitle: String {
        return String(localized: "style.title")
    }
    
    var title: String {
        return name
    }
    
    var subtitle: String? {
        return nil
    }
}
