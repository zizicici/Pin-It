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
