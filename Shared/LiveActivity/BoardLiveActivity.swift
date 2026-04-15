//
//  BoardLiveActivity.swift
//  Board
//
//  Created by Ci Zi on 2025/10/13.
//

import ActivityKit
import WidgetKit
import SwiftUI
import AppIntents
import NaturalLanguage
import MoreKit

struct PinContentView: View {
    enum DisplayType {
        case lockScreen
        case island
    }
    
    var context: ActivityViewContext<PinAttributes>
    
    var displayType: DisplayType
    
    var textColor: Color {
        switch displayType {
        case .lockScreen:
            return context.state.lockTextColor
        case .island:
            return context.state.islandTextColor
        }
    }
    
    var textSize: PostTextSize {
        switch displayType {
        case .lockScreen:
            return context.state.lockTextSize
        case .island:
            return context.state.islandTextSize
        }
    }
    
    var textAlignment: PostTextAlignment {
        switch displayType {
        case .lockScreen:
            return context.state.lockTextAlignment
        case .island:
            return context.state.islandTextAlignment
        }
    }
    
    var body: some View {
        ZStack {
            if #available(iOS 18.0, *) {
                Image("Clear")
                    .resizable()
                    .privacySensitive(false)
            }
            if context.state.total == 0 {
                AutoSizeText(text: String(localized: "content.no"), color: textColor, textAlignment: textAlignment, textSize: textSize)
            } else {
                if let post = try? SyncDataManager.loadPosts()?.posts.first(where: { $0.id == context.state.id }) {
                    switch post.content {
                    case .empty:
                        AutoSizeText(text: String(localized: "content.no"), color: textColor, textAlignment: textAlignment, textSize: textSize)
                    case .text(let string):
                        AutoSizeText(text: string, color: textColor, textAlignment: textAlignment, textSize: textSize)
                            .padding(context.state.needTransparentControl ? 10.0 : 0.0)
                    case .image(let string):
                        if let path = ImageCacheManager.shared.getPath(name: string, type: .processed), let image = UIImage(contentsOfFile: path) {
                            if context.state.imageDisplayMode == .aspectFill, displayType == .lockScreen {
                                Link(destination: BoardURL.detailURL(by: context)!) {
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFill()
                                        .clipShape(RoundedRectangle(cornerRadius: 10.0))
                                }
                            } else {
                                Link(destination: BoardURL.detailURL(by: context)!) {
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFit()
                                        .clipShape(RoundedRectangle(cornerRadius: 10.0))
                                }
                            }
                        } else {
                            AutoSizeText(text: String(localized: "content.error.load"), color: textColor, textAlignment: textAlignment, textSize: textSize)
                        }
                    }
                } else {
                    AutoSizeText(text: String(localized: "content.no"), color: textColor, textAlignment: textAlignment, textSize: textSize)
                }
            }
        }
    }
}

struct PinContentWatchView: View {
    var context: ActivityViewContext<PinAttributes>
    
    var textAlignment: TextAlignment {
        switch context.state.lockTextAlignment {
        case .leading:
            return .leading
        case .center:
            return .center
        case .trailing:
            return .trailing
        }
    }
    
    var body: some View {
        if let post = try? SyncDataManager.loadPosts()?.posts.first(where: { $0.id == context.state.id }) {
            switch post.content {
            case .empty:
                Text("content.no")
                    .foregroundStyle(context.state.lockTextColor)
            case .image:
                Text("content.error.watch")
                    .foregroundStyle(context.state.lockTextColor)
            case .text(let string):
                HStack {
                    Spacer().frame(width: 3.0)
                    VStack {
                        Spacer().frame(height: 1.5)
                        Text(string)
                            .font(.system(.body, design: .rounded).monospacedDigit())
                            .multilineTextAlignment(textAlignment)
                            .lineLimit(4)
                            .minimumScaleFactor(0.6)
                            .foregroundStyle(context.state.lockTextColor)
                        Spacer().frame(height: 1.5)
                    }
                }
            }
        } else {
            Text("content.no")
                .foregroundStyle(context.state.lockTextColor)
        }
    }
}

