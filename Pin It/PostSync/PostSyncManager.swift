//
//  PostSyncManager.swift
//  Pin It
//
//  Created by Ci Zi on 2025/10/25.
//

import Foundation
import UIKit

class PostSyncManager: NSObject {
    static let shared = PostSyncManager()
    
    override init() {
        super.init()
        
        syncPostData()
        
        NotificationCenter.default.addObserver(self, selector: #selector(syncPostData), name: .DatabaseUpdated, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(syncPostData), name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(syncPostData), name: UIApplication.willResignActiveNotification, object: nil)
    }
    
    @objc
    private func syncPostData() {
        // App Group -> Database
        if let actionStorage = try? SyncDataManager.read(SyncActionStorage.self) {
            let unpinIds = actionStorage.actions.filter{ $0.actionType == .unpin }.map{ $0.id }
            _ = DataManager.shared.unpinPosts(by: unpinIds)
        }
        
        // Database -> App Group
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
