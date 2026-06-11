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
    
    var styles: [PostStyle] = []
    
    init() {
        updateStyles()
        
        NotificationCenter.default.addObserver(self, selector: #selector(updateStyles), name: .DatabaseUpdated, object: nil)
    }
    
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
                    .including(optional: Post.decoration
                        .including(optional: PostDecoration.style))
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
                    .including(optional: Post.decoration
                        .including(optional: PostDecoration.style))
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
    
    func fetchPostDetail(for ids: [Int64]) -> [Post.Detail] {
        var result: [Post.Detail] = []
        do {
            try AppDatabase.shared.reader?.read{ db in
                let idColumn = Post.Columns.id
                result = try Post
                    .including(all: Post.images)
                    .including(all: Post.texts)
                    .including(optional: Post.decoration
                        .including(optional: PostDecoration.style))
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
                    .including(optional: Post.decoration
                        .including(optional: PostDecoration.style))
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
    
    public func updateImage(original: String, processed: String, rect: CGRect, orientation: Int, to post: Post) -> Bool {
        guard let postId = post.id,
              let deletedImages = AppDatabase.shared.replacePostBodyWithImage(
                postId: postId,
                original: original,
                processed: processed,
                rect: rect,
                orientation: orientation
              ) else {
            _ = ImageCacheManager.shared.deleteImage(fileName: original, type: .original)
            _ = ImageCacheManager.shared.deleteImage(fileName: processed, type: .processed)
            return false
        }
        for image in deletedImages {
            _ = ImageCacheManager.shared.deleteImage(fileName: image.original, type: .original)
            _ = ImageCacheManager.shared.deleteImage(fileName: image.processed, type: .processed)
        }
        return true
    }
    
    public func updateText(content: String, to post: Post) -> Bool {
        guard let postId = post.id,
              let deletedImages = AppDatabase.shared.replacePostBodyWithText(postId: postId, content: content) else {
            return false
        }
        for image in deletedImages {
            _ = ImageCacheManager.shared.deleteImage(fileName: image.original, type: .original)
            _ = ImageCacheManager.shared.deleteImage(fileName: image.processed, type: .processed)
        }
        return true
    }
    
    public func createPost(content: String, actionLink: String, isPinned: Bool = true, expirationTime: Int64?, styleId: Int64?) -> Post? {
        AppDatabase.shared.createTextPost(
            content: content,
            actionLink: actionLink,
            isPinned: isPinned,
            expirationTime: expirationTime,
            styleId: styleId,
            enforcesSinglePinnedPost: MaxPinnedPosts.current == .one
        )
    }
    
    public func createPost(original: String, processed: String, rect: CGRect, orientation: Int, actionLink: String, isPinned: Bool = true, expirationTime: Int64?, styleId: Int64?) -> Post? {
        let post = AppDatabase.shared.createImagePost(
            original: original,
            processed: processed,
            rect: rect,
            orientation: orientation,
            actionLink: actionLink,
            isPinned: isPinned,
            expirationTime: expirationTime,
            styleId: styleId,
            enforcesSinglePinnedPost: MaxPinnedPosts.current == .one
        )
        if post == nil {
            _ = ImageCacheManager.shared.deleteImage(fileName: original, type: .original)
            _ = ImageCacheManager.shared.deleteImage(fileName: processed, type: .processed)
        }
        return post
    }
    
    public func update(post: Post, isPinned: Bool) -> Bool {
        guard let postId = post.id else { return false }
        return AppDatabase.shared.updatePostPinnedState(
            postId: postId,
            isPinned: isPinned,
            enforcesSinglePinnedPost: MaxPinnedPosts.current == .one
        )
    }
    
    public func update(postIds: [Int64], isPinned: Bool, promotesLocalOnboarding: Bool = true) -> Bool {
        return AppDatabase.shared.update(
            postIds: postIds,
            isPinned: isPinned,
            promotesLocalOnboarding: promotesLocalOnboarding
        )
    }
    
    public func updatePost(id: Int64, mutate: (inout Post) -> Void) -> Bool {
        return AppDatabase.shared.updatePost(id: id, mutate: mutate)
    }

    public func updateText(id: Int64, mutate: (inout PostText) -> Void) -> Bool {
        return AppDatabase.shared.updateText(id: id, mutate: mutate)
    }

    public func updateImage(id: Int64, mutate: (inout PostImage) -> Void) -> Bool {
        return AppDatabase.shared.updateImage(id: id, mutate: mutate)
    }

    public func updateImageReturningReplacedProcessed(
        id: Int64,
        mutate: (inout PostImage) -> Void
    ) -> (success: Bool, replacedProcessed: String?) {
        return AppDatabase.shared.updateImageReturningReplacedProcessed(id: id, mutate: mutate)
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
    
    public func updatePostPlacements(_ placements: [(postId: Int64, isPinned: Bool, order: Int64)]) -> Bool {
        return AppDatabase.shared.updatePostPlacements(placements)
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
    
    public func update(post: Post, expirationTime: Int64?) -> Bool {
        guard let postId = post.id else { return false }
        return updatePost(id: postId) { $0.expirationTime = expirationTime }
    }
}

extension DataManager {
    @objc
    func updateStyles() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.updateStyles()
            }
            return
        }
        styles = fetchAllStyles()
    }
    
    func fetchAllStyles() -> [PostStyle] {
        var result: [PostStyle] = []
        do {
            try AppDatabase.shared.reader?.read{ db in
                let idColumn = PostStyle.Columns.id
                result = try PostStyle
                    .order(idColumn.asc)
                    .fetchAll(db)
            }
        }
        catch {
            print(error)
        }
        
        return result
    }
    
    func fetchStyle(by id: Int64) -> PostStyle? {
        var result: PostStyle? = nil
        do {
            try AppDatabase.shared.reader?.read{ db in
                let idColumn = PostStyle.Columns.id
                result = try PostStyle
                    .filter(idColumn == id)
                    .fetchOne(db)
            }
        }
        catch {
            print(error)
        }
        
        return result
    }
    
    func fetchStyle(bySyncId syncId: String) -> PostStyle? {
        var result: PostStyle? = nil
        do {
            try AppDatabase.shared.reader?.read{ db in
                result = try PostStyle
                    .filter(PostStyle.Columns.syncId == syncId)
                    .fetchOne(db)
            }
        }
        catch {
            print(error)
        }

        return result
    }

    func fetchStyles(by ids: [Int64]) -> [PostStyle] {
        var result: [PostStyle] = []
        do {
            try AppDatabase.shared.reader?.read{ db in
                result = try PostStyle
                    .filter(ids: ids)
                    .fetchAll(db)
            }
        }
        catch {
            print(error)
        }
        
        return result
    }
    
    func add(style: PostStyle) -> PostStyle? {
        return AppDatabase.shared.add(style: style)
    }
    
    func updateStyle(id: Int64, mutate: (inout PostStyle) -> Void) -> Bool {
        return AppDatabase.shared.updateStyle(id: id, mutate: mutate)
    }
    
    func delete(style: PostStyle) -> Bool {
        return AppDatabase.shared.delete(style: style)
    }
    
    func fetchDecoration(by postId: Int64) -> PostDecoration? {
        var result: PostDecoration? = nil
        do {
            try AppDatabase.shared.reader?.read{ db in
                let postIdColumn = PostDecoration.Columns.postId
                result = try PostDecoration
                    .filter(postIdColumn == postId)
                    .fetchOne(db)
            }
        }
        catch {
            print(error)
        }
        
        return result
    }
    
    func add(decoration: PostDecoration) -> Bool {
        return AppDatabase.shared.add(decoration: decoration)
    }
    
    func updateDecoration(id: Int64, mutate: (inout PostDecoration) -> Void) -> Bool {
        return AppDatabase.shared.updateDecoration(id: id, mutate: mutate)
    }
    
    func delete(decoration: PostDecoration) -> Bool {
        return AppDatabase.shared.delete(decoration: decoration)
    }
    
    func update(post: Post, styleId: Int64?) -> Bool {
        guard let postId = post.id else { return false }
        if let styleId = styleId {
            guard fetchStyle(by: styleId) != nil else { return false }
            if let decorationId = fetchDecoration(by: postId)?.id {
                return updateDecoration(id: decorationId) { $0.styleId = styleId }
            } else {
                let decoration = PostDecoration(styleId: styleId, postId: postId)
                return add(decoration: decoration)
            }
        } else {
            if let decoration = fetchDecoration(by: postId) {
                return delete(decoration: decoration)
            } else {
                return true
            }
        }
    }
}

extension DataManager {
    public func cleanupUnreferencedImageCache() {
        var originalNames = Set<String>()
        var processedNames = Set<String>()
        do {
            guard let reader = AppDatabase.shared.reader else { return }
            try reader.read { db in
                for image in try PostImage.fetchAll(db) {
                    originalNames.insert(image.original)
                    processedNames.insert(image.processed)
                }
            }
            _ = ImageCacheManager.shared.deleteUnreferencedImages(
                originalNames: originalNames,
                processedNames: processedNames
            )
        } catch {
            print(error)
        }
    }

    public func reset() {
        let shouldRebuildCloudKit = CloudKitSync.current == .enable
        let reset = AppDatabase.shared.reset()
        if reset {
            ImageCacheManager.shared.clearAllCache()
            OnboardingManager.shared.setupOnboardingDataIfNeeded()
            if shouldRebuildCloudKit {
                CloudKitRecordSyncManager.shared.rebuildCloudKitDataAfterLocalReset()
            }
        }
    }
    
    public func clearExpiredPosts() {
        switch ExpirationAction.current {
        case .unpin:
            // Only still-pinned expired posts need the pass. Rewriting the
            // already-unpinned ones on every activation would bump their
            // modification_time each time and re-upload them to CloudKit.
            let expiredIds = fetchAllPosts().filter({ $0.isExpired() && $0.isPinned }).compactMap({ $0.id })
            guard !expiredIds.isEmpty else { return }
            _ = update(postIds: expiredIds, isPinned: false, promotesLocalOnboarding: false)
        case .delete:
            let expiredIds = fetchAllPosts().filter({ $0.isExpired() }).compactMap({ $0.id })
            guard !expiredIds.isEmpty else { return }
            _ = deletePosts(by: expiredIds)
        }
    }
}
