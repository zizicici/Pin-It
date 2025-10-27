//
//  ActionWidget.swift
//  Board
//
//  Created by Ci Zi on 2025/10/27.
//

import WidgetKit
import SwiftUI
import Intents
import AppIntents

struct StartButtonWidget: Widget {
    let kind: String = "StartButtonWidget"
    
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: StartButtonProvider()) { entry in
            StartButtonWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("widget.start.name")
        .description("widget.start.description")
        .supportedFamilies([.systemSmall, .accessoryCircular])
    }
}

struct StartButtonProvider: TimelineProvider {
    typealias Entry = StartButtonEntry
    
    func placeholder(in context: Context) -> StartButtonEntry {
        StartButtonEntry(date: Date())
    }
    
    func getSnapshot(in context: Context, completion: @escaping (StartButtonEntry) -> Void) {
        let entry = StartButtonEntry(date: Date())
        completion(entry)
    }
    
    func getTimeline(in context: Context, completion: @escaping (Timeline<StartButtonEntry>) -> Void) {
        let entry = StartButtonEntry(date: Date())
        let timeline = Timeline(entries: [entry], policy: .never)
        completion(timeline)
    }
}

struct StartButtonEntry: TimelineEntry {
    let date: Date
}

struct StartButtonWidgetEntryView: View {
    @Environment(\.widgetFamily) var widgetFamily
    
    var entry: StartButtonProvider.Entry
    
    var body: some View {
        if widgetFamily == .accessoryCircular {
            ZStack {
                AccessoryWidgetBackground()
                Button(intent: StartIntent()) {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 23))
                        .foregroundColor(.primary)
                        .rotationEffect(Angle.degrees(-45.0))
                }
                .buttonStyle(PlainButtonStyle())
            }
            .containerBackground(.clear, for: .widget)
            .widgetAccentable()
        } else {
            ZStack {
                Button(intent: StartIntent()) {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 80))
                        .foregroundColor(.red)
                        .padding(4)
                        .rotationEffect(Angle.degrees(-45.0))
                }
                .buttonStyle(PlainButtonStyle())
                .offset(x: 32, y: 32)
            }
            .containerBackground(.fill.secondary, for: .widget)
        }
    }
}
