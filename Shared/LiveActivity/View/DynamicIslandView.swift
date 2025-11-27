//
//  DynamicIslandView.swift
//  Pin It
//
//  Created by Ci Zi on 2025/11/26.
//

import SwiftUI
import WidgetKit
import AppIntents

struct DynamicIslandView: View {
    enum Position {
        case leading
        case trailing
        case center
        case compactLeading
        case compactTrailing
        case minimal
    }
    
    var context: ActivityViewContext<PinAttributes>
    
    var position: Position
    
    var body: some View {
        switch position {
        case .leading:
            VStack {
                Button(intent: ResetAndUpdateIntent()) {
                    Image(systemName: context.state.symbol)
                        .rotationEffect(Angle.degrees(-45.0))
                }
                .tint(context.state.symbolColor)
                
                Spacer(minLength: 4.0)
                
                Button(intent: ButtonUnpinIntent()) {
                    Image(systemName: "pin.slash")
                }
                .buttonStyle(.borderless)
                .tint(.secondary)
                
                Spacer().frame(height: 4.0)
            }
        case .trailing:
            VStack {
                Button(intent: ButtonPreviousIntent()) {
                    Image(systemName: "chevron.up")
                        .frame(minHeight: 21.0)
                }
                .tint(.primary)
                
                Spacer(minLength: 18.0)
                
                Text(context.state.indexString)
                    .font(Font.footnote)
                    .foregroundStyle(.secondary)
                
                Spacer(minLength: 18.0)
                
                Button(intent: ButtonNextIntent()) {
                    Image(systemName: "chevron.down")
                        .frame(minHeight: 21.0)
                }
                .tint(.primary)
            }
            .frame(maxHeight: .infinity)
        case .center:
            VStack {
                PinContentView(context: context, displayType: .island)
                if User.shared.proTier() == .lifetime {
                    Spacer(minLength: 16.0)
                } else {
                    Text("advertising.banner")
                        .foregroundStyle(.secondary.opacity(0.8))
                        .scaleEffect(0.8)
                        .frame(height: 16.0)
                }
            }
        case .compactLeading:
            if context.state.isLeftToRight {
                HStack {
                    Spacer().frame(width: 3.0)
                    Image(systemName: context.state.symbol)
                        .font(.system(size: 12))
                        .foregroundColor(context.state.symbolColor)
                        .rotationEffect(Angle.degrees(-45.0))
                }
            }
        case .compactTrailing:
            if !context.state.isLeftToRight {
                HStack {
                    Spacer().frame(width: 10.0)
                    Image(systemName: context.state.symbol)
                        .font(.system(size: 12))
                        .foregroundColor(context.state.symbolColor)
                        .rotationEffect(Angle.degrees(-45.0))
                }
            }
        case .minimal:
            Spacer().frame(width: 20.0)
            Image(systemName: context.state.symbol)
                .font(.system(size: 12))
                .foregroundColor(context.state.symbolColor)
                .rotationEffect(Angle.degrees(-45.0))
            Spacer().frame(width: 20.0)
        }
    }
}
