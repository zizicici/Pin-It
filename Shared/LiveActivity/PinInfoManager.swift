//
//  PinInfoManager.swift
//  Pin It
//
//  Created by Ci Zi on 2025/10/25.
//

import Foundation
import UIKit

protocol PinInfoPrivider {
    var pinInfo: PinInfo { get }
}

struct PinInfo {
    var index: Int
    var total: Int
}

class PinInfoManager: NSObject {
    static let shared = PinInfoManager()
    
    override init() {
        super.init()
        
        NotificationCenter.default.addObserver(self, selector: #selector(updatePin), name: .SyncDataUpdated, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updatePin), name: .SettingsUpdate, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(restartPin), name: .LifetimeMembership, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(showPinIfNeeded), name: UIApplication.didBecomeActiveNotification, object: nil)
    }
    
    @objc
    private func restartPin() {
        Task {
            if LiveActivityManager.shared.status == .running {
                await LiveActivityManager.shared.end()
                await LiveActivityManager.shared.start()
            }
        }
    }
    
    @objc
    private func updatePin() {
        Task {
            switch AutoStartLiveActivity.current {
            case .withContent:
                if (try getPosts().count) > 0 {
                    await LiveActivityManager.shared.start()
                } else {
                    await LiveActivityManager.shared.update()
                }
            case .appLaunch, .disable:
                await LiveActivityManager.shared.update()
            }
        }
    }
    
    @objc
    private func showPinIfNeeded() {
        Task {
            if AutoStartLiveActivity.current == .appLaunch {
                await LiveActivityManager.shared.start()
            }
        }
    }
    
    public func getPosts() throws -> [SyncPost] {
        let syncPostStorage = try SyncDataManager.read(SyncPostStorage.self)
        
        let actionStorage = try SyncDataManager.read(SyncActionStorage.self)
        
        let unpinIds = actionStorage?.actions.filter{ $0.actionType == .unpin }.map{ $0.id } ?? []
        
        let posts: [SyncPost] = (syncPostStorage?.posts ?? []).filter { post in
            return !unpinIds.contains(post.id)
        }
        
        return posts
    }
    
    public func getPost(by pinInfo: PinInfo) throws -> SyncPost? {
        let posts = try getPosts()
        
        guard pinInfo.total == posts.count else {
            throw NSError(domain: "PinInfoError", code: -1, userInfo: [NSLocalizedDescriptionKey: "total not equal"])
        }
        
        if (pinInfo.index >= 0) && (pinInfo.index < posts.count) {
            return posts[pinInfo.index]
        } else {
            throw NSError(domain: "PinInfoError", code: -1, userInfo: [NSLocalizedDescriptionKey: "index outbound"])
        }
    }
    
    public func unpinCurrentPost() async {
        guard let pinInfo = LiveActivityManager.shared.getCurrentPosition() else { return }
        guard let post = try? getPost(by: pinInfo) else { return }
        
        var actionStorage = (try? SyncDataManager.read(SyncActionStorage.self)) ?? SyncActionStorage(actions: [])
        actionStorage.actions.append(SyncAction(id: post.id, actionType: .unpin))
        
        try? SyncDataManager.write(actionStorage)
    }
}
