//
//  DeletePostIntent.swift
//  Pin It
//
//  Created by Ci Zi on 2025/11/11.
//

import AppIntents
import UIKit

struct DeletePostIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "intent.post.delete.single.title"
    
    static var description: IntentDescription = IntentDescription("intent.post.delete.single.title", categoryName: "intent.post.delete.category")
    
    static var parameterSummary: some ParameterSummary {
        Summary("intent.post.delete.single.summary\(\.$post)")
    }
    
    @Parameter(title: "intent.post.type")
    var post: PostEntity
    
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        guard let detail = DataManager.shared.fetchPostDetail(for: [Int64(post.id)]).first else {
            return .result(value: false)
        }
        
        let result = DataManager.shared.delete(post: detail.post)
        
        return .result(value: result)
    }
}

struct DeleteAllUnpinsIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "intent.post.delete.allUnpins.title"
    
    static var description: IntentDescription = IntentDescription("intent.post.delete.allUnpins.title", categoryName: "intent.post.delete.category")
    
    static var parameterSummary: some ParameterSummary {
        Summary("intent.post.delete.allUnpins.title")
    }
    
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let result = DataManager.shared.deleteAllUnpins()
        
        return .result(value: result)
    }
}
