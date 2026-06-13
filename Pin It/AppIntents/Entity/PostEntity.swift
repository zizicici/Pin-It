//
//  PostEntity.swift
//  Pin It
//
//  Created by Ci Zi on 2025/11/9.
//

import Foundation
import AppIntents
import MoreKit

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
    
    @Property(title: "intent.post.isPinnedValue")
    var isPinned: Bool
    
    @Property(title: "intent.style.type")
    var style: StyleEntity?
    
    init(id: Int, date: Date, text: String? = nil, originalImage: IntentFile? = nil, isPinned: Bool, style: StyleEntity?) {
        self.id = id
        self.date = date
        self.text = text
        self.originalImage = originalImage
        self.isPinned = isPinned
        self.style = style
    }
}

struct PostIntentQuery: EntityQuery {
    func entities(for identifiers: [Int]) async throws -> [PostEntity] {
        let posts = DataManager.shared.fetchPostDetail(for: identifiers.map{ Int64($0) })
        
        let defaultStyleId = UserDefaults(suiteName: appGroupId)?.getInt(forKey: UserDefaults.Settings.DefaultStyle.rawValue)
        
        let result: [PostEntity] = posts.compactMap { detail in
            let text = detail.texts.first?.content
            let originalURL = detail.images.first?.originalURL
            
            var styleEntity: StyleEntity? = nil
            if let style = detail.style {
                styleEntity = StyleEntity(style: style, defaultId: defaultStyleId)
            } else {
                styleEntity = nil
            }
            
            return .init(id: Int(detail.post.id!), date: Date(millisecondsSince1970: detail.post.creationTime!), text: text, originalImage: (originalURL != nil) ? IntentFile(fileURL: originalURL!) : nil, isPinned: detail.post.isPinned, style: styleEntity)
        }
        
        return result
    }
    
    func suggestedEntities() async throws -> [PostEntity] {
        let posts = DataManager.shared.fetchAllPostDetails(isPinned: true)
        
        let defaultStyleId = UserDefaults(suiteName: appGroupId)?.getInt(forKey: UserDefaults.Settings.DefaultStyle.rawValue)
        
        let result: [PostEntity] = posts.compactMap { detail in
            let text = detail.texts.first?.content
            let originalURL = detail.images.first?.originalURL
            
            var styleEntity: StyleEntity? = nil
            if let style = detail.style {
                styleEntity = StyleEntity(style: style, defaultId: defaultStyleId)
            } else {
                styleEntity = nil
            }
            
            return .init(id: Int(detail.post.id!), date: Date(millisecondsSince1970: detail.post.creationTime!), text: text, originalImage: (originalURL != nil) ? IntentFile(fileURL: originalURL!) : nil, isPinned: detail.post.isPinned, style: styleEntity)
        }
        
        return result
    }
}
