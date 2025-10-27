//
//  AppShortcuts.swift
//  Pin It
//
//  Created by Ci Zi on 2025/10/27.
//

import AppIntents

struct AppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartIntent(),
            phrases: [
                "Start \(.applicationName)"
            ],
            shortTitle: "shortcuts.title.start",
            systemImageName: "play"
        )
        AppShortcut(
            intent: EndIntent(),
            phrases: [
                "End \(.applicationName)"
            ],
            shortTitle: "shortcuts.title.stop",
            systemImageName: "stop"
        )
    }
}