struct BoardLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PinAttributes.self) { context in
            BoardContent(context: context)
                .widgetURL(BoardURL.normalURL(by: context))
        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded UI goes here.  Compose the expanded UI through
                // various regions, like leading/trailing/center/bottom
                DynamicIslandExpandedRegion(.leading) {
                    DynamicIslandView(context: context, position: .leading)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    DynamicIslandView(context: context, position: .trailing)
                }
                DynamicIslandExpandedRegion(.center) {
                    DynamicIslandView(context: context, position: .center)
                }
            } compactLeading: {
                DynamicIslandView(context: context, position: .compactLeading)
            } compactTrailing: {
                DynamicIslandView(context: context, position: .compactTrailing)
            } minimal: {
                DynamicIslandView(context: context, position: .minimal)
            }
            .widgetURL(BoardURL.normalURL(by: context))
            .keylineTint(context.state.symbolColor)
        }
        .compatibleSupplementalActivityFamilies()
    }
}

extension WidgetConfiguration {
    @MainActor
    public func compatibleSupplementalActivityFamilies() -> some WidgetConfiguration {
        if #available(iOS 18.0, *) {
            return self.supplementalActivityFamilies([.small])
        } else {
            return self
        }
    }
}

struct BoardContent: View {
    var context: ActivityViewContext<PinAttributes>
    
    var body: some View {
        if #available(iOS 18.0, *) {
            BoardContentForiOS18AndAbove(context: context)
        } else {
            // 对于iOS 17.0以下，我们显示中等尺寸
            BoardMediumView(context: context)
                .background(context.state.lockBackgroundColor)
                .activityBackgroundTint(.clear)
                .activitySystemActionForegroundColor(Color.black)
        }
    }
}

@available(iOS 18.0, *)
struct BoardContentForiOS18AndAbove: View {
    @Environment(\.activityFamily) var activityFamily
    var context: ActivityViewContext<PinAttributes>
    
    var body: some View {
        switch activityFamily {
        case .small:
            BoardSmallView(context: context)
                .activityBackgroundTint(context.state.symbolColor)
        case .medium:
            BoardMediumView(context: context)
                .background(context.state.lockBackgroundColor)
                .activityBackgroundTint(.clear)
        @unknown default:
            Spacer()
        }
    }
}

struct BoardSmallView: View {
    var context: ActivityViewContext<PinAttributes>

    var body: some View {
        HStack {
            Spacer(minLength: 3.0)
            VStack {
                Spacer()
                    .frame(height: 3.0)
                PinContentWatchView(context: context)
                Spacer()
                    .frame(height: 3.0)
            }
            Spacer(minLength: 3.0)
            Button(intent: ButtonNextIntent()) {
                VStack {
                    Image(systemName: context.state.symbol)
                        .rotationEffect(Angle.degrees(context.state.symbolAngle))
                        .foregroundColor(context.state.symbolColor)
                    Text(context.state.indexString)
                        .font(Font.system(size: 9.0, weight: .bold))
                        .foregroundColor(context.state.symbolColor)
                }
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle)
            .tint(.white)
            Spacer().frame(width: 6.0)
        }
    }
}

struct BoardMediumView: View {
    var context: ActivityViewContext<PinAttributes>
    
