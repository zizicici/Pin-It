//
//  PostImage.swift
//  Pin It
//
//  Created by Ci Zi on 2025/10/17.
//

import Foundation
import GRDB
import UIKit

struct PostImage: Identifiable, Hashable, Codable {
    var id: Int64?
    var syncId: String = UUID().uuidString

    var creationTime: Int64?
    var modificationTime: Int64?
    
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

        static let postId = Column(CodingKeys.postId)
        static let syncId = Column(CodingKeys.syncId)
    }
    
    enum CodingKeys: String, CodingKey {
        case id, syncId = "sync_id", creationTime = "creation_time", modificationTime = "modification_time", postId = "post_id", original, processed, orientation, minX = "min_x", minY = "min_y", maxX = "max_x", maxY = "max_y", order
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

extension PostImage: TimestampedRecord {
    
}

extension PostImage {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int64.self, forKey: .id)
        syncId = try container.decodeIfPresent(String.self, forKey: .syncId) ?? UUID().uuidString
        creationTime = try container.decodeIfPresent(Int64.self, forKey: .creationTime)
        modificationTime = try container.decodeIfPresent(Int64.self, forKey: .modificationTime)
        postId = try container.decode(Int64.self, forKey: .postId)
        original = try container.decode(String.self, forKey: .original)
        processed = try container.decode(String.self, forKey: .processed)
        orientation = try container.decodeIfPresent(Int64.self, forKey: .orientation) ?? 0
        minX = try container.decodeIfPresent(Int64.self, forKey: .minX) ?? 0
        minY = try container.decodeIfPresent(Int64.self, forKey: .minY) ?? 0
        maxX = try container.decodeIfPresent(Int64.self, forKey: .maxX) ?? 0
        maxY = try container.decodeIfPresent(Int64.self, forKey: .maxY) ?? 0
        order = try container.decodeIfPresent(Int64.self, forKey: .order) ?? 0
    }
}

extension PostImage {
    static let postForeignKey = ForeignKey([Columns.postId])
}

extension PostImage {
    var rect: CGRect {
        return CGRect.init(
            origin: CGPoint(
                x: Int(minX),
                y: Int(minY)
            ),
            size: CGSize(
                width: Int(maxX - minX),
                height: Int(maxY - minY)
            )
        )
    }
}

extension PostImage {
    var originalURL: URL? {
        if let path = ImageCacheManager.shared.getPath(name: original, type: .original) {
            return URL(filePath: path)
        } else {
            return nil
        }
    }
    
    var processedURL: URL? {
        if let path = ImageCacheManager.shared.getPath(name: processed, type: .processed) {
            return URL(filePath: path)
        } else {
            return nil
        }
    }
}

extension PostImage {
    func getOriginalImage() -> UIImage? {
        if let url = originalURL, let data = try? Data(contentsOf: url) {
            return UIImage(data: data)
        } else {
            return nil
        }
    }
    
    func getProcessedImage() -> UIImage? {
        if let url = processedURL, let data = try? Data(contentsOf: url) {
            return UIImage(data: data)
        } else {
            return nil
        }
    }
}
