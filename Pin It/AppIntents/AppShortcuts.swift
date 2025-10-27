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
                "Show \(.applicationName)",
                "Display \(.applicationName)",
                "Present \(.applicationName)"
            ],
            shortTitle: "shortcuts.title.start",
            systemImageName: "play"
        )
        AppShortcut(
            intent: EndIntent(),
            phrases: [
                "Dismiss \(.applicationName)",
                "Hide \(.applicationName)"
            ],
            shortTitle: "shortcuts.title.stop",
            systemImageName: "stop"
        )
        AppShortcut(
            intent: AddTextRecordIntent(),
            phrases: [
                "New \(.applicationName)",
                "New \(.applicationName) Post",
                "Create \(.applicationName)"
            ],
            shortTitle: "shortcuts.title.add",
            systemImageName: "pin")
    }
}
