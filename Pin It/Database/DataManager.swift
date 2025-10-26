//
//  DataManager.swift
//  Pin It
//
//  Created by Salley Garden on 2025/10/17.
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
                if isPinned {
                    let orderColumn = Post.Columns.order
                    result = try Post
                        .including(all: Post.images)
                        .including(all: Post.texts)
                        .asRequest(of: Post.Detail.self)
                        .filter(isPinnedColumn == isPinned)
                        .order(orderColumn.desc)
                        .fetchAll(db)
                } else {
                    let modificationTimeColumn = Post.Columns.modificationTime
                    result = try Post
                        .including(all: Post.images)
                        .including(all: Post.texts)
                        .asRequest(of: Post.Detail.self)
                        .filter(isPinnedColumn == isPinned)
                        .order(modificationTimeColumn.desc)
                        .fetchAll(db)
                }
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
    
    public func createPost(content: String) -> Bool {
        // Fetch Last Post
        let newOrder = (fetchLastPost(isPinned: true)?.order ?? -1) + 1
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
        var newPost = post
        newPost.isPinned = isPinned
        return AppDatabase.shared.update(post: newPost, updateTimestamp: false)
    }
    
    public func unpinPosts(by ids: [Int64]) -> Bool {
        return AppDatabase.shared.unpinPosts(by: ids)
    }
    
    public func update(text: PostText) -> Bool {
        return AppDatabase.shared.update(text: text)
    }
    
    public func delete(post: Post) -> Bool {
        return AppDatabase.shared.delete(post: post)
    }
}
