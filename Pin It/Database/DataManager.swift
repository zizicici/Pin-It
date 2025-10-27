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
    
    private func createPost(original: String, cropped: String, rect: CGRect, orientation: Int) -> Bool {
        return false
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
    
    public func delete(post: Post) -> Bool {
        return AppDatabase.shared.delete(post: post)
    }
    
    public func update(posts: [Post]) -> Bool {
        return AppDatabase.shared.update(posts: posts)
    }
}
