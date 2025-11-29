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
        
        Task {
            await updateStatus()            
        }
    }
    
    @discardableResult
    func start() async -> Bool {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return false }
        switch Activity<PinAttributes>.activities.count {
        case 0:
            // Create
            var result: Bool

            let (contentState, shouldEnd) = PinInfoManager.shared.getCurrentContentState()
            
            guard !shouldEnd else {
                await end()
                result = false
                return result
            }
            guard let contentState = contentState else {
                result = false
                return result
            }
            
            let activityContent = ActivityContent(state: contentState, staleDate: Date(timeIntervalSinceNow: 3600 * 6))
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
            
            await updateStatus()
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
                if startDate.timeIntervalSinceNow < -3600 * 4 {
                    await end()
                    await start()
                }
            }
        case .stale, .ended:
            await end()
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
        await updateStatus()
    }
    
    func update() async {
        await restartIfNeeded()
        await updateContentState()
        await updateStatus()
    }
    
    private func updateStatus() async {
        await restartIfNeeded()
        currentCount = Activity<PinAttributes>.activities.count
        print("Activity Count: \(currentCount)")
    }
    
    private func updateContentState() async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard let currentActivity = Activity<PinAttributes>.activities.first else { return }
        
        let (contentState, shouldEnd) = PinInfoManager.shared.getCurrentContentState()
        
        guard !shouldEnd else {
            await end()
            return
        }
        guard let contentState = contentState else {
            return
        }
        
        let activityContent = ActivityContent(state: contentState, staleDate: Date(timeIntervalSinceNow: 3600 * 6))
        await currentActivity.update(activityContent)
    }
}
