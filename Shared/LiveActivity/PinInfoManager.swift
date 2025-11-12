//
//  PinInfoManager.swift
//  Pin It
//
//  Created by Ci Zi on 2025/10/25.
//

import Foundation
import UIKit
import ActivityKit

class PinInfoManager: NSObject {
    static let shared = PinInfoManager()
    
    private(set) var current: Int = 0
    private(set) var posts: [SyncPost] = [] {
        didSet {
            if oldValue != posts {
                updateCurrentIfNeeded()
            }
            if posts.count > 0, AutoStartLiveActivity.current == .withContent {
                Task {
                    await LiveActivityManager.shared.start()
                }
            }
        }
    }
    
    override init() {
        super.init()
        
        NotificationCenter.default.addObserver(self, selector: #selector(updatePosts), name: .SyncDataUpdated, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updatePin), name: .SettingsUpdate, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(restartPin), name: .LifetimeMembership, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(showPinIfNeeded), name: UIApplication.didBecomeActiveNotification, object: nil)
    }
    
    @objc
    private func updatePosts() {
        posts = (try? getPosts()) ?? []
    }
    
    private func updateCurrentIfNeeded() {
        Task {
            await updateCurrent(newValue: current)
        }
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
                if posts.count > 0 {
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
    
    private func getPosts() throws -> [SyncPost] {
        let syncPostStorage = try SyncDataManager.read(SyncPostStorage.self)
        
        let actionStorage = try SyncDataManager.read(SyncActionStorage.self)
        
        let unpinIds = actionStorage?.actions.filter{ $0.actionType == .unpin }.map{ $0.id } ?? []
        
        let posts: [SyncPost] = (syncPostStorage?.posts ?? []).filter { post in
            return !unpinIds.contains(post.id)
        }
        
        return posts
    }
    
    public func getCurrentPost() throws -> SyncPost? {
        if (current >= 0) && (current < posts.count) {
            return posts[current]
        } else {
            return nil
        }
    }
    
    public func unpinCurrentPost() {
        guard let currentPost = try? getCurrentPost() else { return }
        
        var actionStorage = (try? SyncDataManager.read(SyncActionStorage.self)) ?? SyncActionStorage(actions: [])
        actionStorage.actions.append(SyncAction(id: currentPost.id, actionType: .unpin))
        
        try? SyncDataManager.write(actionStorage)
    }
    
    public func previousAction() async {
        var newIndex: Int
        if current == 0 {
            newIndex = posts.count - 1
        } else {
            newIndex = current - 1
        }
        await updateCurrent(newValue: newIndex)
    }
    
    public func nextAction() async {
        var newIndex: Int
        if current == posts.count - 1 {
            newIndex = 0
        } else {
            newIndex = current + 1
        }
        await updateCurrent(newValue: newIndex)
    }
    
    private func updateCurrent(newValue: Int) async {
        current = max(0, min(newValue, posts.count - 1))
        await LiveActivityManager.shared.update()
    }
    
    public func getCurrentContentState() -> (content: PinAttributes.ContentState?, shouldEnd: Bool) {
        guard !((posts.count == 0) && (AutoEndLiveActivity.current == .noContent)) else {
            return (nil, true)
        }
        let target = try? getCurrentPost()
        
        return (PinAttributes.ContentState(index: current, total: posts.count, text: target?.text, imageName: target?.image), false)
    }
}
