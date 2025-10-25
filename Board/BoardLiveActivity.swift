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

var qianzi = "天地玄黃宇宙洪荒日月盈昃辰宿列張寒來暑往秋收冬藏閏餘成歲律召調陽雲騰致雨露結爲霜金生麗水玉出崑岡劍號巨闕珠稱夜光果珍李柰菜重芥薑海鹹河淡鱗潛羽翔龍師火帝鳥官人皇始制文字乃服衣裳推位讓國有虞陶唐弔民伐罪周發殷湯坐朝問道垂拱平章愛育黎首臣伏戎羌遐邇壹體率賓歸王鳴鳳在樹白駒食場化被草木賴及萬方蓋此身髮四大五常"

struct BoardLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PinAttributes.self) { context in
            let text = getText(index: context.state.index, total: context.state.total)
            // Lock screen/banner UI goes here
            HStack {
                VStack {
                    Button(intent: ButtonEmptyIntent()) {
                        Image(systemName: "pin.fill")
                    }
                    .tint(.red)
                    
                    Spacer(minLength: 4.0)
                    
                    Button(intent: ButtonEmptyIntent()) {
                        Image(systemName: "pin.slash")
                    }
                    .buttonStyle(.borderless)
                    .tint(.secondary)
                    
                    Spacer().frame(height: 4.0)
                }
                .padding(12.0)
                VStack {
                    Spacer()
                    AutoSizeText(text: text)
    //                Image("testimage").resizable().scaledToFit()
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                VStack {
                    Button(intent: ButtonEmptyIntent()) {
                        Image(systemName: "chevron.up")
                            .frame(minHeight: 21.0)
                    }
                    .tint(.primary)
                    
                    Spacer(minLength: 18.0)
                        .frame(maxHeight: .infinity)
                    
                    Text("1/20")
                        .font(Font.footnote)
                        .foregroundStyle(.secondary)
                    
                    Spacer(minLength: 18.0)
                        .frame(maxHeight: .infinity)
                    
                    Button(intent: ButtonEmptyIntent()) {
                        Image(systemName: "chevron.down")
                            .frame(minHeight: 21.0)
                    }
                    .tint(.primary)
                }
                .padding(12.0)
            }
            .activityBackgroundTint(.clear)
            .activitySystemActionForegroundColor(Color.black)
        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded UI goes here.  Compose the expanded UI through
                // various regions, like leading/trailing/center/bottom
                DynamicIslandExpandedRegion(.leading) {
                    VStack {
                        Button(intent: ButtonEmptyIntent()) {
                            Image(systemName: "pin.fill")
                        }
                        .tint(.red)
                        
                        Spacer(minLength: 4.0)
                        
                        Button(intent: ButtonEmptyIntent()) {
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
                        Button(intent: ButtonEmptyIntent()) {
                            Image(systemName: "chevron.up")
                                .frame(minHeight: 21.0)
                        }
                        .tint(.primary)
                        
                        Spacer(minLength: 18.0)
                        
                        Text("1/20")
                            .font(Font.footnote)
                            .foregroundStyle(.secondary)
                        
                        Spacer(minLength: 18.0)
                        
                        Button(intent: ButtonEmptyIntent()) {
                            Image(systemName: "chevron.down")
                                .frame(minHeight: 21.0)
                        }
                        .tint(.primary)
                    }
                    .frame(maxHeight: .infinity)
//                    .background(.white)
                }
                DynamicIslandExpandedRegion(.center) {
                    let text = getText(index: context.state.index, total: context.state.total)
                    VStack {
//                            Image("testimage").resizable().scaledToFit()
                        
                        AutoSizeText(text: text)
                        Spacer(minLength: 12.0)
//                        AutoSizeText(text: qianzi)
                    }
//                        .clipShape(RoundedRectangle(cornerRadius: 10.0))
//                    .background(.orange)
                }
                
//                DynamicIslandExpandedRegion(.bottom) {
//                    HStack {
//                        VStack {
//                            Button(intent: ButtonIntent()) {
//                                Image(systemName: "pin.fill")
//                            }
//                            .tint(.red)
//                        }
//                        Spacer()
//                        HStack {
//                            Button(intent: ButtonIntent()) {
//                                Image(systemName: "chevron.left")
//                            }
//                            .tint(.secondary)
//                            Button(intent: ButtonIntent()) {
//                                Image(systemName: "chevron.right")
//                            }
//                            .tint(.secondary)
//                        }
//                    }
//                }
            } compactLeading: {
                HStack {
                    Spacer().frame(width: 3.0)
                    Image(systemName: "pin")
                        .foregroundColor(.red)
                }
            } compactTrailing: {
                //
            } minimal: {
                Image(systemName: "pin")
                    .foregroundColor(.red)
            }
            .widgetURL(URL(string: "http://www.apple.com"))
            .keylineTint(Color.red)
        }
    }
    
    func getText(index: Int, total: Int) -> String {
        do {
            let result = try SyncDataManager.read(SyncPostStorage.self)
            return "\(result)"
        }
        catch {
            return "error\(error)"
        }
        return ""
//        let result = (try? PinInfoManager.shared.getPost(by: PinInfo(index: index, total: total))?.text) ?? "lalala"
//        return result
    }
}

struct AutoSizeText: View {
    let text: String
    
    var body: some View {
        ViewThatFits(in: .vertical) {
            // 尝试不同的字体大小，系统会自动选择最适合的
            ForEach([36, 28, 20, 16, 12, 10, 8], id: \.self) { fontSize in
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

//struct AutoSizeText: View {
//    let text: String
//    
//    var body: some View {
//        ViewThatFits(in: .vertical) {
//            // 尝试不同的字体大小，系统会自动选择最适合的
//            VStack {
//                Spacer(minLength: 0.0)
//                Text(text)
//                    .font(.system(size: 36).monospacedDigit())
//                    .multilineTextAlignment(.center)
//                Spacer(minLength: 0.0)
//            }
//            
//            VStack {
//                Spacer(minLength: 0.0)
//                Text(text)
//                    .font(.system(size: 28).monospacedDigit())
//                    .multilineTextAlignment(.center)
//                Spacer(minLength: 0.0)
//            }
//            
//            VStack {
//                Spacer(minLength: 0.0)
//                Text(text)
//                    .font(.system(size: 20).monospacedDigit())
//                    .multilineTextAlignment(.center)
//                Spacer(minLength: 0.0)
//            }
//            
//            VStack {
//                Spacer(minLength: 0.0)
//                Text(text)
//                    .font(.system(size: 16).monospacedDigit())
//                    .multilineTextAlignment(.center)
//                Spacer(minLength: 0.0)
//            }
//            
//            VStack {
//                Spacer(minLength: 0.0)
//                Text(text)
//                    .font(.system(size: 12).monospacedDigit())
//                    .multilineTextAlignment(.center)
//                Spacer(minLength: 0.0)
//            }
//            
//            VStack {
//                Spacer(minLength: 0.0)
//                Text(text)
//                    .font(.system(size: 10).monospacedDigit())
//                    .multilineTextAlignment(.center)
//                Spacer(minLength: 0.0)
//            }
//            
//            VStack {
//                Spacer(minLength: 0.0)
//                Text(text)
//                    .font(.system(size: 8).monospacedDigit())
//                    .multilineTextAlignment(.center)
//                Spacer(minLength: 0.0)
//            }
//        }
//        .frame(maxHeight: .infinity)
//    }
//}
