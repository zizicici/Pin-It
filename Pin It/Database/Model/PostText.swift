//
//  PostText.swift
//  Pin It
//
//  Created by Ci Zi on 2025/10/17.
//

import Foundation
import GRDB

struct PostText: Identifiable, Hashable, Codable {
    var id: Int64?
    
    var postId: Int64
    var content: String
    
    var order: Int64
    
    enum Columns: String, ColumnExpression {
        case order
    }
    
    enum CodingKeys: String, CodingKey {
        case id, postId = "post_id", content, order
    }
}

extension PostText: TableRecord {
    static var databaseTableName: String = "text"
}

extension PostText: FetchableRecord {
    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension PostText: MutablePersistableRecord {
    
}
