//
//  LiveActivityManager.swift
//  Pin It
//
//  Created by Ci Zi on 2025/10/14.
//

import Foundation
import ActivityKit
import Darwin
import MoreKit
import os

extension Notification.Name {
    static let LiveActivityStatusChanged = Notification.Name(rawValue: "com.zizicici.pin.liveActivity.statusChanged")
}

private struct LiveActivityStartDateStore {
    private static let key = "com.zizicici.pin.liveActivity.startDate"

    static var value: Date? {
        get {
            guard let userDefaults = UserDefaults(suiteName: appGroupId),
                  userDefaults.object(forKey: key) != nil else {
                return nil
            }
            return Date(timeIntervalSince1970: userDefaults.double(forKey: key))
        }
        set {
            if let newValue {
                UserDefaults(suiteName: appGroupId)?.set(newValue.timeIntervalSince1970, forKey: key)
            } else {
                UserDefaults(suiteName: appGroupId)?.removeObject(forKey: key)
            }
        }
    }
}

private actor LiveActivityOperationLock {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withLock<T>(_ operation: () async -> T) async -> T {
        await acquire()
        defer { release() }
        return await operation()
    }

    private func acquire() async {
        if !isLocked {
            isLocked = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

private enum LiveActivityProcessLock {
    enum Result<T> {
        case completed(T)
        case unavailable
    }

    private static let lockFileName = "liveActivity.lock"
    private static let retryDelayNanoseconds: UInt64 = 20_000_000
    private static let retryCount = 50

    static func withLock<T>(operation: () async -> T) async -> Result<T> {
        guard let fileDescriptor = openLockFile() else {
            logger.warning("Live Activity process lock file is unavailable")
            return .unavailable
        }

        guard await acquire(fileDescriptor: fileDescriptor) else {
            close(fileDescriptor)
            return .unavailable
        }

        defer {
            flock(fileDescriptor, LOCK_UN)
            close(fileDescriptor)
        }

        return .completed(await operation())
    }

    private static func openLockFile() -> Int32? {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else {
            return nil
        }

        let lockDirectory = containerURL.appendingPathComponent("locks", isDirectory: true)
        try? FileManager.default.createDirectory(at: lockDirectory, withIntermediateDirectories: true)

        let lockURL = lockDirectory.appendingPathComponent(lockFileName)
        let fileDescriptor = lockURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        }

        return fileDescriptor >= 0 ? fileDescriptor : nil
    }

    private static func acquire(fileDescriptor: Int32) async -> Bool {
        for attempt in 0...retryCount {
            if flock(fileDescriptor, LOCK_EX | LOCK_NB) == 0 {
                return true
            }

            if attempt < retryCount {
                try? await Task.sleep(nanoseconds: retryDelayNanoseconds)
            }
        }

        logger.warning("Live Activity process lock is busy")
        return false
    }
}

class LiveActivityManager: NSObject {
    private static let staleDuration: TimeInterval = 3600 * 6
    private static let restartInterval: TimeInterval = 3600 * 4

    private let operationLock = LiveActivityOperationLock()

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
    
    private var startDate: Date? {
        get {
            LiveActivityStartDateStore.value
        }
        set {
            LiveActivityStartDateStore.value = newValue
        }
    }
    
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
        await withLifecycleLock(unavailableValue: false) {
            await startUnlocked()
        }
    }

    @discardableResult
    func startIfAutoStartAllowsContent() async -> Bool {
        switch AutoStartLiveActivity.current {
        case .withContent:
            guard hasPinnedContent else {
                await updateRunningActivity()
                return false
            }
            return await start()
        case .appLaunch, .disable:
            await updateRunningActivity()
            return false
        }
    }

    func end() async {
        await withLifecycleLock(unavailableValue: ()) {
            await endUnlocked()
        }
    }

    func update() async {
        await withLifecycleLock(unavailableValue: ()) {
            await updateUnlocked()
        }
    }

    private func updateRunningActivity() async {
        await withLifecycleLock(unavailableValue: ()) {
            await updateRunningActivityUnlocked()
        }
    }

    private func withLifecycleLock<T>(unavailableValue: T, operation: () async -> T) async -> T {
        await operationLock.withLock {
            switch await LiveActivityProcessLock.withLock(operation: operation) {
            case .completed(let value):
                return value
            case .unavailable:
                await updateStatus()
                return unavailableValue
            }
        }
    }

    // Unlocked methods run under operationLock + process lock; do not call public
    // lifecycle methods from them or the actor lock will deadlock.
    private func startUnlocked() async -> Bool {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            await updateStatus()
            return false
        }

        let activities = Activity<PinAttributes>.activities
        if let currentActivity = primaryActivity(from: activities) {
            if shouldRefreshCurrentActivity {
                await end(activities: activities, clearsStartDate: true)
                return await requestActivity()
            }

            if startDate == nil {
                startDate = Date()
            }
            await end(activities: activities.filter { $0.id != currentActivity.id }, clearsStartDate: false)
            await updateContentState(for: currentActivity)
            await updateStatus()
            return true
        }

        await end(activities: activities, clearsStartDate: true)
        return await requestActivity()
    }

    private func updateRunningActivityUnlocked() async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            await updateStatus()
            return
        }

        let activities = Activity<PinAttributes>.activities
        guard let currentActivity = primaryActivity(from: activities) else {
            await end(activities: activities, clearsStartDate: true)
            await updateStatus()
            return
        }

        if startDate == nil {
            startDate = Date()
        }

        await end(activities: activities.filter { $0.id != currentActivity.id }, clearsStartDate: false)
        await updateContentState(for: currentActivity)
        await updateStatus()
    }

    private func restartIfNeededUnlocked() async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            await updateStatus()
            return
        }

        let activities = Activity<PinAttributes>.activities
        guard !activities.isEmpty else {
            await updateStatus()
            return
        }

        if let currentActivity = primaryActivity(from: activities) {
            if shouldRefreshCurrentActivity {
                await end(activities: activities, clearsStartDate: true)
                _ = await requestActivity()
                return
            }

            if startDate == nil {
                startDate = Date()
            }

            await end(activities: activities.filter { $0.id != currentActivity.id }, clearsStartDate: false)
            await updateStatus()
            return
        }

        if activities.contains(where: shouldAutoRecreate) {
            await end(activities: activities, clearsStartDate: true)
            if hasPinnedContent {
                _ = await requestActivity()
            } else {
                await updateStatus()
            }
            return
        }

        await end(activities: activities, clearsStartDate: true)
        await updateStatus()
    }

    private func endUnlocked() async {
        await end(activities: Activity<PinAttributes>.activities, clearsStartDate: true)
        await updateStatus()
    }

    private func end(activities: [Activity<PinAttributes>], clearsStartDate: Bool) async {
        guard !activities.isEmpty else { return }

        for activity in activities {
            await activity.end(nil, dismissalPolicy: .immediate)
            print("Ending the Live Activity: \(activity.id)")
        }

        if clearsStartDate {
            startDate = nil
        }
    }

    private func updateUnlocked() async {
        await restartIfNeededUnlocked()
        guard let currentActivity = primaryActivity(from: Activity<PinAttributes>.activities) else {
            await updateStatus()
            return
        }
        await updateContentState(for: currentActivity)
        await updateStatus()
    }
    
    private func updateStatus() async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            currentCount = 0
            return
        }

        currentCount = Activity<PinAttributes>.activities.filter { activity in
            switch activity.activityState {
            case .active, .pending:
                return true
            case .dismissed, .ended, .stale:
                return false
            @unknown default:
                return false
            }
        }.count
        print("Activity Count: \(currentCount)")
    }
    
    private func updateContentState(for activity: Activity<PinAttributes>) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        
        let (activityContent, shouldEnd) = currentActivityContent()

        if shouldEnd {
            await endUnlocked()
            return
        }
        guard let activityContent else { return }

        await activity.update(activityContent)
    }

    private func requestActivity() async -> Bool {
        let (activityContent, shouldEnd) = currentActivityContent()

        if shouldEnd {
            await endUnlocked()
            return false
        }
        guard let activityContent else {
            await updateStatus()
            return false
        }

        let activityAttributes = PinAttributes(name: "Pin")

        do {
            let activity = try Activity.request(attributes: activityAttributes, content: activityContent)
            startDate = Date()
            print(activity)
            await updateStatus()
            return true
        } catch {
            print(error.localizedDescription)
            await updateStatus()
            return false
        }
    }

    private func currentActivityContent() -> (content: ActivityContent<PinAttributes.ContentState>?, shouldEnd: Bool) {
        let (contentState, shouldEnd) = PinInfoManager.shared.getCurrentContentState()

        guard !shouldEnd else {
            return (nil, true)
        }
        guard let contentState else {
            return (nil, false)
        }

        let activityContent = ActivityContent(state: contentState, staleDate: Date(timeIntervalSinceNow: Self.staleDuration))
        return (activityContent, false)
    }

    private var shouldRefreshCurrentActivity: Bool {
        guard let startDate else { return false }
        return Date().timeIntervalSince(startDate) > Self.restartInterval
    }

    private var hasPinnedContent: Bool {
        !PinInfoManager.shared.pinInfo.posts.isEmpty
    }

    private func primaryActivity(from activities: [Activity<PinAttributes>]) -> Activity<PinAttributes>? {
        activities.first(where: isActive)
            ?? activities.first(where: isPending)
    }

    private func shouldAutoRecreate(_ activity: Activity<PinAttributes>) -> Bool {
        switch activity.activityState {
        case .ended, .stale:
            return true
        case .active, .pending, .dismissed:
            return false
        @unknown default:
            return true
        }
    }

    private func isActive(_ activity: Activity<PinAttributes>) -> Bool {
        switch activity.activityState {
        case .active:
            return true
        case .pending, .dismissed, .ended, .stale:
            return false
        @unknown default:
            return false
        }
    }

    private func isPending(_ activity: Activity<PinAttributes>) -> Bool {
        switch activity.activityState {
        case .pending:
            return true
        case .active, .dismissed, .ended, .stale:
            return false
        @unknown default:
            return false
        }
    }
}
