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
    
    public func fetchAllPosts() -> [Post] {
        var result: [Post] = []
        do {
            try AppDatabase.shared.reader?.read{ db in
                result = try Post
                    .fetchAll(db)
            }
        }
        catch {
            print(error)
        }
        
        return result
    }
    
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
    
    public func fetchAllPostDetails(by ids: [Int64]) -> [Post.Detail] {
        var result: [Post.Detail] = []
        do {
            try AppDatabase.shared.reader?.read{ db in
                let idColumn = Post.Columns.id
                result = try Post
                    .including(all: Post.images)
                    .including(all: Post.texts)
                    .asRequest(of: Post.Detail.self)
                    .filter(ids.contains(idColumn))
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
    
    func fetchPostDetail(for ids: [Int64]) -> [Post.Detail] {
        var result: [Post.Detail] = []
        do {
            try AppDatabase.shared.reader?.read{ db in
                let idColumn = Post.Columns.id
                result = try Post
                    .including(all: Post.images)
                    .including(all: Post.texts)
                    .asRequest(of: Post.Detail.self)
                    .filter(ids.contains(idColumn))
                    .fetchAll(db)
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
    
    public func updateImage(original: String, processed: String, rect: CGRect, orientation: Int, to post: Post) -> Bool {
        guard let postId = post.id, let detail = fetchPostDetail(for: postId) else {
            return false
        }
        let deleteImage = AppDatabase.shared.delete(images: detail.images)
        if deleteImage {
            for image in detail.images {
                _ = ImageCacheManager.shared.deleteImage(fileName: image.original, type: .original)
                _ = ImageCacheManager.shared.deleteImage(fileName: image.processed, type: .processed)
            }
        }
        _ = AppDatabase.shared.delete(texts: detail.texts)
        
        let newPostImage = PostImage(postId: postId, original: original, processed: processed, orientation: Int64(orientation), minX: Int64(rect.minX), minY: Int64(rect.minY), maxX: Int64(rect.maxX), maxY: Int64(rect.maxY), order: 0)
        let result = AppDatabase.shared.add(image: newPostImage)
        
        return result
    }
    
    public func updateText(content: String, to post: Post) -> Bool {
        guard let postId = post.id, let detail = fetchPostDetail(for: postId) else {
            return false
        }
        let deleteImage = AppDatabase.shared.delete(images: detail.images)
        if deleteImage {
            for image in detail.images {
                _ = ImageCacheManager.shared.deleteImage(fileName: image.original, type: .original)
                _ = ImageCacheManager.shared.deleteImage(fileName: image.processed, type: .processed)
            }
        }
        _ = AppDatabase.shared.delete(texts: detail.texts)
        
        let newPostText = PostText(postId: postId, content: content, order: 0)
        let result = AppDatabase.shared.add(text: newPostText)
        
        return result
    }
    
    public func createPost(content: String, isPinned: Bool = true, expirationTime: Int64? = nil) -> Post? {
        // Fetch Last Post
        switch MaxPinnedPosts.current {
        case .unlimited:
            break
        case .one:
            if isPinned {
                _ = unpinAllPinnedPosts()
            }
        }
        let newOrder = getNewOrder(isPinned: true)
        let newPost = Post(expirationTime: expirationTime, isPinned: isPinned, order: newOrder)
        guard let savedPost = AppDatabase.shared.add(post: newPost), let id = savedPost.id else {
            return nil
        }
        let newPostText = PostText(postId: id, content: content, order: 0)
        if !AppDatabase.shared.add(text: newPostText) {
            _ = AppDatabase.shared.delete(post: newPost)
            return nil
        } else {
            return savedPost
        }
    }
    
    public func createPost(original: String, processed: String, rect: CGRect, orientation: Int, isPinned: Bool = true) -> Post? {
        switch MaxPinnedPosts.current {
        case .unlimited:
            break
        case .one:
            if isPinned {
                _ = unpinAllPinnedPosts()
            }
        }
        let newOrder = getNewOrder(isPinned: isPinned)
        let newPost = Post(isPinned: true, order: newOrder)
        guard let savedPost = AppDatabase.shared.add(post: newPost), let id = savedPost.id else {
            return nil
        }
        let newPostImage = PostImage(postId: id, original: original, processed: processed, orientation: Int64(orientation), minX: Int64(rect.minX), minY: Int64(rect.minY), maxX: Int64(rect.maxX), maxY: Int64(rect.maxY), order: 0)
        if !AppDatabase.shared.add(image: newPostImage) {
            _ = AppDatabase.shared.delete(post: newPost)
            return nil
        } else {
            return savedPost
        }
    }
    
    public func update(post: Post, isPinned: Bool) -> Bool {
        switch MaxPinnedPosts.current {
        case .unlimited:
            return updatePost(post, isPinned: isPinned, order: getNewOrder(isPinned: isPinned))
        case .one:
            if isPinned {
                _ = unpinAllPinnedPosts()
            }
            let order: Int64 = isPinned ? 0 : getNewOrder(isPinned: isPinned)
            return updatePost(post, isPinned: isPinned, order: order)
        }
    }
    
    private func unpinAllPinnedPosts() -> Bool {
        let pinnedPostIds = fetchAllPostDetails(isPinned: true).compactMap { $0.post.id }
        return update(postIds: pinnedPostIds, isPinned: false)
    }
    
    private func updatePost(_ post: Post, isPinned: Bool, order: Int64) -> Bool {
        var newPost = post
        newPost.isPinned = isPinned
        newPost.order = order
        return AppDatabase.shared.update(post: newPost)
    }
    
    public func update(postIds: [Int64], isPinned: Bool) -> Bool {
        let newOrder = getNewOrder(isPinned: isPinned)
        return AppDatabase.shared.update(postIds: postIds, isPinned: isPinned, newOrder: newOrder)
    }
    
    public func update(post: Post) -> Bool {
        return AppDatabase.shared.update(post: post)
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
                _ = ImageCacheManager.shared.deleteImage(fileName: image.processed, type: .processed)
            }
        }
        
        return result
    }
    
    public func update(posts: [Post]) -> Bool {
        return AppDatabase.shared.update(posts: posts)
    }
    
    public func deleteAllUnpins() -> Bool {
        let details = fetchAllPostDetails(isPinned: false)
        let ids = details.compactMap { detail in
            return detail.post.id
        }
        let images = details.compactMap{ $0.images }.flatMap{ $0 }
        
        let result = AppDatabase.shared.deletePosts(by: ids)
        
        if result {
            for image in images {
                _ = ImageCacheManager.shared.deleteImage(fileName: image.original, type: .original)
                _ = ImageCacheManager.shared.deleteImage(fileName: image.processed, type: .processed)
            }
        }
        
        return result
    }
    
    public func deletePosts(by ids: [Int64]) -> Bool {
        let details = fetchAllPostDetails(by: ids)
        let images = details.compactMap{ $0.images }.flatMap{ $0 }
        
        let result = AppDatabase.shared.deletePosts(by: ids)
        
        if result {
            for image in images {
                _ = ImageCacheManager.shared.deleteImage(fileName: image.original, type: .original)
                _ = ImageCacheManager.shared.deleteImage(fileName: image.processed, type: .processed)
            }
        }
        
        return result
    }
}

extension DataManager {
    public func reset() {
        let reset = AppDatabase.shared.reset()
        if reset {
            ImageCacheManager.shared.clearAllCache()
            OnboardingManager.shared.setupOnboardingDataIfNeeded()
        }
    }
    
    public func clearExpiredPosts() {
        let expiredIds = fetchAllPosts().filter({ $0.isExpired() }).compactMap({ $0.id })
        switch ExpirationAction.current {
        case .unpin:
            _ = update(postIds: expiredIds, isPinned: false)
        case .delete:
            _ = deletePosts(by: expiredIds)
        }
    }
}
