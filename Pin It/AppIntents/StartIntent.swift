//
//  StartIntent.swift
//  Pin It
//
//  Created by Ci Zi on 2025/10/27.
//

import AppIntents

struct StartIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "intent.action.start.title"
    
    static var description: IntentDescription = IntentDescription("intent.action.start.description", categoryName: "intent.action.category")
    
    static var parameterSummary: some ParameterSummary {
        Summary("intent.action.start.summary")
    }
    
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let result = await LiveActivityManager.shared.start()
        return .result(value: result)
    }
}

struct EndIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "intent.action.end.title"
    
    static var description: IntentDescription = IntentDescription("intent.action.end.description", categoryName: "intent.action.category")
    
    static var parameterSummary: some ParameterSummary {
        Summary("intent.action.end.summary")
    }
    
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        await LiveActivityManager.shared.end()
        return .result(value: true)
    }
}
