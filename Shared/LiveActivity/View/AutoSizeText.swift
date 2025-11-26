//
//  AutoSizeText.swift
//  Pin It
//
//  Created by Ci Zi on 2025/11/26.
//

import SwiftUI

struct AutoSizeText: View {
    let text: String
    let color: Color
    let textAlignment: PostTextAlignment
    let textSize: PostTextSize
    
    var appliedTextAlignment: TextAlignment {
        switch textAlignment {
        case .leading:
            return .leading
        case .center:
            return .center
        case .trailing:
            return .trailing
        }
    }
    
    var appliedFont: Font {
        switch textSize {
        case .automatic:
            return .system(.title, design: .rounded).monospacedDigit()
        default:
            return .system(size: CGFloat(textSize.rawValue), design: .rounded).monospaced()
        }
    }
    
    var body: some View {
        Text(text)
            .font(appliedFont)
            .multilineTextAlignment(appliedTextAlignment)
            .lineLimit(nil)
            .minimumScaleFactor(textSize == .automatic ? 0.6 : 1.0)
            .foregroundStyle(color)
    }
}
