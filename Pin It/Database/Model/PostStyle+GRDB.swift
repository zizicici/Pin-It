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

        static let syncId = Column(CodingKeys.syncId)
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

extension PostStyle: TimestampedRecord {
    
}

extension PostDecoration {
    enum Columns: String, ColumnExpression {
        case id
        
        static let syncId = Column(CodingKeys.syncId)
        static let postId = Column(CodingKeys.postId)
        static let styleId = Column(CodingKeys.styleId)
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

extension PostDecoration: TimestampedRecord {
    
}

extension PostDecoration {
    static let postForeignKey = ForeignKey([Columns.postId])
    static let styleForeignKey = ForeignKey([Columns.styleId])

    static let style = belongsTo(PostStyle.self, using: styleForeignKey)
    
    var style: QueryInterfaceRequest<PostStyle> {
        request(for: PostDecoration.style)
    }
}
