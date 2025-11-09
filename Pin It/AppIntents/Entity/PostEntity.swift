//
//  PostEntity.swift
//  Pin It
//
//  Created by Ci Zi on 2025/11/9.
//

import Foundation
import AppIntents

struct PostEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "intent.post.type")
    typealias DefaultQuery = PostIntentQuery
    static var defaultQuery = PostIntentQuery()
    var displayRepresentation: DisplayRepresentation {
        if text != nil {
            return DisplayRepresentation(title: "\(text ?? "")", subtitle: "\(date.formatted())")
        } else if let fileURL = originalImage?.fileURL {
            return DisplayRepresentation(title: "intent.post.image", subtitle: "\(date.formatted())", image: DisplayRepresentation.Image.init(url: fileURL, isTemplate: false, displayStyle: .default))
        } else {
            return DisplayRepresentation(title: "intent.post.empty")
        }
    }
    
    var id: Int
    
    var date: Date
    
    @Property(title: "intent.post.textValue")
    var text: String?
    
    @Property(title: "intent.post.originalImageValue")
    var originalImage: IntentFile?
    
    init(id: Int, date: Date, text: String? = nil, originalImage: IntentFile? = nil) {
        self.id = id
        self.date = date
        self.text = text
        self.originalImage = originalImage
    }
}

struct PostIntentQuery: EntityQuery {
    func entities(for identifiers: [Int]) async throws -> [PostEntity] {
        let posts = DataManager.shared.fetchPostDetail(for: identifiers.map{ Int64($0) })
        
        let result: [PostEntity] = posts.compactMap { detail in
            let text = detail.texts.first?.content
            let originalURL = detail.images.first?.originalURL
            
            return .init(id: Int(detail.post.id!), date: Date(nanoSecondSince1970: detail.post.creationTime!), text: text, originalImage: (originalURL != nil) ? IntentFile(fileURL: originalURL!) : nil)
        }
        
        return result
    }
    
    func suggestedEntities() async throws -> [PostEntity] {
        return []
    }
}
