//
//  ConsideringUser.swift
//  Pin It
//
//  Created by Salley Garden on 2025/10/19.
//

import Foundation
import UIKit

struct ConsideringUser {
    static var animated: Bool {
        return UIAccessibility.isReduceMotionEnabled ? false : true
    }
    
    static var pushAnimated: Bool {
        return UIAccessibility.prefersCrossFadeTransitions ? false : true
    }
    
    static var buttonShapesEnabled: Bool {
        return UIAccessibility.buttonShapesEnabled
    }
}
