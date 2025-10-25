//
//  PostSyncManager.swift
//  Pin It
//
//  Created by Ci Zi on 2025/10/25.
//

import Foundation

class PostSyncManager: NSObject {
    static let shared = PostSyncManager()
    
    override init() {
        super.init()
        
        NotificationCenter.default.addObserver(self, selector: #selector(syncPostData), name: .DatabaseUpdated, object: nil)
    }
    
    @objc
    private func syncPostData() {
        let pinnedPosts = DataManager.shared.fetchAllPostDetails(isPinned: true).compactMap { $0.convertToSyncPost() }
        
        try? SyncDataManager.write(SyncPostStorage(posts: pinnedPosts))
    }
}

extension Post.Detail {
    func convertToSyncPost() -> SyncPost? {
        guard let id = post.id else { return nil }
        return .init(id: id, text: texts.first?.content, image: images.first?.cropped)
    }
}
