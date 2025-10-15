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
        var text: String?
        var imageName: String?
    }
    
    var name: String
}
