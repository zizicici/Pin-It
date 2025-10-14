//
//  BoardLiveActivity.swift
//  Board
//
//  Created by Ci Zi on 2025/10/13.
//

import ActivityKit
import WidgetKit
import SwiftUI

struct BoardAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        // Dynamic stateful properties about your activity go here!
        var emoji: String
    }

    // Fixed non-changing properties about your activity go here!
    var name: String
}

struct BoardLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BoardAttributes.self) { context in
            // Lock screen/banner UI goes here
            VStack {
                Text("Hello \(context.state.emoji)")
            }
            .activityBackgroundTint(Color.cyan)
            .activitySystemActionForegroundColor(Color.black)

        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded UI goes here.  Compose the expanded UI through
                // various regions, like leading/trailing/center/bottom
                DynamicIslandExpandedRegion(.leading) {
                    Text("Leading")
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("Trailing")
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("Bottom \(context.state.emoji)")
                    // more content
                }
            } compactLeading: {
                Text("L")
            } compactTrailing: {
                Text("T \(context.state.emoji)")
            } minimal: {
                Text(context.state.emoji)
            }
            .widgetURL(URL(string: "http://www.apple.com"))
            .keylineTint(Color.red)
        }
    }
}

extension BoardAttributes {
    fileprivate static var preview: BoardAttributes {
        BoardAttributes(name: "World")
    }
}

extension BoardAttributes.ContentState {
    fileprivate static var smiley: BoardAttributes.ContentState {
        BoardAttributes.ContentState(emoji: "😀")
     }
     
     fileprivate static var starEyes: BoardAttributes.ContentState {
         BoardAttributes.ContentState(emoji: "🤩")
     }
}

#Preview("Notification", as: .content, using: BoardAttributes.preview) {
   BoardLiveActivity()
} contentStates: {
    BoardAttributes.ContentState.smiley
    BoardAttributes.ContentState.starEyes
}
