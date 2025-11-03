//
//  PostImage.swift
//  Pin It
//
//  Created by Ci Zi on 2025/10/17.
//

import Foundation
import GRDB

struct PostImage: Identifiable, Hashable, Codable {
    var id: Int64?
    
    var postId: Int64
    var original: String
    var processed: String
    var orientation: Int64
    var minX: Int64
    var minY: Int64
    var maxX: Int64
    var maxY: Int64
    
    var order: Int64
    
    enum Columns: String, ColumnExpression {
        case order
    }
    
    enum CodingKeys: String, CodingKey {
        case id, postId = "post_id", original, processed, orientation, minX = "min_x", minY = "min_y", maxX = "max_x", maxY = "max_y", order
    }
}

extension PostImage: TableRecord {
    static var databaseTableName: String = "image"
}

extension PostImage: FetchableRecord {
    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension PostImage: MutablePersistableRecord {
    
}
