//
//  PinInfoManager.swift
//  Pin It
//
//  Created by Ci Zi on 2025/10/25.
//

import Foundation
import UIKit
import ActivityKit

extension UserDefaults {
    enum PinInfo: String {
        case PageIndex = "com.zizicici.pin.pinInfo.pageIndex"
    }
}

struct PinInfoPageIndex {
    static let key: String = UserDefaults.PinInfo.PageIndex.rawValue
    
    static func getValue() -> Int {
        if let intValue = UserDefaults(suiteName: appGroupId)?.getInt(forKey: key) {
            return intValue
        } else {
            return 0
        }
    }
    
    static func setValue(_ value: Int) {
        UserDefaults(suiteName: appGroupId)?.set(value, forKey: key)
    }
}

class PinInfoManager: NSObject {
    static let shared = PinInfoManager()
    
    private var updateDebounce: Debounce<Int>!
    
    private(set) var current: Int = PinInfoPageIndex.getValue() {
        didSet {
            PinInfoPageIndex.setValue(current)
        }
    }
    private(set) var pinInfo: (posts: [SyncPost], styles: [PostStyle]) = ([], []) {
        didSet {
            if oldValue != pinInfo {
                updateCurrentIfNeeded()
                updateDebounce.emit(value: 0)
            }
        }
    }
    
    override init() {
        super.init()
        
        updateDebounce = Debounce(duration: 0.1, block: { [weak self] _ in
            await self?.commitUpdate()
        })
        
        updatePosts()
        
        NotificationCenter.default.addObserver(self, selector: #selector(updatePosts), name: .SyncDataUpdated, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updatePin), name: .SettingsUpdate, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(restartPin), name: .LifetimeMembership, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(showPinIfNeeded), name: UIApplication.didBecomeActiveNotification, object: nil)
    }
    
    private func commitUpdate() async {
        if pinInfo.posts.count > 0, AutoStartLiveActivity.current == .withContent {
            await LiveActivityManager.shared.start()
        }
    }
    
    @objc
    private func updatePosts() {
        self.pinInfo = (try? getPinInfo()) ?? ([], [])
    }
    
    public func resetCurrentIndex() async {
        updatePosts()
        await updateCurrent(newValue: 0)
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
                if pinInfo.posts.count > 0 {
                    updateDebounce.emit(value: 0)
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
            switch AutoStartLiveActivity.current {
            case .withContent:
                updateDebounce.emit(value: 0)
            case .appLaunch:
                await LiveActivityManager.shared.start()
            case .disable:
                break
            }
        }
    }
    
    private func getPinInfo() throws -> ([SyncPost], [PostStyle]) {
        guard let syncPostStorage = try SyncDataManager.read(SyncPostStorage.self) else { return ([], [])}
        
        let actionStorage = try SyncDataManager.read(SyncActionStorage.self)
        
        let unpinIds = actionStorage?.actions.filter{ $0.actionType == .unpin }.map{ $0.id } ?? []
        
        let posts: [SyncPost] = (syncPostStorage.posts).filter { post in
            return !unpinIds.contains(post.id) && !post.isExpired()
        }
        
        return (posts, syncPostStorage.styles)
    }
    
    public func getCurrentPost() throws -> SyncPost? {
        if (current >= 0) && (current < pinInfo.posts.count) {
            return pinInfo.posts[current]
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
            newIndex = pinInfo.posts.count - 1
        } else {
            newIndex = current - 1
        }
        await updateCurrent(newValue: newIndex)
    }
    
    public func nextAction() async {
        var newIndex: Int
        if current == pinInfo.posts.count - 1 {
            newIndex = 0
        } else {
            newIndex = current + 1
        }
        await updateCurrent(newValue: newIndex)
    }
    
    private func updateCurrent(newValue: Int) async {
        current = max(0, min(newValue, pinInfo.posts.count - 1))
        await LiveActivityManager.shared.update()
        for id in pinInfo.posts.map({ $0.id }) {
            await SyncCompletionManager.shared.notifyCompletion(for: id)
        }
    }
    
    public func getCurrentContentState() -> (content: PinAttributes.ContentState?, shouldEnd: Bool) {
        guard !((pinInfo.posts.count == 0) && (AutoEndLiveActivity.current == .noContent)) else {
            return (nil, true)
        }
        let target = try? getCurrentPost()
        
        return (PinAttributes.ContentState(id: target?.id, index: current, total: pinInfo.posts.count, isLeftToRight: Language.type() != .ar), false)
    }
}

actor SyncCompletionManager {
    static let shared = SyncCompletionManager()
    private var continuations: [Int64: [CheckedContinuation<Void, Never>]] = [:]
    private var timeoutTasks: [Int64: Task<Void, Never>] = [:]
    
    func waitForCompletion(postId: Int64, timeout: TimeInterval = 10.0) async {
        await withCheckedContinuation { continuation in
            // 存储 continuation
            if continuations[postId] == nil {
                continuations[postId] = []
            }
            continuations[postId]?.append(continuation)
            
            // 如果没有超时任务，创建一个
            if timeoutTasks[postId] == nil {
                timeoutTasks[postId] = Task {
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    self.handleTimeout(for: postId)
                }
            }
        }
    }
    
    private func handleTimeout(for postId: Int64) {
        // 超时后恢复所有等待这个 postId 的 continuation
        if let waitingContinuations = continuations[postId] {
            for continuation in waitingContinuations {
                continuation.resume()
            }
            continuations[postId] = nil
            timeoutTasks[postId] = nil
        }
    }
    
    func notifyCompletion(for postId: Int64) {
        // 取消超时任务
        if let task = timeoutTasks[postId] {
            task.cancel()
            timeoutTasks[postId] = nil
        }
        
        // 恢复所有等待的 continuation
        if let waitingContinuations = continuations[postId] {
            for continuation in waitingContinuations {
                continuation.resume()
            }
            continuations[postId] = nil
        }
    }
}
