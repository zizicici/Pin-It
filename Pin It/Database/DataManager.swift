//
//  DataManager.swift
//  Pin It
//
//  Created by Ci Zi on 2025/10/17.
//

import Foundation
import GRDB

final class DataManager {
    static let shared = DataManager()
    
    public func fetchAllPostDetails(isPinned: Bool) -> [Post.Detail] {
        var result: [Post.Detail] = []
        do {
            try AppDatabase.shared.reader?.read{ db in
                let isPinnedColumn = Post.Columns.isPinned
                let orderColumn = Post.Columns.order
                result = try Post
                    .including(all: Post.images)
                    .including(all: Post.texts)
                    .asRequest(of: Post.Detail.self)
                    .filter(isPinnedColumn == isPinned)
                    .order(orderColumn.desc)
                    .fetchAll(db)
            }
        }
        catch {
            print(error)
        }
        
        return result
    }
    
    public func fetchLastPost(isPinned: Bool) -> Post? {
        var result: Post?
        do {
            try AppDatabase.shared.reader?.read { db in
                let orderColumn = Post.Columns.order
                let isPinnedColumn = Post.Columns.isPinned
                result = try Post.order(orderColumn.desc).filter(isPinnedColumn == isPinned).fetchOne(db)
            }
        }
        catch {
            print(error)
        }
        
        return result
    }
    
    private func fetchPostDetail(for id: Int64) -> Post.Detail? {
        var result: Post.Detail?
        do {
            try AppDatabase.shared.reader?.read{ db in
                let idColumn = Post.Columns.id
                result = try Post
                    .including(all: Post.images)
                    .including(all: Post.texts)
                    .asRequest(of: Post.Detail.self)
                    .filter(idColumn == id)
                    .fetchOne(db)
            }
        }
        catch {
            print(error)
        }
        
        return result
    }
    
    private func getNewOrder(isPinned: Bool) -> Int64 {
        return (fetchLastPost(isPinned: isPinned)?.order ?? -1) + 1
    }
    
    public func createPost(content: String) -> Bool {
        // Fetch Last Post
        let newOrder = getNewOrder(isPinned: true)
        let newPost = Post(isPinned: true, order: newOrder)
        guard let savedPost = AppDatabase.shared.add(post: newPost), let id = savedPost.id else {
            return false
        }
        let newPostText = PostText(postId: id, content: content, order: 0)
        if !AppDatabase.shared.add(text: newPostText) {
            _ = AppDatabase.shared.delete(post: newPost)
            return false
        } else {
            return true
        }
    }
    
    public func createPost(original: String, processed: String, rect: CGRect, orientation: Int) -> Bool {
        let newOrder = getNewOrder(isPinned: true)
        let newPost = Post(isPinned: true, order: newOrder)
        guard let savedPost = AppDatabase.shared.add(post: newPost), let id = savedPost.id else {
            return false
        }
        let newPostImage = PostImage(postId: id, original: original, cropped: processed, orientation: Int64(orientation), minX: Int64(rect.minX), minY: Int64(rect.minY), maxX: Int64(rect.maxX), maxY: Int64(rect.maxY), order: 0)
        if !AppDatabase.shared.add(image: newPostImage) {
            _ = AppDatabase.shared.delete(post: newPost)
            return false
        } else {
            return true
        }
    }
    
    public func update(post: Post, isPinned: Bool) -> Bool {
        let newOrder = getNewOrder(isPinned: isPinned)
        var newPost = post
        newPost.isPinned = isPinned
        newPost.order = newOrder
        return AppDatabase.shared.update(post: newPost)
    }
    
    public func update(postIds: [Int64], isPinned: Bool) -> Bool {
        let newOrder = getNewOrder(isPinned: isPinned)
        return AppDatabase.shared.update(postIds: postIds, isPinned: isPinned, newOrder: newOrder)
    }
    
    public func update(text: PostText) -> Bool {
        return AppDatabase.shared.update(text: text)
    }
    
    public func update(image: PostImage) -> Bool {
        return AppDatabase.shared.update(image: image)
    }
    
    public func delete(post: Post) -> Bool {
        guard let id = post.id, let detail = fetchPostDetail(for: id) else { return false }
        
        let result = AppDatabase.shared.delete(post: post)
        
        if result {
            for image in detail.images {
                _ = ImageCacheManager.shared.deleteImage(fileName: image.original, type: .original)
                _ = ImageCacheManager.shared.deleteImage(fileName: image.cropped, type: .processed)
            }
        }
        
        return result
    }
    
    public func update(posts: [Post]) -> Bool {
        return AppDatabase.shared.update(posts: posts)
    }
}
