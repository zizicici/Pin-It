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
        
        syncData()
        
        NotificationCenter.default.addObserver(self, selector: #selector(syncDatabaseToAppGroup), name: .DatabaseUpdated, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(syncData), name: UIApplication.didBecomeActiveNotification, object: nil)
    }
    
    @objc
    private func syncData() {
        syncAppGroupToDatabase()
        syncDatabaseToAppGroup()
    }
    
    @objc
    private func syncAppGroupToDatabase() {
        // App Group -> Database
        if let actionStorage = try? SyncDataManager.read(SyncActionStorage.self) {
            let unpinIds = actionStorage.actions.filter{ $0.actionType == .unpin }.map{ $0.id }
            let result = DataManager.shared.unpinPosts(by: unpinIds)
            if result {
                try? SyncDataManager.clearData(for: SyncActionStorage.self)
            }
        }
    }
    
    @objc
    private func syncDatabaseToAppGroup() {
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
