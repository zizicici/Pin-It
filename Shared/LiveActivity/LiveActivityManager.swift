//
//  LiveActivityManager.swift
//  Pin It
//
//  Created by Ci Zi on 2025/10/14.
//

import Foundation
import ActivityKit

extension Notification.Name {
    static let LiveActivityStatusChanged = Notification.Name(rawValue: "com.zizicici.pin.liveActivity.statusChanged")
}

class LiveActivityManager: NSObject {
    enum Status {
        case initial
        case running
        case idle
        
        var title: String {
            switch self {
            case .initial:
                return String(localized: "liveActivity.status.initial")
            case .running:
                return String(localized: "liveActivity.status.running")
            case .idle:
                return String(localized: "liveActivity.status.idle")
            }
        }
    }
    
    static let shared = LiveActivityManager()
    
    private var currentCount: Int = 0 {
        didSet {
            if currentCount >= 1 {
                status = .running
            } else {
                status = .idle
            }
        }
    }
    
    public private(set) var status: Status = .initial {
        didSet {
            if oldValue != status {
                postNotification()
            }
        }
    }
    
    private var startDate: Date?
    
    func postNotification() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: NSNotification.Name.LiveActivityStatusChanged, object: nil)
        }
    }
    
    var areActivitiesEnabled: Bool {
        return ActivityAuthorizationInfo().areActivitiesEnabled
    }
    
    override init() {
        super.init()
        
        updateStatus()
    }
    
    @discardableResult
    func start(fastMode: Bool = false) async -> Bool {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return false }
        switch Activity<PinAttributes>.activities.count {
        case 0:
            // Create
            var result: Bool

            if fastMode {
                let activityContent = ActivityContent(state: PinAttributes.ContentState.placeholder, staleDate: nil)
                let activityAttributes = PinAttributes(name: "Pin")
                do {
                    let activity = try Activity.request(attributes: activityAttributes, content: activityContent)
                    startDate = Date()
                    print(activity)
                    result = true
                }
                catch {
                    print(error.localizedDescription)
                    result = false
                }
            } else {
                let posts = (try? PinInfoManager.shared.getPosts()) ?? []
                
                guard !((posts.count == 0) && (AutoEndLiveActivity.current == .noContent)) else {
                    await end()
                    result = false
                    return result
                }
                
                let total: Int = posts.count
                let index: Int = 0
                let target = try? PinInfoManager.shared.getPost(by: PinInfo(index: index, total: total))
                let activityContent = ActivityContent(state: PinAttributes.ContentState(index: index, total: total, text: target?.text, imageName: target?.image), staleDate: nil)
                let activityAttributes = PinAttributes(name: "Pin")
                
                do {
                    let activity = try Activity.request(attributes: activityAttributes, content: activityContent)
                    startDate = Date()
                    print(activity)
                    result = true
                }
                catch {
                    print(error.localizedDescription)
                    result = false
                }
            }
            
            updateStatus()
            return result
        case 1:
            // Update
            await update()
            return true
        default:
            return false
        }
    }
    
    func restartIfNeeded() async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard let currentActivity = Activity<PinAttributes>.activities.first else { return }
        
        switch currentActivity.activityState {
        case .active, .dismissed:
            if let startDate = startDate {
                if startDate.timeIntervalSinceNow < -3600 {
                    await start()
                }
            }
        case .stale, .ended:
            await start()
        case .pending:
            break
        @unknown default:
            fatalError()
        }
    }
    
    func end() async {
        for activity in Activity<PinAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
            print("Ending the Live Activity: \(activity.id)")
        }
        updateStatus()
    }
    
    func update() async {
        await restartIfNeeded()
        if let position = getCurrentPosition() {
            await update(index: position.index)
        }
        updateStatus()
    }
    
    @objc
    private func updateStatus() {
        Task {
            await restartIfNeeded()
            currentCount = Activity<PinAttributes>.activities.count
        }
        print("Activity Count: \(currentCount)")
    }
    
    public func getCurrentPosition() -> PinInfo? {
        if let state = Activity<PinAttributes>.activities.first?.content.state {
            return PinInfo(index: state.index, total: state.total)
        } else {
            return nil
        }
    }
    
    public func previousAction() async {
        if let position = getCurrentPosition() {
            var newIndex: Int
            if position.index == 0 {
                newIndex = position.total - 1
            } else {
                newIndex = position.index - 1
            }
            await update(index: newIndex)
        }
    }
    
    public func nextAction() async {
        if let position = getCurrentPosition() {
            var newIndex: Int
            if position.index == position.total - 1 {
                newIndex = 0
            } else {
                newIndex = position.index + 1
            }
            await update(index: newIndex)
        }
    }
    
    func update(index: Int) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard let currentActivity = Activity<PinAttributes>.activities.first else { return }
        
        let posts = (try? PinInfoManager.shared.getPosts()) ?? []
        let total: Int = posts.count
        
        guard !((posts.count == 0) && (AutoEndLiveActivity.current == .noContent)) else {
            await end()
            return
        }
        
        var newIndex = index
        if total > 0 {
            if index >= total {
                // Fix for last one
                newIndex = total - 1
            }
        } else if total == 0 {
            newIndex = 0
        } else {
            
        }
        let target = try? PinInfoManager.shared.getPost(by: PinInfo(index: newIndex, total: total))
        let activityContent = ActivityContent(state: PinAttributes.ContentState(index: newIndex, total: total, text: target?.text, imageName: target?.image), staleDate: nil)
        
        await currentActivity.update(activityContent)
    }
}
