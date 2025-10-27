//
//  ButtonIntent.swift
//  Pin It
//
//  Created by Ci Zi on 2025/10/25.
//

import Foundation
import AppIntents

struct ButtonEmptyIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "intent.empty.title"
    
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let posts = try? PinInfoManager.shared.getPosts()
        print(posts)
        print("ButtonIntent perform()")
        
        return .result(value: true)
    }

    static var parameterSummary: some ParameterSummary {
        Summary("")
    }
    
    static var openAppWhenRun: Bool = false
    
    static var isDiscoverable: Bool = false
}

struct ButtonPreviousIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "intent.previous.title"
    
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        await LiveActivityManager.shared.previousAction()

        return .result(value: true)
    }

    static var parameterSummary: some ParameterSummary {
        Summary("")
    }
    
    static var openAppWhenRun: Bool = false
    
    static var isDiscoverable: Bool = false
}

struct ButtonNextIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "intent.next.title"
    
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        await LiveActivityManager.shared.nextAction()
        
        return .result(value: true)
    }

    static var parameterSummary: some ParameterSummary {
        Summary("")
    }
    
    static var openAppWhenRun: Bool = false
    
    static var isDiscoverable: Bool = false
}

struct ButtonUnpinIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "intent.unpin.title"
    
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        await PinInfoManager.shared.unpinCurrentPost()

        return .result(value: true)
    }

    static var parameterSummary: some ParameterSummary {
        Summary("")
    }
    
    static var openAppWhenRun: Bool = false
    
    static var isDiscoverable: Bool = false
}
