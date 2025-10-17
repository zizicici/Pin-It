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
    
    private func fetchAllPostDetails() -> [Post.Detail] {
        var result: [Post.Detail] = []
        do {
            try AppDatabase.shared.reader?.read{ db in
                let orderColumn = Post.Columns.order
                result = try Post
                    .including(required: Post.images)
                    .including(required: Post.texts)
                    .asRequest(of: Post.Detail.self)
                    .order(orderColumn.desc)
                    .fetchAll(db)
            }
        }
        catch {
            print(error)
        }
        
        return result
    }
    
    private func fetchLastPost() -> Post? {
        var result: Post?
        do {
            try AppDatabase.shared.reader?.read { db in
                let orderColumn = Post.Columns.order
                result = try Post.order(orderColumn.desc).fetchOne(db)
            }
        }
        catch {
            print(error)
        }
        
        return result
    }
    
    private func createPost(content: String) -> Bool {
        // Fetch Last Post
        let newOrder = (fetchLastPost()?.order ?? -1) + 1
        let newPost = Post(title: "", order: newOrder)
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
}
