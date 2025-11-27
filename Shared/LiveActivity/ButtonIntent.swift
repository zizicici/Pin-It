//
//  ButtonIntent.swift
//  Pin It
//
//  Created by Ci Zi on 2025/10/25.
//

import Foundation
import AppIntents

struct ResetAndUpdateIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "intent.action.reload.title"
    
    static var description: IntentDescription = IntentDescription("intent.action.reload.title", categoryName: "intent.action.category")
    
    static var parameterSummary: some ParameterSummary {
        Summary("intent.action.reload.summary")
    }
    
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        await PinInfoManager.shared.resetCurrentIndex()
        
        await LiveActivityManager.shared.update()

        return .result(value: true)
    }
    
    static var openAppWhenRun: Bool = false
}

struct ButtonPreviousIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "intent.action.previous.title"
    
    static var description: IntentDescription = IntentDescription("intent.action.previous.title", categoryName: "intent.action.category")
    
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        await PinInfoManager.shared.previousAction()

        return .result(value: true)
    }

    static var parameterSummary: some ParameterSummary {
        Summary("intent.action.previous.title")
    }
    
    static var openAppWhenRun: Bool = false
}

struct ButtonNextIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "intent.action.next.title"
    
    static var description: IntentDescription = IntentDescription("intent.action.next.title", categoryName: "intent.action.category")
    
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        await PinInfoManager.shared.nextAction()
        
        return .result(value: true)
    }

    static var parameterSummary: some ParameterSummary {
        Summary("intent.action.next.title")
    }
    
    static var openAppWhenRun: Bool = false
}

struct ButtonUnpinIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "intent.current.unpin.title"
    
    static var description: IntentDescription = IntentDescription("intent.current.unpin.title", categoryName: "intent.current.category")
    
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        PinInfoManager.shared.unpinCurrentPost()

        return .result(value: true)
    }

    static var parameterSummary: some ParameterSummary {
        Summary("intent.current.unpin.title")
    }
    
    static var openAppWhenRun: Bool = false
}