    var body: some View {
        if context.state.needTransparentControl {
            ZStack {
                if #available(iOS 18.0, *) {
                    Image("Clear")
                        .resizable()
                        .privacySensitive(false)
                }
                HStack {
                    VStack {
                        Button(intent: ResetAndUpdateIntent()) {
                            Image(systemName: context.state.symbol)
                                .rotationEffect(Angle.degrees(context.state.symbolAngle))
                        }
                        .tint(context.state.symbolColor)
                        .privacySensitive(false)
                        
                        Spacer(minLength: 4.0)
                        
                        if context.state.isActionable {
                            Link(destination: BoardURL.actionURL(by: context)!) {
                                Image(systemName: "arrow.up.forward")
                                    .foregroundColor(.secondary)
                            }

                            Spacer(minLength: 4.0)
                            
                            Spacer().frame(height: 4.0)
                        }
                        
                        Button(intent: ButtonUnpinIntent()) {
                            Image(systemName: "pin.slash")
                        }
                        .buttonStyle(.borderless)
                        .tint(.secondary)
                        .privacySensitive(false)
                        
                        Spacer().frame(height: 4.0)
                    }
                    .padding(12.0)
                    .opacity(0.001)
                    .allowsHitTesting(true)
                    VStack {
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    VStack {
                        Button(intent: ButtonPreviousIntent()) {
                            Image(systemName: "chevron.up")
                                .frame(minHeight: 21.0)
                        }
                        .tint(.primary)
                        .privacySensitive(false)
                        
                        Spacer(minLength: 18.0)
                            .frame(maxHeight: .infinity)
                        
                        Text(context.state.indexString)
                            .font(Font.footnote)
                            .foregroundStyle(.secondary)
                        
                        Spacer(minLength: 18.0)
                            .frame(maxHeight: .infinity)
                        
                        Button(intent: ButtonNextIntent()) {
                            Image(systemName: "chevron.down")
                                .frame(minHeight: 21.0)
                        }
                        .tint(.primary)
                        .privacySensitive(false)
                    }
                    .padding(12.0)
                }
                .opacity(0.001)
                .allowsHitTesting(true)
                .background {
                    VStack {
                        if User.shared.proTier() == .lifetime {
                            PinContentView(context: context, displayType: .lockScreen)
                        } else {
                            PinContentView(context: context, displayType: .lockScreen)
                            Text("advertising.banner")
                                .foregroundStyle(.secondary.opacity(0.8))
                                .scaleEffect(0.8)
                                .frame(height: 10.0)
                            Spacer()
                                .frame(height: 16.0)
                        }
                    }
                }
            }
        } else {
            HStack {
                VStack {
                    Button(intent: ResetAndUpdateIntent()) {
                        Image(systemName: context.state.symbol)
                            .rotationEffect(Angle.degrees(context.state.symbolAngle))
                    }
                    .tint(context.state.symbolColor)
                    .privacySensitive(false)
                    
                    Spacer(minLength: 4.0)
                    
                    if context.state.isActionable {
                        Link(destination: BoardURL.actionURL(by: context)!) {
                            Image(systemName: "arrow.up.forward")
                                .foregroundColor(.secondary)
                        }

                        Spacer(minLength: 4.0)
                        
                        Spacer().frame(height: 4.0)
                    }
                    
                    Button(intent: ButtonUnpinIntent()) {
                        Image(systemName: "pin.slash")
                    }
                    .buttonStyle(.borderless)
                    .tint(.secondary)
                    .privacySensitive(false)
                    
                    Spacer().frame(height: 4.0)
                }
                .padding(12.0)
                VStack {
                    if User.shared.proTier() == .lifetime {
                        Spacer()
                            .frame(height: 12.0)
                        PinContentView(context: context, displayType: .lockScreen)
                        Spacer()
                            .frame(height: 12.0)
                    } else {
                        Spacer()
                            .frame(height: 16.0)
                        PinContentView(context: context, displayType: .lockScreen)
                        Text("advertising.banner")
                            .foregroundStyle(.secondary.opacity(0.8))
                            .scaleEffect(0.8)
                            .frame(height: 10.0)
                        Spacer()
                            .frame(height: 16.0)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                VStack {
                    Button(intent: ButtonPreviousIntent()) {
                        Image(systemName: "chevron.up")
                            .frame(minHeight: 21.0)
                    }
                    .tint(.primary)
                    .privacySensitive(false)
                    
                    Spacer(minLength: 18.0)
                        .frame(maxHeight: .infinity)
                    
                    Text(context.state.indexString)
                        .font(Font.footnote)
                        .foregroundStyle(.secondary)
                    
                    Spacer(minLength: 18.0)
                        .frame(maxHeight: .infinity)
                    
                    Button(intent: ButtonNextIntent()) {
                        Image(systemName: "chevron.down")
                            .frame(minHeight: 21.0)
                    }
                    .tint(.primary)
                    .privacySensitive(false)
                }
                .padding(12.0)
            }
        }
    }
}

struct BoardURL {
    static let url = "https://pin.zizicici.com/widget"
    
    static func detailURL(by context: ActivityViewContext<PinAttributes>) -> URL? {
        if let postId = context.state.id {
            return URL(string: url + "/detail/" + "\(postId)")
        } else {
            return URL(string: url + "/detail/")
        }
    }
    
    static func normalURL(by context: ActivityViewContext<PinAttributes>) -> URL? {
        if let postId = context.state.id {
            return URL(string: url + "\(postId)")
        } else {
            return URL(string: url)
        }
    }
    
    static func actionURL(by context: ActivityViewContext<PinAttributes>) -> URL? {
        if let postId = context.state.id {
            return URL(string: url + "/action/" + "\(postId)")
        } else {
            return URL(string: url + "/action/")
        }
    }
}
