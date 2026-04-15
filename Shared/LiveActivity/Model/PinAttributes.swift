//
//  PinAttributes.swift
//  Pin It
//
//  Created by Ci Zi on 2025/10/14.
//

import Foundation
import ActivityKit
import SwiftUI
import WidgetKit
import MoreKit

struct PinAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var id: Int64?
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

extension PinAttributes.ContentState {
    var style: PostStyle? {
        return SyncDataManager.style(by: id)
    }
    
    var post: SyncPost? {
        guard let id = id else {
            return nil
        }
        return SyncDataManager.post(by: id)
    }
    
    var symbol: String {
        return style?.symbol ?? "pin.fill"
    }
    
    var symbolColor: Color {
        let defaultColor: Color = .red
        if let symbolColor = style?.symbolColor {
            if let uiColor = UIColor(string: symbolColor) {
                return Color(uiColor: uiColor)
            } else {
                return defaultColor
            }
        } else {
            return defaultColor
        }
    }
    
    var symbolAngle: Double {
        let defaultAngle: Double = -45.0
        if let symbolAngle = style?.symbolAngle {
            return Double(symbolAngle) / 100.0
        } else {
            return defaultAngle
        }
    }
    
    var lockBackgroundColor: Color {
        let defaultColor: Color
        if #available(iOS 26.0, *) {
            defaultColor = .clear
        } else {
            defaultColor = Color("WidgetBackgroundColor")
        }
        if let lockBackgroundColor = style?.lockBackgroundColor {
            if let uiColor = UIColor(string: lockBackgroundColor) {
                return Color(uiColor: uiColor)
            } else {
                return defaultColor
            }
        } else {
            return defaultColor
        }
    }
    
    var lockTextColor: Color {
        let defaultColor = Color.primary
        
        if let lockTextColor = style?.lockTextColor {
            if let uiColor = UIColor(string: lockTextColor) {
                return Color(uiColor: uiColor)
            } else {
                return defaultColor
            }
        } else {
            return defaultColor
        }
    }
    
    var islandTextColor: Color {
        let defaultColor = Color.primary
        
        if let islandTextColor = style?.islandTextColor {
            if let uiColor = UIColor(string: islandTextColor) {
                return Color(uiColor: uiColor)
            } else {
                return defaultColor
            }
        } else {
            return defaultColor
        }
    }
    
    var lockTextSize: PostTextSize {
        let defaultSize = PostTextSize.automatic
        
        return style?.lockTextSize ?? defaultSize
    }
    
    var islandTextSize: PostTextSize {
        let defaultSize = PostTextSize.automatic
        
        return style?.islandTextSize ?? defaultSize
    }
    
    var lockTextAlignment: PostTextAlignment {
        let defaultValue = PostTextAlignment.center
        
        return style?.lockTextAlignment ?? defaultValue
    }
    
    var islandTextAlignment: PostTextAlignment {
        let defaultValue = PostTextAlignment.center
        
        return style?.islandTextAlignment ?? defaultValue
    }
    
    var imageDisplayMode: PostImageDisplayMode {
        let defaultMode: PostImageDisplayMode = .aspectFit
        
        return style?.imageDisplayMode ?? defaultMode
    }
    
    var controlAlpha: Int {
        return style?.controlAlpha ?? 100
    }
    
    var needTransparentControl: Bool {
        return controlAlpha == 0
    }
    
    var isActionable: Bool {
        guard let post = post else { return false }
        return !post.actionLink.isEmpty
    }
}
