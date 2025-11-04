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

struct PinContentWatchView: View {
    var context: ActivityViewContext<PinAttributes>
    
    var body: some View {
        if let text = context.state.text {
            AutoSizeText(text: text)
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
                HStack {
                    Spacer().frame(width: 3.0)
                    Image(systemName: "pin.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                        .rotationEffect(Angle.degrees(-45.0))
                }
            } compactTrailing: {
                //
            } minimal: {
                Spacer().frame(width: 20.0)
                Image(systemName: "pin.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.red)
                    .rotationEffect(Angle.degrees(-45.0))
                Spacer().frame(width: 20.0)
            }
            .widgetURL(URL(string: Self.url))
            .keylineTint(Color.red)
        }
        .supplementalActivityFamilies([.small])
    }
}

struct AutoSizeText: View {
    let text: String
    
    var body: some View {
        ViewThatFits(in: .vertical) {
            // 尝试不同的字体大小，系统会自动选择最适合的
            ForEach([36, 32, 28, 24, 20, 18, 16, 14, 12, 10, 8], id: \.self) { fontSize in
                VStack {
                    Spacer(minLength: 0.0)
                    // 使用高亮处理后的文本
                    Text(highlightedText(from: text, fontSize: fontSize))
                        .font(.system(size: CGFloat(fontSize)).monospacedDigit())
                        .multilineTextAlignment(.center)
                    Spacer(minLength: 0.0)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }
    
    private func highlightedText(from input: String, fontSize: Int) -> AttributedString {
        var attributedString = AttributedString(input)
        
//        // 使用 NSDataDetector 来识别日期和时间
//        let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
//        let matches = detector.matches(in: input, options: [], range: NSRange(location: 0, length: input.utf16.count))
//        
//        // 存储已识别的时间范围
//        var dateRanges: [Range<String.Index>] = []
//        
//        // 高亮日期和时间
//        for match in matches {
//            if let range = Range(match.range, in: input) {
//                let dateText = String(input[range])
//                if let attributedRange = attributedString.range(of: dateText) {
//                    attributedString[attributedRange].foregroundColor = .blue
//                    attributedString[attributedRange].font = .system(size: CGFloat(fontSize), weight: .bold, design: .monospaced)
//                }
//                dateRanges.append(range)
//            }
//        }
//        
//        // 使用正则表达式高亮数字，不需要前后空格
//        let numberRegex = try! NSRegularExpression(pattern: "\\d+", options: [])
//        let numberMatches = numberRegex.matches(in: input, options: [], range: NSRange(location: 0, length: input.utf16.count))
//        
//        for match in numberMatches {
//            if let range = Range(match.range, in: input) {
//                // 检查数字是否在已识别的时间范围内
//                let isInDateRange = dateRanges.contains(where: { $0.overlaps(range) })
//                
//                // 只有当数字不在时间范围内时，才进行高亮显示
//                if !isInDateRange {
//                    let numberText = String(input[range])
//                    if let attributedRange = attributedString.range(of: numberText) {
//                        attributedString[attributedRange].foregroundColor = .green // 可以选择不同颜色
//                        attributedString[attributedRange].font = .system(size: CGFloat(fontSize), weight: .bold, design: .monospaced)
//                    }
//                }
//            }
//        }
        
        return attributedString
    }
}

struct BoardContent: View {
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
                PinContentWatchView(context: context)
            }
            Spacer(minLength: 3.0)
            Button(intent: ButtonNextIntent()) {
                Image(systemName: "pin.fill")
                    .rotationEffect(Angle.degrees(-45.0))
                    .foregroundColor(.red)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
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
                
                Spacer(minLength: 4.0)
                
                Button(intent: ButtonUnpinIntent()) {
                    Image(systemName: "pin.slash")
                }
                .buttonStyle(.borderless)
                .tint(.secondary)
                
                Spacer().frame(height: 4.0)
            }
            .padding(12.0)
            VStack {
                if User.shared.proTier() == .lifetime {
                    Spacer()
                        .frame(height: 24.0)
                    PinContentView(context: context)
                    Spacer()
                        .frame(height: 24.0)
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
            }
            .padding(12.0)
        }
    }
}
