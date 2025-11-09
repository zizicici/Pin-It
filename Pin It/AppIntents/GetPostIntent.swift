//
//  GetPostIntent.swift
//  Pin It
//
//  Created by Ci Zi on 2025/11/9.
//

import Foundation
import AppIntents

struct GetCurrentPinnedPostIntent: AppIntent {
    static var title: LocalizedStringResource = "intent.post.get.current.title"
    
    static var description: IntentDescription = IntentDescription("intent.post.get.current.description", categoryName: "intent.post.get.category")
    
    static var parameterSummary: some ParameterSummary {
        Summary("intent.post.get.current.summary")
    }
    
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<PostEntity?> {
        guard let post = await PinInfoManager.shared.getCurrentPost() else {
            return .result(value: nil)
        }
        
        let id = post.id
        
        let result = try await PostEntity.defaultQuery.entities(for: [Int(id)]).first
        
        return .result(value: result)
    }
}

struct GetAllPinnedPostIntent: AppIntent {
    static var title: LocalizedStringResource = "intent.post.get.all.title"
    
    static var description: IntentDescription = IntentDescription("intent.post.get.all.description", categoryName: "intent.post.get.category")
    
    static var parameterSummary: some ParameterSummary {
        Summary("intent.post.get.all.title")
    }
    
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[PostEntity]> {
        let postIds = try PinInfoManager.shared.getPosts().map { $0.id }
        
        let result = try await PostEntity.defaultQuery.entities(for: postIds.map { Int($0) })
        
        return .result(value: result)
    }
}
