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
        case end
    }
    
    static let shared = LiveActivityManager()
    
    private var currentCount: Int = -1 {
        didSet {
            if currentCount >= 1 {
                status = .running
            } else {
                status = .end
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
    
    func addObserver() {
    }
    
    func postNotification() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: NSNotification.Name.LiveActivityStatusChanged, object: nil)
        }
    }
    
    var areActivitiesEnabled: Bool {
        return ActivityAuthorizationInfo().areActivitiesEnabled
    }
    
    @discardableResult
    func start(retryFlag: Int = 1) async -> Bool {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return false }
        switch Activity<PinAttributes>.activities.count {
        case 0:
            // Create
            guard retryFlag >= 0 else {
                return false
            }
            var result: Bool = false
            let activityContent = ActivityContent(state: PinAttributes.ContentState(text: "ZIZICICI LIMITED"), staleDate: nil)
            let activityAttributes = PinAttributes(name: "Pin")

            do {
                let activity = try Activity.request(attributes: activityAttributes, content: activityContent)
                startDate = Date()
                updateStatus()
                print(activity)
                result = true
            }
            catch {
                print(error.localizedDescription)
                result = false
            }
            return result
        case 1:
            // Update
            let activities = Activity<PinAttributes>.activities
            if let first = activities.first {
                await first.end(nil, dismissalPolicy: .immediate)
                return await start(retryFlag: retryFlag - 1)
            } else {
                return false
            }
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
                if startDate.timeIntervalSinceNow < -14400 {
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
    
    @objc
    func updateStatus() {
        Task {
            await restartIfNeeded()
            currentCount = Activity<PinAttributes>.activities.count
        }
        print("Activity Count: \(currentCount)")
    }
}
