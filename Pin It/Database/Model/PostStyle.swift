//
//  PostStyle.swift
//  Pin It
//
//  Created by Ci Zi on 2025/11/20.
//

import Foundation
import GRDB

enum PostImageDisplayMode: Int, Codable, CaseIterable {
    case scaleFill = 0
    case aspectFit = 1
    case aspectFill = 2
}

enum PostTextAlignment: Int, Codable, CaseIterable {
    case leading = 0
    case center = 1
    case trailing = 2
}

enum PostTextSize: Int, Codable, CaseIterable {
    case automatic = -1
    case largeTitle = 34
    case title1 = 28
    case title2 = 22
    case title3 = 20
    case body = 17
    case callout = 16
    case subhead = 15
    case footnote = 13
    case caption1 = 12
    case caption2 = 11
}

struct PostStyle: Identifiable, Hashable, Codable {
    var id: Int64?
     
    var name: String
    
    var lockBackgroundColor: String?
    var lockTextColor: String?
    var lockTextSize: PostTextSize
    var lockTextAlignment: PostTextAlignment
    
    var islandTextColor: String?
    var islandTextSize: PostTextSize
    var islandTextAlignment: PostTextAlignment
    
    var symbol: String
    var symbolColor: String?
    var symbolAngle: Int
    
    var imageDisplayMode: PostImageDisplayMode
    
    var controlAlpha: Int // 0 - 100
    
    enum Columns: String, ColumnExpression {
        case id
    }
    
    enum CodingKeys: String, CodingKey {
        case id, name, lockBackgroundColor = "lock_background_color", lockTextColor = "lock_text_color", lockTextSize = "lock_text_size", lockTextAlignment = "lock_text_alignment", islandTextColor = "island_text_color", islandTextSize = "island_text_size", islandTextAlignment = "island_text_alignment", symbol, symbolColor = "symbol_color", symbolAngle = "symbol_angle", imageDisplayMode = "image_display_mode", controlAlpha = "control_alpha"
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

extension PostStyle {
    static let placeholder: Self = PostStyle(name: String(localized: "style.placeholder"), lockTextSize: .automatic, lockTextAlignment: .center, islandTextSize: .automatic, islandTextAlignment: .center, symbol: "pin.fill", symbolAngle: -4500, imageDisplayMode: .aspectFit, controlAlpha: 100)
}

struct PostDecoration: Identifiable, Hashable, Codable {
    var id: Int64?
    
    var styleId: Int64
    var postId: Int64
    
    enum Columns: String, ColumnExpression {
        case id
        
        static let postId = Column(CodingKeys.postId)
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
