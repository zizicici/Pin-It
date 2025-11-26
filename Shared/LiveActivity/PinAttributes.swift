//
//  PinAttributes.swift
//  Pin It
//
//  Created by Ci Zi on 2025/10/14.
//

import Foundation
import ActivityKit

struct PinAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var id: Int
        var index: Int
        var total: Int
        var isLeftToRight: Bool
        
        var indexString: String {
            if total == 0 {
                return ""
            } else {
                return String(format: String(localized: "content.index%d%d"), index + 1, total)                
            }
        }
    }
    
    var name: String
}
