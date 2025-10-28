//
//  AddPostIntent.swift
//  Pin It
//
//  Created by Ci Zi on 2025/10/25.
//

import AppIntents

struct AddTextRecordIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "intent.post.add.by.text.title"
    
    static var description: IntentDescription = IntentDescription("intent.post.add.by.text.description", categoryName: "intent.post.add.category")
    
    @Parameter(title: "intent.text")
    var content: String
    
    static var parameterSummary: some ParameterSummary {
        Summary("intent.post.add.by.text.summary\(\.$content)")
    }
    
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let result = DataManager.shared.createPost(content: content)
        return .result(value: result)
    }
}
