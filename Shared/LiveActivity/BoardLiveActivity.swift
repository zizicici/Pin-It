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

struct PinContentView: View {
    var context: ActivityViewContext<PinAttributes>
    
    var body: some View {
        ZStack {
            Image("Clear")
                .resizable()
                .privacySensitive(false)
            if context.state.total == 0 {
                AutoSizeText(text: String(localized: "content.no"))
            } else {
                if let text = context.state.text {
                    AutoSizeText(text: text)
                } else if let imageName = context.state.imageName {
                    if let path = ImageCacheManager.shared.getPath(name: imageName, type: .processed), let image = UIImage(contentsOfFile: path) {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 10.0))
                    } else {
                        AutoSizeText(text: String(localized: "content.error.load"))
                    }
                } else {
                    AutoSizeText(text: String(localized: "content.no"))
                }
            }
        }
    }
}

struct PinContentWatchView: View {
    var context: ActivityViewContext<PinAttributes>
    
    var body: some View {
        if let text = context.state.text {
            HStack {
                Spacer().frame(width: 3.0)
                VStack {
                    Spacer().frame(height: 1.5)
                    Text(text)
                        .font(.system(.body, design: .rounded).monospacedDigit())
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                        .minimumScaleFactor(0.6)
                    Spacer().frame(height: 1.5)
                }
            }
        } else {
            Text("content.error.watch")
        }
    }
}

struct BoardLiveActivity: Widget {
    static let url = "https://pin.zizicici.com/widget"
    
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PinAttributes.self) { context in
            BoardContent(context: context)
                .widgetURL(URL(string: Self.url + "/" + "\(context.state.id)"))
        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded UI goes here.  Compose the expanded UI through
                // various regions, like leading/trailing/center/bottom
                DynamicIslandExpandedRegion(.leading) {
                    VStack {
                        Button(intent: ButtonEmptyIntent()) {
                            Image(systemName: "pin.fill")
                                .rotationEffect(Angle.degrees(-45.0))
                        }
                        .tint(.red)
                        
                        Spacer(minLength: 4.0)
                        
                        Button(intent: ButtonUnpinIntent()) {
                            Image(systemName: "pin.slash")
                        }
                        .buttonStyle(.borderless)
                        .tint(.secondary)
                        
                        Spacer().frame(height: 4.0)
                    }
                    //.background(.white)
                }
                DynamicIslandExpandedRegion(.trailing) {
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
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack {
                        PinContentView(context: context)
                        if User.shared.proTier() == .lifetime {
                            Spacer(minLength: 16.0)
                        } else {
                            Text("advertising.banner")
                                .foregroundStyle(.secondary.opacity(0.8))
                                .scaleEffect(0.8)
                                .frame(height: 16.0)
                        }
                    }
                }
            } compactLeading: {
                if context.state.isLeftToRight {
                    HStack {
                        Spacer().frame(width: 3.0)
                        Image(systemName: "pin.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.red)
                            .rotationEffect(Angle.degrees(-45.0))
                    }
                }
            } compactTrailing: {
                if !context.state.isLeftToRight {
                    HStack {
                        Spacer().frame(width: 10.0)
                        Image(systemName: "pin.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.red)
                            .rotationEffect(Angle.degrees(-45.0))
                    }
                }
            } minimal: {
                Spacer().frame(width: 20.0)
                Image(systemName: "pin.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.red)
                    .rotationEffect(Angle.degrees(-45.0))
                Spacer().frame(width: 20.0)
            }
            .widgetURL(URL(string: Self.url + "/" + "\(context.state.id)"))
            .keylineTint(Color.red)
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

struct AutoSizeText: View {
    let text: String
    
    var body: some View {
        Text(text)
            .font(.system(.title, design: .rounded).monospacedDigit())
            .multilineTextAlignment(.center)
            .lineLimit(5)
            .minimumScaleFactor(0.6)
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
                .background(Color("WidgetBackgroundColor"))
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
                .activityBackgroundTint(.red)
        case .medium:
            if #available(iOS 26.0, *) {
                BoardMediumView(context: context)
                    .activityBackgroundTint(.clear)
            } else {
                BoardMediumView(context: context)
                    .background(Color("WidgetBackgroundColor"))
                    .activityBackgroundTint(.clear)
                    .activitySystemActionForegroundColor(Color.black)
            }
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
                    Image(systemName: "pin.fill")
                        .rotationEffect(Angle.degrees(-45.0))
                        .foregroundColor(.red)
                    Text(context.state.indexString)
                        .font(Font.system(size: 9.0, weight: .bold))
                        .foregroundColor(.red)
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
        HStack {
            VStack {
                Button(intent: ButtonEmptyIntent()) {
                    Image(systemName: "pin.fill")
                        .rotationEffect(Angle.degrees(-45.0))
                }
                .tint(.red)
                .privacySensitive(false)
                
                Spacer(minLength: 4.0)
                
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
                    PinContentView(context: context)
                    Spacer()
                        .frame(height: 12.0)
                } else {
                    Spacer()
                        .frame(height: 16.0)
                    PinContentView(context: context)
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
