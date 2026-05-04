//
//  PostStyle.swift
//  Pin It
//
//  Created by Ci Zi on 2025/11/20.
//

import Foundation

enum PostImageDisplayMode: Int, Codable, CaseIterable {
    case aspectFit = 0
    case aspectFill = 1
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
    var syncId: String = UUID().uuidString

    var creationTime: Int64?
    var modificationTime: Int64?

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
    
    enum CodingKeys: String, CodingKey {
        case id, syncId = "sync_id", creationTime = "creation_time", modificationTime = "modification_time", name, lockBackgroundColor = "lock_background_color", lockTextColor = "lock_text_color", lockTextSize = "lock_text_size", lockTextAlignment = "lock_text_alignment", islandTextColor = "island_text_color", islandTextSize = "island_text_size", islandTextAlignment = "island_text_alignment", symbol, symbolColor = "symbol_color", symbolAngle = "symbol_angle", imageDisplayMode = "image_display_mode", controlAlpha = "control_alpha"
    }
}

extension PostStyle {
    static func makePlaceholder() -> Self {
        PostStyle(name: String(localized: "style.placeholder"), lockTextSize: .automatic, lockTextAlignment: .center, islandTextSize: .automatic, islandTextAlignment: .center, symbol: "pin.fill", symbolAngle: -4500, imageDisplayMode: .aspectFit, controlAlpha: 100)
    }
}

struct PostDecoration: Identifiable, Hashable, Codable {
    var id: Int64?
    var syncId: String = UUID().uuidString

    var creationTime: Int64?
    var modificationTime: Int64?
    
    var styleId: Int64
    var postId: Int64
    
    enum CodingKeys: String, CodingKey {
        case id, syncId = "sync_id", creationTime = "creation_time", modificationTime = "modification_time", styleId = "style_id", postId = "post_id"
    }
}

extension PostDecoration {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int64.self, forKey: .id)
        syncId = try container.decodeIfPresent(String.self, forKey: .syncId) ?? UUID().uuidString
        creationTime = try container.decodeIfPresent(Int64.self, forKey: .creationTime)
        modificationTime = try container.decodeIfPresent(Int64.self, forKey: .modificationTime)
        styleId = try container.decode(Int64.self, forKey: .styleId)
        postId = try container.decode(Int64.self, forKey: .postId)
    }
}

extension PostStyle {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int64.self, forKey: .id)
        syncId = try container.decodeIfPresent(String.self, forKey: .syncId) ?? UUID().uuidString
        creationTime = try container.decodeIfPresent(Int64.self, forKey: .creationTime)
        modificationTime = try container.decodeIfPresent(Int64.self, forKey: .modificationTime)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? String(localized: "style.placeholder")
        lockBackgroundColor = try container.decodeIfPresent(String.self, forKey: .lockBackgroundColor)
        lockTextColor = try container.decodeIfPresent(String.self, forKey: .lockTextColor)
        lockTextSize = try container.decodeIfPresent(PostTextSize.self, forKey: .lockTextSize) ?? .automatic
        lockTextAlignment = try container.decodeIfPresent(PostTextAlignment.self, forKey: .lockTextAlignment) ?? .center
        islandTextColor = try container.decodeIfPresent(String.self, forKey: .islandTextColor)
        islandTextSize = try container.decodeIfPresent(PostTextSize.self, forKey: .islandTextSize) ?? .automatic
        islandTextAlignment = try container.decodeIfPresent(PostTextAlignment.self, forKey: .islandTextAlignment) ?? .center
        symbol = try container.decodeIfPresent(String.self, forKey: .symbol) ?? "pin.fill"
        symbolColor = try container.decodeIfPresent(String.self, forKey: .symbolColor)
        symbolAngle = try container.decodeIfPresent(Int.self, forKey: .symbolAngle) ?? -4500
        imageDisplayMode = try container.decodeIfPresent(PostImageDisplayMode.self, forKey: .imageDisplayMode) ?? .aspectFit
        controlAlpha = try container.decodeIfPresent(Int.self, forKey: .controlAlpha) ?? 100
    }
}
