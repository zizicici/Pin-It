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
    
    private var updateDebounce: Debounce<Int>!
    
    override init() {
        super.init()
        
        updateDebounce = Debounce(duration: 0.1, block: { [weak self] _ in
            self?.commitUpdate()
        })
        
        syncData()
        
        NotificationCenter.default.addObserver(self, selector: #selector(needSyncDatabaseToAppGroup), name: .DatabaseUpdated, object: nil)
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
            let result = DataManager.shared.update(postIds: unpinIds, isPinned: false)
            if result {
                try? SyncDataManager.clearData(for: SyncActionStorage.self)
            }
        }
    }
    
    @objc
    private func needSyncDatabaseToAppGroup() {
        updateDebounce.emit(value: 0)
    }
    
    private func syncDatabaseToAppGroup() {
        // Database -> App Group
        let pinnedPosts = DataManager.shared.fetchAllPostDetails(isPinned: true).compactMap { $0.convertToSyncPost() }
        
        try? SyncDataManager.write(SyncPostStorage(posts: pinnedPosts))
    }
    
    private func commitUpdate() {
        syncDatabaseToAppGroup()
    }
}

extension Post.Detail {
    func convertToSyncPost() -> SyncPost? {
        guard let id = post.id else { return nil }
        return .init(id: id, text: texts.first?.content, image: images.first?.cropped)
    }
}
