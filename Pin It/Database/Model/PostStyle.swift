//
//  PostStyle.swift
//  Pin It
//
//  Created by Ci Zi on 2025/11/20.
//

import Foundation
import GRDB

enum PostImageDisplayMode: Int, Codable {
    case scaleFill = 0
    case aspectFit = 1
    case aspectFill = 2
}

enum PostTextAlignment: Int, Codable {
    case leading = 0
    case center = 1
    case trailing = 2
}

struct PostStyle: Identifiable, Hashable, Codable {
    var id: Int64?
     
    var name: String
    
    var lockBackgroundColor: String?
    var lockTextColor: String?
    var lockTextSize: Int?
    var lockTextAlignment: PostTextAlignment
    
    var islandTextColor: String?
    var islandTextSize: Int?
    var islandTextAlignment: PostTextAlignment
    
    var icon: String
    var iconColor: String?
    var iconAngle: Int
    
    var imageDisplayMode: PostImageDisplayMode
    
    var buttonAlpha: Int // 0 - 100
    
    enum Columns: String, ColumnExpression {
        case id
    }
    
    enum CodingKeys: String, CodingKey {
        case id, name, lockBackgroundColor = "lock_background_color", lockTextColor = "lock_text_color", lockTextSize = "lock_text_size", lockTextAlignment = "lock_text_alignment", islandTextColor = "island_text_color", islandTextSize = "island_text_size", islandTextAlignment = "island_text_alignment", icon, iconColor = "icon_color", iconAngle = "icon_anger", imageDisplayMode = "image_display_mode", buttonAlpha = "button_alpha"
    }
}

extension PostStyle: TableRecord {
    static var databaseTableName: String = "style"
}

extension PostStyle: FetchableRecord {
    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension PostStyle: MutablePersistableRecord {
    
}

struct PostDecoration: Identifiable, Hashable, Codable {
    var id: Int64?
    
    var styleId: Int64
    var postId: Int64
    
    enum Columns: String, ColumnExpression {
        case id
    }
    
    enum CodingKeys: String, CodingKey {
        case id, styleId = "style_id", postId = "post_id"
    }
}

extension PostDecoration: TableRecord {
    static var databaseTableName: String = "decoration"
}

extension PostDecoration: FetchableRecord {
    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension PostDecoration: MutablePersistableRecord {
    
}

extension PostDecoration {
    static let style = belongsTo(PostStyle.self)
    
    var style: QueryInterfaceRequest<PostStyle> {
        request(for: PostDecoration.style)
    }
}
