//
//  PostStyle+GRDB.swift
//  Pin It
//
//  Created by Ci Zi on 2025/11/26.
//

import Foundation
import GRDB

extension PostStyle {
    enum Columns: String, ColumnExpression {
        case id
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

extension PostDecoration {
    enum Columns: String, ColumnExpression {
        case id
        
        static let postId = Column(CodingKeys.postId)
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
