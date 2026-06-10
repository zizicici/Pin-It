//
//  CloudKitRecordSyncManager.swift
//  Pin It
//
//  Created by OpenAI on 2026/5/3.
//

import CloudKit
import Foundation
import GRDB
import OSLog
import UIKit

private let cloudKitSyncLog = Logger(subsystem: "com.zizicici.pin", category: "CloudKitSync")

private struct CloudKitSyncDisabledError: LocalizedError {
    var errorDescription: String? {
        String(localized: "settings.cloudKitSync.error.disabled")
    }
}

private struct CloudKitOutboxBuildError: LocalizedError {
    var recordName: String
    var reason: String

    var errorDescription: String? {
        let prefix = String(localized: "settings.cloudKitSync.error.recordBuildFailed")
        return "\(prefix): \(recordName) (\(reason))"
    }
}

private struct CloudKitSyncInProgressError: LocalizedError {
    var errorDescription: String? {
        String(localized: "settings.cloudKitSync.error.syncInProgress")
    }
}

private struct CloudKitUserVisibleError: LocalizedError {
    var message: String

    var errorDescription: String? {
        message
    }
}

final class CloudKitRecordSyncManager: NSObject, @unchecked Sendable {
    static let shared = CloudKitRecordSyncManager()
    private static let tombstoneRetentionMilliseconds: Int64 = 30 * 24 * 60 * 60 * 1000

    private let client: CloudKitDatabaseClient

    private lazy var updateDebounce = Debounce<Int>(duration: 1.0) { [weak self] _ in
        await self?.sync()
    }
    private let stateLock = NSLock()
    private var isSyncing = false
    private var needsFollowUpSync = false
    private var isApplyingRemoteChanges = false
    private var isPostingCloudKitOriginatedUpdate = false
    private var isLocalResetRebuildQueued = false
    private var didFinishInitialCloudGate = false
    private var wantsBackgroundTask = false
    private var backgroundTaskIdentifier: UIBackgroundTaskIdentifier = .invalid
    private var activeOperations: [ObjectIdentifier: CKDatabaseOperation] = [:]
    private var syncEngine: CKSyncEngine?
    private var fetchAccumulator: FetchAccumulator?
    private var pendingFetchStateSerialization: CKSyncEngine.State.Serialization?
    private var serverRecordCacheByRecordName: [String: CKRecord] = [:]
    private var needsFullFetchAfterCurrentSync = false
    private var uploadAssetFilesByRecordName: [String: [URL]] = [:]
    private var syncRunID: UInt64 = 0
    private var engineGeneration: UInt64 = 0
    private var didEnsureRecordZone = false

    private static let maxConsecutiveSyncFailures = 5
    private static let maxSyncRoundsPerRun = 20
    private static let maxRetryDelaySeconds: Double = 60

    init(client: CloudKitDatabaseClient = LiveCloudKitDatabaseClient()) {
        self.client = client

        super.init()

        // Lazy vars are not thread-safe; .DatabaseUpdated can arrive from any
        // thread, so force initialization while init is still single-threaded.
        _ = updateDebounce
        cleanupTemporaryUploadAssetDirectory()
        NotificationCenter.default.addObserver(self, selector: #selector(databaseDidUpdate), name: .DatabaseUpdated, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(settingsDidUpdate), name: .DefaultStyleDidChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(applicationDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(applicationDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    func syncIfEnabled() {
        guard CloudKitSync.current == .enable else { return }
        if CloudKitSync.pendingRemoteReset {
            rebuildCloudKitDataAfterLocalReset()
            return
        }
        Task {
            await sync()
        }
    }

    func rebuildCloudKitData() async throws -> Bool {
        guard CloudKitSync.current == .enable else {
            throw CloudKitSyncDisabledError()
        }
        beginBackgroundTaskIfNeeded()
        guard let syncRun = beginSync() else {
            endBackgroundTaskIfNeeded()
            throw CloudKitSyncInProgressError()
        }

        do {
            clearFollowUpSync(runID: syncRun)
            try ensureSyncEnabled()
            let accountStatus = try await fetchAccountStatus()
            guard accountStatus == .available else {
                throw CloudKitUserVisibleError(message: cloudKitAccountStatusMessage(accountStatus))
            }

            OnboardingManager.shared.markExistingOnboardingRecordsIfNeeded()
            try cleanupLocalCloudKitOrphans()
            try validateLocalCloudKitSnapshotForRebuild()
            CloudKitSync.setPendingRemoteReset(true)
            try await deleteRecordZoneIfExists()
            try rebuildLocalCloudKitStateForCurrentDevice()
            try await ensureRecordZone()
            setDidEnsureRecordZone(true)
            // Stamp the rebuilt zone with a fresh generation so peers can tell a
            // deliberate rebuild (adopt this snapshot, prune their extras) from
            // accidental zone loss (keep local data and merge).
            let zoneGeneration = UUID().uuidString
            try await saveZoneResetMarker(generation: zoneGeneration)
            try persistZoneGeneration(zoneGeneration)
            let syncGeneration = currentEngineGeneration()
            let engine = try syncEngineInstance(expectedGeneration: syncGeneration)
            try syncEnginePendingChangesFromOutbox(engine)
            try markRemoteDataMayExistBeforeSendingOutboxIfNeeded()
            try await sendChangesAndCleanupUploadAssets(engine)
            try ensureEngineGeneration(syncGeneration)
            try syncEnginePendingChangesFromOutbox(engine)
            let hasOutboxFailures = try hasOutboxFailures()
            try markRemoteDataMayExistIfCloudKitStateExists()
            CloudKitSync.setPendingRemoteReset(false)
            // A rebuild deletes the zone and stamps a fresh reset marker — it
            // fully supersedes any interrupted clear.
            CloudKitSync.setPendingRemoteClear(false)
            CloudKitSync.setLastError(
                hasOutboxFailures ? String(localized: "settings.cloudKitSync.error.uploadFailed") : nil
            )
            runOnboardingAfterInitialCloudGateIfNeeded()
            let needsSync = finishExclusiveSync(runID: syncRun)
            if needsSync {
                syncIfEnabled()
            }
            return hasOutboxFailures
        } catch is CancellationError {
            _ = finishExclusiveSync(runID: syncRun)
            throw CancellationError()
        } catch {
            CloudKitSync.setLastError(error.localizedDescription)
            _ = finishExclusiveSync(runID: syncRun)
            throw error
        }
    }

    func validateAccountForEnabling() async throws {
        let accountStatus = try await fetchAccountStatus()
        guard accountStatus == .available else {
            throw CloudKitUserVisibleError(message: cloudKitAccountStatusMessage(accountStatus))
        }
    }

    func clearCloudKitData() async throws {
        beginBackgroundTaskIfNeeded()
        guard let syncRun = beginSync() else {
            endBackgroundTaskIfNeeded()
            throw CloudKitSyncInProgressError()
        }

        do {
            clearFollowUpSync(runID: syncRun)
            try await validateAccountForEnabling()
            // Persisted across a crash/kill: if the app dies between the zone
            // deletion and the new reset marker, the zone has no marker and
            // peers would misread the loss as accidental and re-upload — the
            // clear would be silently undone. The flag makes the interruption
            // visible on next launch so the user can re-run the clear.
            CloudKitSync.setPendingRemoteClear(true)
            try await deleteRecordZoneIfExists(requiresSyncEnabled: false)
            // Leave behind an empty zone holding only a fresh reset marker: peers
            // that still sync then prune their local copies, which is what the
            // clear alert promises ("the deletion will sync to other devices") —
            // instead of treating the missing zone as accidental loss and
            // re-uploading everything.
            try await ensureRecordZone(requiresSyncEnabled: false)
            try await saveZoneResetMarker(generation: UUID().uuidString)
            try clearLocalCloudKitState()
            CloudKitSync.setPendingRemoteClear(false)
            CloudKitSync.setPendingRemoteReset(false)
            CloudKitSync.clearRemoteDataMayExist()
            CloudKitSync.setLastError(nil)
            _ = finishExclusiveSync(runID: syncRun)
        } catch {
            CloudKitSync.setLastError(error.localizedDescription)
            _ = finishExclusiveSync(runID: syncRun)
            throw error
        }
    }

    @objc
    private func databaseDidUpdate() {
        guard CloudKitSync.current == .enable else { return }
        guard !localResetRebuildIsQueued() else { return }
        if shouldDebounceDatabaseUpdate() {
            updateDebounce.emit(value: 0)
        }
    }

    @objc
    private func settingsDidUpdate() {
        guard !shouldIgnoreCloudKitOriginatedUpdate() else { return }
        syncIfEnabled()
    }

    @objc
    private func applicationDidBecomeActive() {
        syncIfEnabled()
    }

    @objc
    private func applicationDidEnterBackground() {
        guard CloudKitSync.current == .enable else { return }
        beginBackgroundTaskIfNeeded()
        syncIfEnabled()
    }

    private func sync() async {
        guard CloudKitSync.current == .enable else {
            endBackgroundTaskIfNeeded()
            return
        }
        guard !CloudKitSync.pendingRemoteReset else {
            rebuildCloudKitDataAfterLocalReset()
            endBackgroundTaskIfNeeded()
            return
        }
        guard let runID = beginSync() else { return }

        var consecutiveFailures = 0
        var rounds = 0
        while true {
            rounds += 1
            if rounds > Self.maxSyncRoundsPerRun {
                // Persistent follow-up churn (e.g. serverRecordChanged ping-pong
                // against a peer that keeps writing). Yield; the next trigger
                // (foreground, local edit) starts a fresh run.
                cloudKitSyncLog.error("sync run exceeded \(Self.maxSyncRoundsPerRun) rounds; deferring")
                abortSyncRun(runID: runID)
                return
            }
            clearFollowUpSync(runID: runID)
            do {
                try ensureSyncEnabled()
                try await performSync()
                consecutiveFailures = 0
            } catch is CloudKitSyncDisabledError {
                runOnboardingAfterInitialCloudGateIfNeeded()
            } catch is CancellationError {
                runOnboardingAfterInitialCloudGateIfNeeded()
            } catch {
                guard CloudKitSync.current == .enable else {
                    runOnboardingAfterInitialCloudGateIfNeeded()
                    continue
                }
                guard !isOperationCancelled(error) else {
                    runOnboardingAfterInitialCloudGateIfNeeded()
                    if finishSyncIfNoFollowUp(runID: runID) {
                        return
                    }
                    continue
                }
                cloudKitSyncLog.error("sync failed: \(error.localizedDescription, privacy: .public)")
                CloudKitSync.setLastError(error.localizedDescription)
                runOnboardingAfterInitialCloudGateIfNeeded()
                consecutiveFailures += 1
                if consecutiveFailures >= Self.maxConsecutiveSyncFailures {
                    cloudKitSyncLog.error("giving up after \(consecutiveFailures) consecutive sync failures")
                    abortSyncRun(runID: runID)
                    return
                }
                let delaySeconds = retryDelaySeconds(for: error, attempt: consecutiveFailures)
                if delaySeconds > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                }
            }

            if finishSyncIfNoFollowUp(runID: runID) {
                return
            }
        }
    }

    /// Honors the server's CKErrorRetryAfterKey when present, otherwise backs
    /// off exponentially from the second consecutive failure on.
    private func retryDelaySeconds(for error: Error, attempt: Int) -> Double {
        let retryAfter = cloudKitRetryAfterSeconds(error) ?? 0
        let backoff = attempt >= 2 ? min(pow(2.0, Double(attempt - 1)), 30.0) : 0
        return min(max(retryAfter, backoff), Self.maxRetryDelaySeconds)
    }

    private func cloudKitRetryAfterSeconds(_ error: Error) -> Double? {
        guard let cloudKitError = error as? CKError else { return nil }
        var values: [Double] = []
        if let retryAfter = cloudKitError.retryAfterSeconds {
            values.append(retryAfter)
        }
        if let partialErrors = cloudKitError.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error] {
            values.append(contentsOf: partialErrors.values.compactMap { ($0 as? CKError)?.retryAfterSeconds })
        }
        return values.max()
    }

    private func performSync() async throws {
        try ensureSyncEnabled()
        try finishInterruptedDisableCleanupIfNeeded()
        try recoverInterruptedRemoteClearIfNeeded()
        guard !CloudKitSync.pendingRemoteReset else {
            rebuildCloudKitDataAfterLocalReset()
            return
        }
        let accountStatus = try await fetchAccountStatus()
        guard accountStatus == .available else {
            let message = cloudKitAccountStatusMessage(accountStatus)
            cloudKitSyncLog.info("sync skipped: \(message, privacy: .public)")
            CloudKitSync.setLastError(message)
            runOnboardingAfterInitialCloudGateIfNeeded()
            return
        }

        if zoneNeedsEnsure() {
            // CKModifyRecordZonesOperation is a full server round trip; do it once
            // per launch. zoneNotFound recovery paths reset the flag if the zone
            // disappears later.
            try await ensureRecordZone()
            setDidEnsureRecordZone(true)
        }
        OnboardingManager.shared.markExistingOnboardingRecordsIfNeeded()

        let syncGeneration = currentEngineGeneration()
        let hasEngineState = hasActiveSyncEngine() ? true : try hasStoredSyncEngineState()
        try cleanupLocalCloudKitOrphans()

        let freshEngineMode = try freshEngineMode(hasStoredEngineState: hasEngineState)
        if freshEngineMode.probesZoneDiscontinuity {
            // Keep-vs-prune is decided inside the apply transaction once the
            // snapshot's reset marker is known; don't enqueue anything yet.
        } else if freshEngineMode.bootstrapsLocalRecords {
            try enqueueBootstrapOutbox()
        } else if !hasEngineState {
            // Fresh engine without bootstrap = re-enable on a device that already
            // synced before. Reconcile any drift accumulated while sync was off so
            // the upcoming full-fetch's remote-wins logic doesn't clobber local edits
            // and so offline deletes actually reach CloudKit.
            try enqueueOfflineReconciliationOutbox()
        }

        let engine = try syncEngineInstance(expectedGeneration: syncGeneration)
        try ensureEngineGeneration(syncGeneration)
        try syncEnginePendingChangesFromOutbox(engine)

        beginFetchAccumulation(
            isFullSnapshot: !hasEngineState,
            prunesMissingLocalRecords: freshEngineMode.prunesMissingLocalRecords,
            probesZoneDiscontinuity: freshEngineMode.probesZoneDiscontinuity
        )
        do {
            try await engine.fetchChanges()
        } catch {
            discardFetchAccumulation()
            if isZoneNotFound(error) || isChangeTokenExpired(error) {
                try resetSyncEngineStateForZoneDiscontinuity()
                requestFollowUpSync()
                CloudKitSync.setLastError(String(localized: "settings.cloudKitSync.error.fullRefresh"))
                runOnboardingAfterInitialCloudGateIfNeeded()
                return
            }
            // Batches delivered before the failure were accumulated and just
            // discarded, but the engine's in-memory token already moved past
            // them. Keeping the instance would resume from that token and never
            // re-deliver — fatal for a probe/full-snapshot pass (the keep-vs-
            // prune decision would silently never happen). Drop the engine so
            // the next pass rebuilds from the last persisted token.
            invalidateSyncEngineForRedelivery()
            throw error
        }
        try ensureEngineGeneration(syncGeneration)
        try applyAccumulatedFetchIfNeeded()

        if try resetForRequestedFullFetchIfNeeded() {
            runOnboardingAfterInitialCloudGateIfNeeded()
            return
        }

        try ensureEngineGeneration(syncGeneration)
        try syncEnginePendingChangesFromOutbox(engine)
        try ensureSyncEnabled()
        try markRemoteDataMayExistBeforeSendingOutboxIfNeeded()
        try await sendChangesAndCleanupUploadAssets(engine)
        try ensureEngineGeneration(syncGeneration)
        try syncEnginePendingChangesFromOutbox(engine)

        if try enqueueExpiredTombstonePurgesIfNeeded() {
            try syncEnginePendingChangesFromOutbox(engine)
            try ensureSyncEnabled()
            try markRemoteDataMayExistBeforeSendingOutboxIfNeeded()
            try await sendChangesAndCleanupUploadAssets(engine)
            try ensureEngineGeneration(syncGeneration)
            try syncEnginePendingChangesFromOutbox(engine)
        }

        if try resetForRequestedFullFetchIfNeeded() {
            runOnboardingAfterInitialCloudGateIfNeeded()
            return
        }

        let hasOutboxFailures = try hasOutboxFailures()
        try markRemoteDataMayExistIfCloudKitStateExists()
        CloudKitSync.setLastError(
            hasOutboxFailures ? String(localized: "settings.cloudKitSync.error.uploadFailed") : nil
        )
        runOnboardingAfterInitialCloudGateIfNeeded()
    }
}

extension CloudKitRecordSyncManager: CKSyncEngineDelegate {
    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        guard isCurrentSyncEngine(syncEngine) else { return }
        do {
            switch event {
            case .stateUpdate(let stateUpdate):
                if shouldDeferStateUpdates() {
                    setPendingFetchStateSerialization(stateUpdate.stateSerialization)
                } else {
                    try persistSyncEngineStateSerialization(stateUpdate.stateSerialization)
                }
            case .accountChange:
                try handleAccountChange()
                requestFollowUpSync()
            case .fetchedDatabaseChanges(let changes):
                try handleFetchedDatabaseChanges(changes)
            case .fetchedRecordZoneChanges(let changes):
                try handleFetchedRecordZoneChanges(changes)
            case .sentDatabaseChanges(let changes):
                try handleSentDatabaseChanges(changes, syncEngine: syncEngine)
            case .sentRecordZoneChanges(let changes):
                try handleSentRecordZoneChanges(changes, syncEngine: syncEngine)
            case .didFetchRecordZoneChanges(let changes):
                if let error = changes.error, isZoneNotFound(error) || isChangeTokenExpired(error) {
                    discardFetchAccumulation()
                    try resetSyncEngineStateForZoneDiscontinuity()
                    CloudKitSync.setLastError(String(localized: "settings.cloudKitSync.error.fullRefresh"))
                    requestFollowUpSync()
                }
            case .didFetchChanges:
                try applyAccumulatedFetchIfNeeded()
            case .willFetchChanges,
                 .willFetchRecordZoneChanges,
                 .willSendChanges,
                 .didSendChanges:
                break
            @unknown default:
                break
            }
        } catch {
            cloudKitSyncLog.error("sync engine event failed: \(error.localizedDescription, privacy: .public)")
            CloudKitSync.setLastError(error.localizedDescription)
            requestFollowUpSync()
        }
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        do {
            return try await makeRecordZoneChangeBatch(context: context, syncEngine: syncEngine)
        } catch {
            cloudKitSyncLog.error("sync engine batch failed: \(error.localizedDescription, privacy: .public)")
            CloudKitSync.setLastError(error.localizedDescription)
            requestFollowUpSync()
            return nil
        }
    }
}

extension CloudKitRecordSyncManager {
    func shouldDebounceDatabaseUpdate() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }

        if isApplyingRemoteChanges {
            needsFollowUpSync = true
            return false
        }
        if isPostingCloudKitOriginatedUpdate {
            return false
        }
        return true
    }

    func shouldIgnoreCloudKitOriginatedUpdate() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isPostingCloudKitOriginatedUpdate
    }

    func currentEngineGeneration() -> UInt64 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return engineGeneration
    }

    func ensureEngineGeneration(_ generation: UInt64) throws {
        stateLock.lock()
        let isCurrent = generation == engineGeneration
        stateLock.unlock()
        if !isCurrent {
            throw CancellationError()
        }
    }

    func postCloudKitOriginatedUpdate(_ name: Notification.Name) {
        DispatchQueue.main.async {
            self.stateLock.lock()
            self.isPostingCloudKitOriginatedUpdate = true
            self.stateLock.unlock()
            NotificationCenter.default.post(name: name, object: nil)
            self.stateLock.lock()
            self.isPostingCloudKitOriginatedUpdate = false
            self.stateLock.unlock()
        }
    }

    func beginSync() -> UInt64? {
        stateLock.lock()
        defer { stateLock.unlock() }

        if isSyncing {
            needsFollowUpSync = true
            return nil
        }
        syncRunID += 1
        isSyncing = true
        return syncRunID
    }

    func clearFollowUpSync(runID: UInt64) {
        stateLock.lock()
        guard runID == syncRunID else {
            stateLock.unlock()
            return
        }
        needsFollowUpSync = false
        stateLock.unlock()
    }

    func finishSyncIfNoFollowUp(runID: UInt64) -> Bool {
        stateLock.lock()
        guard runID == syncRunID else {
            stateLock.unlock()
            return true
        }
        if needsFollowUpSync {
            stateLock.unlock()
            return false
        }
        isSyncing = false
        stateLock.unlock()
        endBackgroundTaskIfNeeded()
        return true
    }

    func finishExclusiveSync(runID: UInt64) -> Bool {
        stateLock.lock()
        guard runID == syncRunID else {
            stateLock.unlock()
            return false
        }
        let needsSync = needsFollowUpSync
        needsFollowUpSync = false
        isSyncing = false
        stateLock.unlock()
        endBackgroundTaskIfNeeded()
        return needsSync
    }

    func beginBackgroundTaskIfNeeded() {
        stateLock.lock()
        wantsBackgroundTask = true
        let hasBackgroundTask = backgroundTaskIdentifier != .invalid
        stateLock.unlock()
        guard !hasBackgroundTask else { return }

        if Thread.isMainThread {
            beginBackgroundTaskOnMain()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.beginBackgroundTaskOnMain()
            }
        }
    }

    func beginBackgroundTaskOnMain() {
        stateLock.lock()
        let shouldStartBackgroundTask = wantsBackgroundTask && backgroundTaskIdentifier == .invalid
        stateLock.unlock()
        guard shouldStartBackgroundTask else { return }

        let task = UIApplication.shared.beginBackgroundTask(withName: "CloudKitRecordSync") { [weak self] in
            self?.cancelActiveOperations()
            self?.endBackgroundTaskIfNeeded()
        }

        stateLock.lock()
        if wantsBackgroundTask && backgroundTaskIdentifier == .invalid {
            backgroundTaskIdentifier = task
            stateLock.unlock()
        } else {
            stateLock.unlock()
            UIApplication.shared.endBackgroundTask(task)
        }
    }

    func endBackgroundTaskIfNeeded() {
        stateLock.lock()
        wantsBackgroundTask = false
        let task = backgroundTaskIdentifier
        backgroundTaskIdentifier = .invalid
        stateLock.unlock()

        guard task != .invalid else { return }
        DispatchQueue.main.async {
            UIApplication.shared.endBackgroundTask(task)
        }
    }

    func setApplyingRemoteChanges(_ value: Bool) {
        stateLock.lock()
        isApplyingRemoteChanges = value
        stateLock.unlock()
    }

    func requestFollowUpSync() {
        stateLock.lock()
        needsFollowUpSync = true
        stateLock.unlock()
    }

    /// Ends the run without clearing needsFollowUpSync: pending work survives
    /// for the next trigger instead of being retried right now.
    func abortSyncRun(runID: UInt64) {
        stateLock.lock()
        if runID == syncRunID {
            isSyncing = false
        }
        stateLock.unlock()
        endBackgroundTaskIfNeeded()
    }

    func zoneNeedsEnsure() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return !didEnsureRecordZone
    }

    func setDidEnsureRecordZone(_ value: Bool) {
        stateLock.lock()
        didEnsureRecordZone = value
        stateLock.unlock()
    }

    func localResetRebuildIsQueued() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isLocalResetRebuildQueued
    }

    func setLocalResetRebuildQueued(_ value: Bool) {
        stateLock.lock()
        isLocalResetRebuildQueued = value
        stateLock.unlock()
    }

    func rebuildCloudKitDataAfterLocalReset() {
        guard !localResetRebuildIsQueued() else { return }
        setLocalResetRebuildQueued(true)

        Task {
            defer {
                self.setLocalResetRebuildQueued(false)
            }
            while CloudKitSync.current == .enable {
                do {
                    _ = try await self.rebuildCloudKitData()
                    return
                } catch is CloudKitSyncInProgressError {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                } catch is CancellationError {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                } catch {
                    CloudKitSync.setLastError(error.localizedDescription)
                    return
                }
            }
        }
    }

    func disableSyncAndClearLocalState() {
        cancelActiveOperations()
        endBackgroundTaskIfNeeded()
        stateLock.lock()
        syncEngine = nil
        stateLock.unlock()
        // Synchronous marker, deferred cleanup: the DB write must not run on
        // this (main) thread — it would block behind any in-flight remote-apply
        // transaction — but a kill before the deferred write lands would leave
        // the engine state behind and make a later re-enable skip offline
        // reconciliation. The flag survives the kill; the next sync finishes
        // the cleanup first (finishInterruptedDisableCleanupIfNeeded).
        CloudKitSync.setPendingDisableCleanup(true)
        let preservesLocalSyncIntent = CloudKitSync.remoteDataMayExist || CloudKitSync.pendingRemoteReset
        AppDatabase.shared.dbWriter?.asyncWrite({ db in
            try Self.clearLocalStateForDisable(preservesLocalSyncIntent: preservesLocalSyncIntent, in: db)
        }, completion: { _, result in
            switch result {
            case .success:
                CloudKitSync.setPendingDisableCleanup(false)
            case .failure(let error):
                CloudKitSync.setLastError(error.localizedDescription)
            }
        })
    }

    private static func clearLocalStateForDisable(preservesLocalSyncIntent: Bool, in db: Database) throws {
        try CloudKitSyncState.clearSyncEngineStateSerialization(in: db)
        try CloudKitSyncState.clearBootstrapSuppression(in: db)
        try CloudKitSyncState.clearLocalRecordPreservation(in: db)
        if !preservesLocalSyncIntent {
            try CloudKitOutboxEntry.deleteAll(db)
            try CloudKitRecordMetadata.deleteAll(db)
            try CloudKitLocalTombstone.deleteAll(db)
            try CloudKitSettingRecord.deleteAll(db)
            try CloudKitSyncState.clearZoneDiscontinuityProbe(in: db)
            try CloudKitSyncState.clearZoneGeneration(in: db)
        }
    }

    /// Finishes a disable-time cleanup that never committed (app killed before
    /// the deferred asyncWrite ran, or it failed). Runs synchronously on the
    /// caller's (background) task; also barriers the subsequent engine-state
    /// reads in performSync behind the cleanup, closing the read-vs-asyncWrite
    /// race of a rapid disable→enable toggle.
    func finishInterruptedDisableCleanupIfNeeded() throws {
        guard CloudKitSync.pendingDisableCleanup else { return }
        let preservesLocalSyncIntent = CloudKitSync.remoteDataMayExist || CloudKitSync.pendingRemoteReset
        try AppDatabase.shared.dbWriter?.write { db in
            try Self.clearLocalStateForDisable(preservesLocalSyncIntent: preservesLocalSyncIntent, in: db)
        }
        CloudKitSync.setPendingDisableCleanup(false)
    }

    /// Re-enabling sync supersedes an interrupted "clear CloudKit data": the
    /// zone may be missing (or missing its reset marker) while local sync
    /// metadata still exists, and the upcoming full fetch of that empty zone
    /// would otherwise PRUNE every previously-synced local record. Preserve
    /// local data for that fetch (bootstrap re-uploads it) and drop the stale
    /// clear intent.
    func recoverInterruptedRemoteClearIfNeeded() throws {
        guard CloudKitSync.pendingRemoteClear else { return }
        _ = try AppDatabase.shared.dbWriter?.write { db in
            try CloudKitSyncState.preserveLocalRecordsForNextFullFetch(in: db)
        }
        CloudKitSync.setPendingRemoteClear(false)
    }

    func cancelSyncForLocalReset() {
        cancelActiveOperations()
        endBackgroundTaskIfNeeded()
    }

    func runOnboardingAfterInitialCloudGateIfNeeded() {
        stateLock.lock()
        guard !didFinishInitialCloudGate else {
            stateLock.unlock()
            return
        }
        didFinishInitialCloudGate = true
        stateLock.unlock()

        DispatchQueue.main.async {
            OnboardingManager.shared.setupOnboardingDataIfNeeded()
        }
    }

    func addOperation(_ operation: CKDatabaseOperation) {
        let identifier = ObjectIdentifier(operation)
        stateLock.lock()
        activeOperations[identifier] = operation
        stateLock.unlock()

        let existingCompletionBlock = operation.completionBlock
        operation.completionBlock = { [weak self, weak operation] in
            existingCompletionBlock?()
            guard let operation else { return }
            self?.unregisterOperation(operation)
        }
        client.add(operation)
    }

    func unregisterOperation(_ operation: CKDatabaseOperation) {
        let identifier = ObjectIdentifier(operation)
        stateLock.lock()
        activeOperations.removeValue(forKey: identifier)
        stateLock.unlock()
    }

    func cancelActiveOperations() {
        stateLock.lock()
        let operations = Array(activeOperations.values)
        activeOperations.removeAll()
        engineGeneration += 1
        syncRunID += 1
        isSyncing = false
        syncEngine = nil
        fetchAccumulator = nil
        pendingFetchStateSerialization = nil
        serverRecordCacheByRecordName.removeAll()
        needsFullFetchAfterCurrentSync = false
        needsFollowUpSync = false
        stateLock.unlock()

        for operation in operations {
            operation.cancel()
        }
        cleanupAllUploadAssetFiles()
    }
}

extension CloudKitRecordSyncManager {
    func handleFetchedDatabaseChanges(_ changes: CKSyncEngine.Event.FetchedDatabaseChanges) throws {
        guard changes.deletions.contains(where: { $0.zoneID == CloudKitRecordName.zoneID }) else { return }
        try resetSyncEngineStateForZoneDiscontinuity()
        CloudKitSync.setLastError(String(localized: "settings.cloudKitSync.error.fullRefresh"))
        requestFollowUpSync()
    }

    func handleAccountChange() throws {
        cancelActiveOperations()
        endBackgroundTaskIfNeeded()
        setDidEnsureRecordZone(false)
        CloudKitSync.clearRemoteDataMayExist()
        CloudKitSync.setPendingRemoteReset(false)
        // An interrupted clear of the OLD account's zone must not be re-run
        // (or surfaced) against the new account.
        CloudKitSync.setPendingRemoteClear(false)
        // The account-change wipe below is a superset of the disable cleanup.
        CloudKitSync.setPendingDisableCleanup(false)

        _ = try AppDatabase.shared.dbWriter?.write { db in
            try CloudKitSyncState.clearSyncEngineStateSerialization(in: db)
            try CloudKitSyncState.clearBootstrapSuppression(in: db)
            // The new account's zone has its own generation history.
            try CloudKitSyncState.clearZoneDiscontinuityProbe(in: db)
            try CloudKitSyncState.clearZoneGeneration(in: db)
            try CloudKitOutboxEntry.deleteAll(db)
            try CloudKitRecordMetadata.deleteAll(db)
            try CloudKitLocalTombstone.deleteAll(db)
            try CloudKitSettingRecord.deleteAll(db)
            // Without this flag the next fresh-engine fetch would set prunesMissing
            // LocalRecords=true and wipe user data to match the new account's zone.
            try CloudKitSyncState.preserveLocalRecordsForNextFullFetch(in: db)
        }

        CloudKitSync.disableAfterAccountChange()
    }

    func handleFetchedRecordZoneChanges(_ changes: CKSyncEngine.Event.FetchedRecordZoneChanges) throws {
        appendFetchedRecordZoneChanges(changes)
    }

    func handleSentDatabaseChanges(
        _ changes: CKSyncEngine.Event.SentDatabaseChanges,
        syncEngine: CKSyncEngine
    ) throws {
        let successfulChanges: [CKSyncEngine.PendingDatabaseChange] =
        changes.savedZones.map { .saveZone($0) }
        + changes.deletedZoneIDs.map { .deleteZone($0) }

        if !successfulChanges.isEmpty {
            syncEngine.state.remove(pendingDatabaseChanges: successfulChanges)
        }

        if let failure = changes.failedZoneSaves.first?.error ?? changes.failedZoneDeletes.values.first {
            throw failure
        }
    }

    func handleSentRecordZoneChanges(
        _ changes: CKSyncEngine.Event.SentRecordZoneChanges,
        syncEngine: CKSyncEngine
    ) throws {
        let recordNotFoundDeletes = changes.failedRecordDeletes
            .filter { isRecordNotFound($0.value) }
            .map(\.key)
        let deletedRecordIDs = changes.deletedRecordIDs + recordNotFoundDeletes
        let successfulChanges: [CKSyncEngine.PendingRecordZoneChange] =
        changes.savedRecords.map { .saveRecord($0.recordID) }
        + deletedRecordIDs.map { .deleteRecord($0) }

        if !successfulChanges.isEmpty {
            syncEngine.state.remove(pendingRecordZoneChanges: successfulChanges)
        }

        let savedRecordVersions = Dictionary(
            uniqueKeysWithValues: changes.savedRecords.map { ($0.recordID.recordName, modificationTime(of: $0)) }
        )
        for recordName in savedRecordVersions.keys {
            evictCachedServerRecord(recordName: recordName)
        }
        let failedSaveResults = Dictionary(
            uniqueKeysWithValues: changes.failedRecordSaves.map {
                ($0.record.recordID.recordName, (version: modificationTime(of: $0.record), error: $0.error as Error))
            }
        )
        for failure in changes.failedRecordSaves {
            if let serverRecord = failure.error.serverRecord {
                cacheServerRecord(serverRecord)
            }
        }
        let failedDeleteErrors = changes.failedRecordDeletes
            .filter { !isRecordNotFound($0.value) }
        let deletedRecordNames = Set(deletedRecordIDs.map(\.recordName))
        var failedEntries: [(id: Int64, error: Error)] = []
        var clearedEntryIDs: [Int64] = []

        for entry in try loadOutboxEntries() {
            guard let entryID = entry.id,
                  let operation = entry.cloudKitOperation else {
                continue
            }
            switch operation {
            case .save, .delete:
                if let savedVersion = savedRecordVersions[entry.recordName],
                   savedVersion >= entry.localVersion {
                    clearedEntryIDs.append(entryID)
                } else if savedRecordVersions[entry.recordName] != nil {
                    requestFollowUpSync()
                } else if let failure = failedSaveResults[entry.recordName],
                          failure.version >= entry.localVersion {
                    failedEntries.append((entryID, failure.error))
                }
            case .purge:
                if deletedRecordNames.contains(entry.recordName) {
                    clearedEntryIDs.append(entryID)
                } else if let error = failedDeleteErrors[CloudKitRecordName.recordID(entry.recordName)] {
                    failedEntries.append((entryID, error))
                }
            }
        }

        if failedEntries.contains(where: { isServerRecordChanged($0.error) }) {
            requestFollowUpSync()
        }
        try markOutboxFailures(failedEntries)
        try clearOutbox(ids: clearedEntryIDs)
        cleanupUploadAssetFiles(for: Array(Set(savedRecordVersions.keys).union(failedSaveResults.keys)))
    }

    func makeRecordZoneChangeBatch(
        context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async throws -> CKSyncEngine.RecordZoneChangeBatch? {
        let scopedChanges = Set(syncEngine.state.pendingRecordZoneChanges.filter {
            context.options.scope.contains($0) && isManagedRecordZoneChange($0)
        })
        guard !scopedChanges.isEmpty else { return nil }

        let entries = try loadOutboxEntries()
        let scopedEntries = Array(entries
            .filter { entry in
                pendingRecordZoneChanges(for: entry).contains { scopedChanges.contains($0) }
            }
            .prefix(50))
        guard !scopedEntries.isEmpty else { return nil }

        let serverRecordState = try await fetchServerRecordState(for: scopedEntries)
        let batch = try buildRecordZoneChangeBatch(
            entries: scopedEntries,
            scopedChanges: scopedChanges,
            serverRecordState: serverRecordState
        )

        if !batch.changesToRemove.isEmpty {
            syncEngine.state.remove(pendingRecordZoneChanges: batch.changesToRemove)
        }
        try markOutboxFailures(batch.failedEntries)
        try dropOutbox(ids: batch.skippedEntryIDs)

        guard !batch.recordsToSave.isEmpty || !batch.recordIDsToDelete.isEmpty else {
            return nil
        }
        return CKSyncEngine.RecordZoneChangeBatch(
            recordsToSave: batch.recordsToSave,
            recordIDsToDelete: batch.recordIDsToDelete,
            atomicByZone: false
        )
    }

    func buildRecordZoneChangeBatch(
        entries: [CloudKitOutboxEntry],
        scopedChanges: Set<CKSyncEngine.PendingRecordZoneChange>,
        serverRecordState: ServerRecordState
    ) throws -> (
        recordsToSave: [CKRecord],
        recordIDsToDelete: [CKRecord.ID],
        skippedEntryIDs: [Int64],
        failedEntries: [(id: Int64, error: Error)],
        changesToRemove: [CKSyncEngine.PendingRecordZoneChange]
    ) {
        var recordsToSave: [CKRecord] = []
        var recordIDsToDelete: [CKRecord.ID] = []
        var skippedEntryIDs: [Int64] = []
        var failedEntries: [(id: Int64, error: Error)] = []
        var changesToRemove: [CKSyncEngine.PendingRecordZoneChange] = []

        for entry in entries {
            guard let entryID = entry.id,
                  let type = entry.cloudKitRecordType,
                  let operation = entry.cloudKitOperation else {
                if let id = entry.id {
                    skippedEntryIDs.append(id)
                }
                continue
            }

            let pendingChanges = pendingRecordZoneChanges(for: entry).filter { scopedChanges.contains($0) }
            guard !pendingChanges.isEmpty else { continue }

            do {
                if serverStateWins(entry: entry, operation: operation, against: serverRecordState) {
                    requestFullFetchAfterCurrentSync()
                    continue
                }

                switch operation {
                case .save:
                    let saveChange = CKSyncEngine.PendingRecordZoneChange.saveRecord(
                        CloudKitRecordName.recordID(entry.recordName)
                    )
                    guard scopedChanges.contains(saveChange) else { continue }
                    if let record = try makeRecord(
                        for: entry,
                        type: type,
                        baseRecord: serverRecordState.recordsByRecordName[entry.recordName]
                    ) {
                        recordsToSave.append(record)
                    } else {
                        skippedEntryIDs.append(entryID)
                        changesToRemove.append(saveChange)
                    }
                case .delete:
                    let saveChange = CKSyncEngine.PendingRecordZoneChange.saveRecord(
                        CloudKitRecordName.recordID(entry.recordName)
                    )
                    if scopedChanges.contains(saveChange) {
                        recordsToSave.append(makeDeletedRecord(
                            for: entry,
                            deletedRecordType: type,
                            baseRecord: serverRecordState.recordsByRecordName[entry.recordName]
                        ))
                    }
                case .purge:
                    let deleteID = CloudKitRecordName.recordID(entry.recordName)
                    let deleteChange = CKSyncEngine.PendingRecordZoneChange.deleteRecord(deleteID)
                    if scopedChanges.contains(deleteChange) {
                        recordIDsToDelete.append(deleteID)
                    }
                }
            } catch {
                failedEntries.append((entryID, error))
                changesToRemove.append(contentsOf: pendingChanges)
            }
        }

        return (
            recordsToSave: recordsToSave,
            recordIDsToDelete: recordIDsToDelete,
            skippedEntryIDs: skippedEntryIDs,
            failedEntries: failedEntries,
            changesToRemove: changesToRemove
        )
    }

    func makeRemoteChangeSet(
        changedRecords: [CKRecord],
        physicalDeletedRecords: [PhysicalDeletedRecord]
    ) -> RemoteChangeSet {
        var activeRecordsByType: [CloudKitRecordType: [CKRecord]] = [:]
        var tombstonesByDeletedRecordName: [String: RemoteTombstone] = [:]
        var zoneResetGeneration: String?

        for record in changedRecords {
            if record.recordID.recordName == CloudKitRecordName.zoneMetaName,
               record.recordType == CloudKitRecordName.zoneMetaRecordType {
                zoneResetGeneration = stringValue(Field.resetGeneration, in: record)
                continue
            }
            guard let type = CloudKitRecordType(rawValue: record.recordType) else { continue }
            if isDeletedRecord(record),
               let tombstone = makeRemoteTombstone(from: record, type: type) {
                if let existing = tombstonesByDeletedRecordName[tombstone.deletedRecordName],
                   existing.deletionTime > tombstone.deletionTime {
                    continue
                }
                tombstonesByDeletedRecordName[tombstone.deletedRecordName] = tombstone
            } else {
                activeRecordsByType[type, default: []].append(record)
            }
        }

        let hasUnexplainedPhysicalDeletes = physicalDeletedRecords.contains { deletion in
            return deletion.recordName != CloudKitRecordName.zoneMetaName
                && tombstonesByDeletedRecordName[deletion.recordName] == nil
        }

        return RemoteChangeSet(
            activeRecordsByType: activeRecordsByType,
            tombstonesByDeletedRecordName: tombstonesByDeletedRecordName,
            hasUnexplainedPhysicalDeletes: hasUnexplainedPhysicalDeletes,
            zoneResetGeneration: zoneResetGeneration
        )
    }

    func fetchAccountStatus() async throws -> CKAccountStatus {
        try await client.accountStatus()
    }

    func ensureRecordZone(requiresSyncEnabled: Bool = true) async throws {
        if requiresSyncEnabled {
            try ensureSyncEnabled()
        }
        let zone = CKRecordZone(zoneID: CloudKitRecordName.zoneID)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let operation = CKModifyRecordZonesOperation(recordZonesToSave: [zone], recordZoneIDsToDelete: nil)
            operation.modifyRecordZonesResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            addOperation(operation)
        }
    }

    /// Writes the zone reset marker peers use to tell a deliberate rebuild from
    /// accidental zone loss. Saved directly (not through the engine/outbox) so
    /// it never mixes with record-level sync state.
    func saveZoneResetMarker(generation: String) async throws {
        let record = CKRecord(
            recordType: CloudKitRecordName.zoneMetaRecordType,
            recordID: CloudKitRecordName.recordID(CloudKitRecordName.zoneMetaName)
        )
        set(generation, for: Field.resetGeneration, on: record)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let operation = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
            operation.savePolicy = .allKeys
            operation.modifyRecordsResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            addOperation(operation)
        }
    }

    func persistZoneGeneration(_ generation: String) throws {
        _ = try AppDatabase.shared.dbWriter?.write { db in
            try CloudKitSyncState.setZoneGeneration(generation, in: db)
        }
    }

    func deleteRecordZoneIfExists(requiresSyncEnabled: Bool = true) async throws {
        setDidEnsureRecordZone(false)
        if requiresSyncEnabled {
            try ensureSyncEnabled()
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let operation = CKModifyRecordZonesOperation(
                recordZonesToSave: nil,
                recordZoneIDsToDelete: [CloudKitRecordName.zoneID]
            )
            operation.modifyRecordZonesResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    if self.isZoneNotFound(error) {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: error)
                    }
                }
            }
            addOperation(operation)
        }
    }

    func clearLocalCloudKitState() throws {
        stateLock.lock()
        engineGeneration += 1
        syncEngine = nil
        fetchAccumulator = nil
        pendingFetchStateSerialization = nil
        serverRecordCacheByRecordName.removeAll()
        needsFullFetchAfterCurrentSync = false
        uploadAssetFilesByRecordName.removeAll()
        didEnsureRecordZone = false
        stateLock.unlock()

        cleanupTemporaryUploadAssetDirectory()
        _ = try AppDatabase.shared.dbWriter?.write { db in
            try CloudKitSyncState.clearSyncEngineStateSerialization(in: db)
            try CloudKitSyncState.clearBootstrapSuppression(in: db)
            try CloudKitSyncState.clearLocalRecordPreservation(in: db)
            try CloudKitSyncState.clearZoneDiscontinuityProbe(in: db)
            try CloudKitSyncState.clearZoneGeneration(in: db)
            try CloudKitOutboxEntry.deleteAll(db)
            try CloudKitRecordMetadata.deleteAll(db)
            try CloudKitLocalTombstone.deleteAll(db)
            try CloudKitSettingRecord.deleteAll(db)
        }
        // This wipe is a superset of the disable-time cleanup.
        CloudKitSync.setPendingDisableCleanup(false)
    }

    func ensureSyncEnabled() throws {
        guard CloudKitSync.current == .enable else {
            throw CloudKitSyncDisabledError()
        }
    }

    func isChangeTokenExpired(_ error: Error) -> Bool {
        guard let cloudKitError = error as? CKError else { return false }
        if cloudKitError.code == .changeTokenExpired {
            return true
        }
        guard cloudKitError.code == .partialFailure,
              let partialErrors = cloudKitError.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error] else {
            return false
        }
        return partialErrors.values.contains { isChangeTokenExpired($0) }
    }

    func isPartialFailure(_ error: Error) -> Bool {
        guard let cloudKitError = error as? CKError else { return false }
        return cloudKitError.code == .partialFailure
    }

    func isRecordNotFound(_ error: Error) -> Bool {
        guard let cloudKitError = error as? CKError else { return false }
        return cloudKitError.code == .unknownItem
    }

    func isServerRecordChanged(_ error: Error) -> Bool {
        guard let cloudKitError = error as? CKError else { return false }
        if cloudKitError.code == .serverRecordChanged {
            return true
        }
        guard cloudKitError.code == .partialFailure,
              let partialErrors = cloudKitError.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error] else {
            return false
        }
        return partialErrors.values.contains { isServerRecordChanged($0) }
    }

    func isOperationCancelled(_ error: Error) -> Bool {
        guard let cloudKitError = error as? CKError else { return false }
        if cloudKitError.code == .operationCancelled {
            return true
        }
        guard cloudKitError.code == .partialFailure,
              let partialErrors = cloudKitError.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error] else {
            return false
        }
        return partialErrors.values.contains { isOperationCancelled($0) }
    }

    func isZoneNotFound(_ error: Error) -> Bool {
        guard let cloudKitError = error as? CKError else { return false }
        if cloudKitError.code == .zoneNotFound || cloudKitError.code == .unknownItem || cloudKitError.code == .userDeletedZone {
            return true
        }
        guard cloudKitError.code == .partialFailure,
              let partialErrors = cloudKitError.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error] else {
            return false
        }
        return partialErrors.values.allSatisfy { isZoneNotFound($0) }
    }

    func cloudKitAccountStatusMessage(_ status: CKAccountStatus) -> String {
        switch status {
        case .available:
            return ""
        case .noAccount:
            return String(localized: "settings.cloudKitSync.error.noAccount")
        case .restricted:
            return String(localized: "settings.cloudKitSync.error.restricted")
        case .couldNotDetermine:
            return String(localized: "settings.cloudKitSync.error.couldNotDetermine")
        case .temporarilyUnavailable:
            return String(localized: "settings.cloudKitSync.error.temporarilyUnavailable")
        @unknown default:
            return String(localized: "settings.cloudKitSync.error.couldNotDetermine")
        }
    }
}

extension CloudKitRecordSyncManager {
    func syncEngineInstance(expectedGeneration: UInt64? = nil) throws -> CKSyncEngine {
        stateLock.lock()
        if let expectedGeneration, expectedGeneration != engineGeneration {
            stateLock.unlock()
            throw CancellationError()
        }
        if let syncEngine {
            stateLock.unlock()
            return syncEngine
        }
        let generation = engineGeneration
        stateLock.unlock()

        let stateSerialization = try loadSyncEngineStateSerialization()
        var configuration = CKSyncEngine.Configuration(
            database: client.database,
            stateSerialization: stateSerialization,
            delegate: self
        )
        configuration.automaticallySync = false
        let engine = CKSyncEngine(configuration)

        stateLock.lock()
        guard generation == engineGeneration,
              expectedGeneration == nil || expectedGeneration == generation else {
            stateLock.unlock()
            throw CancellationError()
        }
        if let existingEngine = syncEngine {
            stateLock.unlock()
            return existingEngine
        }
        syncEngine = engine
        stateLock.unlock()
        return engine
    }

    func isCurrentSyncEngine(_ engine: CKSyncEngine) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return syncEngine === engine
    }

    func hasActiveSyncEngine() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return syncEngine != nil
    }

    func loadSyncEngineStateSerialization() throws -> CKSyncEngine.State.Serialization? {
        var serialization: CKSyncEngine.State.Serialization?
        try AppDatabase.shared.dbWriter?.read { db in
            serialization = try CloudKitSyncState.syncEngineStateSerialization(in: db)
        }
        return serialization
    }

    func hasStoredSyncEngineState() throws -> Bool {
        try loadSyncEngineStateSerialization() != nil
    }

    func freshEngineMode(hasStoredEngineState: Bool) throws -> FreshEngineMode {
        guard !hasStoredEngineState else {
            return FreshEngineMode(bootstrapsLocalRecords: false, prunesMissingLocalRecords: false)
        }
        var suppressesBootstrap = false
        var preservesLocalRecords = false
        var probesZoneDiscontinuity = false
        _ = try AppDatabase.shared.dbWriter?.write { db in
            // The probe flag is read, not consumed: it's cleared atomically inside
            // the apply transaction together with the keep-vs-prune outcome, so a
            // crash between fetch and apply simply probes again.
            probesZoneDiscontinuity = try CloudKitSyncState.isZoneDiscontinuityProbePending(in: db)
            guard !probesZoneDiscontinuity else { return }
            suppressesBootstrap = try CloudKitSyncState.consumeBootstrapSuppression(in: db)
            preservesLocalRecords = try CloudKitSyncState.consumeLocalRecordPreservation(in: db)
        }
        if probesZoneDiscontinuity {
            return FreshEngineMode(
                bootstrapsLocalRecords: false,
                prunesMissingLocalRecords: false,
                probesZoneDiscontinuity: true
            )
        }
        let bootstrapsLocalRecords = preservesLocalRecords || (!suppressesBootstrap && !CloudKitSync.remoteDataMayExist)
        // Prune local-only records on a fresh full fetch unless we're explicitly
        // bootstrapping (uploading local) or preserving (rebuild path). When the
        // remote zone is canonical we want stale local records to disappear.
        return FreshEngineMode(
            bootstrapsLocalRecords: bootstrapsLocalRecords,
            prunesMissingLocalRecords: !bootstrapsLocalRecords && !preservesLocalRecords
        )
    }

    func persistSyncEngineStateSerialization(_ serialization: CKSyncEngine.State.Serialization) throws {
        _ = try AppDatabase.shared.dbWriter?.write { db in
            try CloudKitSyncState.setSyncEngineStateSerialization(serialization, in: db)
        }
    }

    func resetSyncEngineStateForFullFetch(suppressesBootstrap: Bool, preservesLocalRecords: Bool = false) throws {
        try resetSyncEngineState { db in
            if suppressesBootstrap {
                try CloudKitSyncState.suppressBootstrapForNextFreshEngine(in: db)
            } else {
                try CloudKitSyncState.clearBootstrapSuppression(in: db)
            }
            if preservesLocalRecords {
                try CloudKitSyncState.preserveLocalRecordsForNextFullFetch(in: db)
            } else {
                try CloudKitSyncState.clearLocalRecordPreservation(in: db)
            }
            try CloudKitSyncState.clearZoneDiscontinuityProbe(in: db)
        }
    }

    /// The zone disappeared (deleted by a peer, zoneNotFound, expired change
    /// token). Whether the local data should be kept (accidental loss → merge)
    /// or pruned (a peer deliberately rebuilt → adopt its snapshot) can only be
    /// decided once the next full fetch reveals the zone's reset marker, so
    /// just flag the probe here.
    func resetSyncEngineStateForZoneDiscontinuity() throws {
        try resetSyncEngineState { db in
            try CloudKitSyncState.markZoneDiscontinuityProbe(in: db)
            try CloudKitSyncState.clearBootstrapSuppression(in: db)
            try CloudKitSyncState.clearLocalRecordPreservation(in: db)
        }
    }

    /// Drops the in-memory engine (and any deferred fetch state) so the next
    /// pass rebuilds it from the last persisted state token and CloudKit
    /// re-delivers everything after that point. Disk-side flags are untouched:
    /// a pending discontinuity probe stays pending.
    func invalidateSyncEngineForRedelivery() {
        stateLock.lock()
        engineGeneration += 1
        syncEngine = nil
        fetchAccumulator = nil
        pendingFetchStateSerialization = nil
        serverRecordCacheByRecordName.removeAll()
        stateLock.unlock()
    }

    private func resetSyncEngineState(flags: (Database) throws -> Void) throws {
        stateLock.lock()
        engineGeneration += 1
        syncEngine = nil
        fetchAccumulator = nil
        pendingFetchStateSerialization = nil
        serverRecordCacheByRecordName.removeAll()
        needsFullFetchAfterCurrentSync = false
        didEnsureRecordZone = false
        stateLock.unlock()

        _ = try AppDatabase.shared.dbWriter?.write { db in
            try CloudKitSyncState.clearSyncEngineStateSerialization(in: db)
            try flags(db)
        }
    }

    func resetForRequestedFullFetchIfNeeded() throws -> Bool {
        guard takeNeedsFullFetchAfterCurrentSync() else { return false }
        try resetSyncEngineStateForFullFetch(suppressesBootstrap: true)
        requestFollowUpSync()
        CloudKitSync.setLastError(String(localized: "settings.cloudKitSync.error.fullRefresh"))
        return true
    }

    func beginFetchAccumulation(isFullSnapshot: Bool, prunesMissingLocalRecords: Bool, probesZoneDiscontinuity: Bool) {
        stateLock.lock()
        fetchAccumulator = FetchAccumulator(
            isFullSnapshot: isFullSnapshot,
            prunesMissingLocalRecords: prunesMissingLocalRecords,
            probesZoneDiscontinuity: probesZoneDiscontinuity
        )
        stateLock.unlock()
    }

    func discardFetchAccumulation() {
        stateLock.lock()
        fetchAccumulator = nil
        pendingFetchStateSerialization = nil
        stateLock.unlock()
    }

    func appendFetchedRecordZoneChanges(_ changes: CKSyncEngine.Event.FetchedRecordZoneChanges) {
        let changedRecords = changes.modifications
            .map(\.record)
            .filter { $0.recordID.zoneID == CloudKitRecordName.zoneID }
        let physicalDeletedRecords = changes.deletions
            .filter { $0.recordID.zoneID == CloudKitRecordName.zoneID }
            .map {
                PhysicalDeletedRecord(
                    recordName: $0.recordID.recordName,
                    recordType: CloudKitRecordType(rawValue: $0.recordType)
                )
            }

        stateLock.lock()
        if fetchAccumulator == nil {
            fetchAccumulator = FetchAccumulator(isFullSnapshot: false, prunesMissingLocalRecords: false)
        }
        fetchAccumulator?.changedRecords.append(contentsOf: changedRecords)
        fetchAccumulator?.physicalDeletedRecords.append(contentsOf: physicalDeletedRecords)
        stateLock.unlock()
    }

    func takeFetchAccumulator() -> FetchAccumulator? {
        stateLock.lock()
        let accumulator = fetchAccumulator
        fetchAccumulator = nil
        stateLock.unlock()
        return accumulator
    }

    /// Take both the accumulator and the pending state token under a single lock.
    /// Splitting them lets a `.stateUpdate` event sneak in between the two takes,
    /// flip out of accumulator-mode and persist its newer state to disk while we
    /// still hold the older value in memory — which would then overwrite it.
    func takeFetchAccumulatorAndPendingState() -> (FetchAccumulator?, CKSyncEngine.State.Serialization?) {
        stateLock.lock()
        let accumulator = fetchAccumulator
        let serialization = pendingFetchStateSerialization
        fetchAccumulator = nil
        pendingFetchStateSerialization = nil
        stateLock.unlock()
        return (accumulator, serialization)
    }

    func isAccumulatingFetch() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return fetchAccumulator != nil
    }

    /// Defer .stateUpdate writes for the entire fetch lifecycle: accumulation, the
    /// subsequent apply window, AND any time a full-fetch reset is queued. The reset
    /// flag covers the unexplained-physical-delete branch (which sets it before
    /// applyRemoteChanges ever runs) plus the window between apply finishing and
    /// resetForRequestedFullFetchIfNeeded clearing the disk token. Without this we'd
    /// risk persisting a state token past records that need re-delivery.
    func shouldDeferStateUpdates() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return fetchAccumulator != nil
            || isApplyingRemoteChanges
            || needsFullFetchAfterCurrentSync
    }

    func setPendingFetchStateSerialization(_ serialization: CKSyncEngine.State.Serialization) {
        stateLock.lock()
        pendingFetchStateSerialization = serialization
        stateLock.unlock()
    }

    func takePendingFetchStateSerialization() -> CKSyncEngine.State.Serialization? {
        stateLock.lock()
        let serialization = pendingFetchStateSerialization
        pendingFetchStateSerialization = nil
        stateLock.unlock()
        return serialization
    }

    func applyAccumulatedFetchIfNeeded() throws {
        let (maybeAccumulator, pendingState) = takeFetchAccumulatorAndPendingState()
        guard let accumulator = maybeAccumulator else {
            if let pendingState {
                try persistSyncEngineStateSerialization(pendingState)
            }
            return
        }
        let remoteChanges = makeRemoteChangeSet(
            changedRecords: accumulator.changedRecords,
            physicalDeletedRecords: accumulator.physicalDeletedRecords
        )

        if !accumulator.isFullSnapshot, remoteChanges.hasUnexplainedPhysicalDeletes {
            if let pendingState {
                setPendingFetchStateSerialization(pendingState)
            }
            requestFullFetchAfterCurrentSync()
            return
        }

        setApplyingRemoteChanges(true)
        defer { setApplyingRemoteChanges(false) }
        do {
            try applyRemoteChanges(
                remoteChanges,
                missingDependenciesAreOrphans: accumulator.isFullSnapshot,
                prunesMissingLocalRecords: accumulator.isFullSnapshot && accumulator.prunesMissingLocalRecords,
                probesZoneDiscontinuity: accumulator.isFullSnapshot && accumulator.probesZoneDiscontinuity,
                pendingStateSerialization: pendingState
            )
            // Drain anything a late .stateUpdate dropped into the pending slot while
            // apply was running. If apply requested a full fetch, discard — reset will
            // wipe disk state anyway. Otherwise persist; it's monotonically newer than
            // what apply just wrote inside its txn.
            if let lateState = takePendingFetchStateSerialization(),
               !needsFullFetchAfterCurrentSyncIsRequested() {
                try persistSyncEngineStateSerialization(lateState)
            }
        } catch {
            // The accumulated records are lost (applyRemoteChanges threw before or
            // inside its transaction) while the engine's in-memory token already
            // moved past them. Persisting the held state token later would skip
            // them forever — drop the engine instead, so the next pass rebuilds
            // it from the last persisted token and CloudKit re-delivers
            // everything since (re-applies are version-guarded, so harmless).
            invalidateSyncEngineForRedelivery()
            throw error
        }
    }


    func requestFullFetchAfterCurrentSync() {
        stateLock.lock()
        needsFullFetchAfterCurrentSync = true
        stateLock.unlock()
    }

    func takeNeedsFullFetchAfterCurrentSync() -> Bool {
        stateLock.lock()
        let value = needsFullFetchAfterCurrentSync
        needsFullFetchAfterCurrentSync = false
        stateLock.unlock()
        return value
    }

    func needsFullFetchAfterCurrentSyncIsRequested() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return needsFullFetchAfterCurrentSync
    }

    func validateLocalCloudKitSnapshotForRebuild() throws {
        try AppDatabase.shared.dbWriter?.read { db in
            if let syncId = try String.fetchOne(
                db,
                sql: """
                    SELECT text.sync_id
                    FROM text
                    LEFT JOIN post ON post.id = text.post_id
                    WHERE post.id IS NULL
                    LIMIT 1
                """
            ) {
                throw CloudKitOutboxBuildError(recordName: CloudKitRecordName.make(.text, syncId: syncId), reason: "parent post is missing")
            }
            if let syncId = try String.fetchOne(
                db,
                sql: """
                    SELECT image.sync_id
                    FROM image
                    LEFT JOIN post ON post.id = image.post_id
                    WHERE post.id IS NULL
                    LIMIT 1
                """
            ) {
                throw CloudKitOutboxBuildError(recordName: CloudKitRecordName.make(.image, syncId: syncId), reason: "parent post is missing")
            }
            for image in try PostImage.fetchAll(db) {
                guard ImageCacheManager.shared.getURL(name: image.original, type: .original) != nil,
                      ImageCacheManager.shared.getURL(name: image.processed, type: .processed) != nil else {
                    throw CloudKitOutboxBuildError(recordName: image.cloudKitRecordName, reason: "cached image files are missing")
                }
            }
            if let syncId = try String.fetchOne(
                db,
                sql: """
                    SELECT decoration.sync_id
                    FROM decoration
                    LEFT JOIN post ON post.id = decoration.post_id
                    WHERE post.id IS NULL
                    LIMIT 1
                """
            ) {
                throw CloudKitOutboxBuildError(recordName: CloudKitRecordName.make(.decoration, syncId: syncId), reason: "parent post is missing")
            }
            if let syncId = try String.fetchOne(
                db,
                sql: """
                    SELECT decoration.sync_id
                    FROM decoration
                    LEFT JOIN style ON style.id = decoration.style_id
                    WHERE style.id IS NULL
                    LIMIT 1
                """
            ) {
                throw CloudKitOutboxBuildError(recordName: CloudKitRecordName.make(.decoration, syncId: syncId), reason: "style is missing")
            }
        }
    }

    func cleanupLocalCloudKitOrphans() throws {
        var deletedImageFiles: [(String, CacheImageType)] = []
        var didChangeDatabase = false
        _ = try AppDatabase.shared.dbWriter?.write { db in
            for text in try PostText.fetchAll(db) {
                guard try Post.fetchOne(db, id: text.postId) == nil else { continue }
                try enqueueCloudKitDeleteIfNeeded(recordType: .text, syncId: text.syncId, deletionTime: text.modificationTime ?? db.transactionDate.nanoSecondSince1970, in: db)
                if let textId = text.id {
                    try PostText.deleteAll(db, ids: [textId])
                }
                try OnboardingLocalRecord.unmark(recordType: .text, syncId: text.syncId, in: db)
                didChangeDatabase = true
            }

            for image in try PostImage.fetchAll(db) {
                guard try Post.fetchOne(db, id: image.postId) == nil else { continue }
                try enqueueCloudKitDeleteIfNeeded(recordType: .image, syncId: image.syncId, deletionTime: image.modificationTime ?? db.transactionDate.nanoSecondSince1970, in: db)
                if let imageId = image.id {
                    try PostImage.deleteAll(db, ids: [imageId])
                }
                try OnboardingLocalRecord.unmark(recordType: .image, syncId: image.syncId, in: db)
                deletedImageFiles.append(contentsOf: imageFiles(for: [image]))
                didChangeDatabase = true
            }

            for decoration in try PostDecoration.fetchAll(db) {
                let hasPost = try Post.fetchOne(db, id: decoration.postId) != nil
                let hasStyle = try PostStyle.fetchOne(db, id: decoration.styleId) != nil
                guard !hasPost || !hasStyle else { continue }
                try enqueueCloudKitDeleteIfNeeded(recordType: .decoration, syncId: decoration.syncId, deletionTime: decoration.modificationTime ?? db.transactionDate.nanoSecondSince1970, in: db)
                if let decorationId = decoration.id {
                    try PostDecoration.deleteAll(db, ids: [decorationId])
                }
                try OnboardingLocalRecord.unmark(recordType: .decoration, syncId: decoration.syncId, in: db)
                didChangeDatabase = true
            }
        }

        cleanupCopiedImageFiles(deletedImageFiles)
        if didChangeDatabase {
            postCloudKitOriginatedUpdate(.DatabaseUpdated)
        }
    }

    func rebuildLocalCloudKitStateForCurrentDevice() throws {
        let defaultStyleSyncId = DataManager.shared.fetchStyle(by: Int64(DefaultStyle.getValue().rawValue))?.syncId
        stateLock.lock()
        engineGeneration += 1
        syncEngine = nil
        fetchAccumulator = nil
        pendingFetchStateSerialization = nil
        serverRecordCacheByRecordName.removeAll()
        needsFullFetchAfterCurrentSync = false
        stateLock.unlock()
        _ = try AppDatabase.shared.dbWriter?.write { db in
            try CloudKitSyncState.clearSyncEngineStateSerialization(in: db)
            try CloudKitSyncState.clearBootstrapSuppression(in: db)
            try CloudKitSyncState.clearLocalRecordPreservation(in: db)
            try CloudKitSyncState.clearZoneDiscontinuityProbe(in: db)
            try CloudKitLocalTombstone.deleteAll(db)
            try CloudKitOutboxEntry.deleteAll(db)
            try CloudKitRecordMetadata.deleteAll(db)
            try CloudKitSettingRecord.deleteAll(db)
            try CloudKitOutboxEntry.enqueueBootstrapSaves(in: db)
            try enqueueDefaultStyleSettingIfNeeded(syncId: defaultStyleSyncId, in: db)
        }
        // This rebuild wipe is a superset of the disable-time cleanup.
        CloudKitSync.setPendingDisableCleanup(false)
    }

    func sendChangesAndCleanupUploadAssets(_ engine: CKSyncEngine) async throws {
        // Per-record cleanup runs in handleSentRecordZoneChanges; this drains anything
        // left behind when sendChanges throws or completes without acking every entry.
        defer { cleanupAllUploadAssetFiles() }
        try await engine.sendChanges()
    }

    func enqueueBootstrapOutbox() throws {
        let defaultStyleSyncId = DefaultStyle.currentStyleSyncIdForCloudKit()
        _ = try AppDatabase.shared.dbWriter?.write { db in
            try CloudKitOutboxEntry.enqueueBootstrapSaves(in: db)
            try enqueueDefaultStyleSettingIfNeeded(syncId: defaultStyleSyncId, in: db)
        }
    }

    /// Re-enable scenario: previous sync left CloudKit metadata behind, but local
    /// edits during the disabled period weren't tracked. Catch up the outbox before
    /// the first fetch so remote-wins-on-pull doesn't overwrite divergent local data.
    func enqueueOfflineReconciliationOutbox() throws {
        // Read the actual local UserDefaults selection, not currentStyleSyncIdForCloudKit
        // which would prefer the (potentially stale) CloudKitSettingRecord when remote
        // DataMayExist is true. During the disabled period the user may have changed
        // default style locally and that change must propagate.
        let defaultStyleSyncId = DataManager.shared.fetchStyle(by: Int64(DefaultStyle.getValue().rawValue))?.syncId
        _ = try AppDatabase.shared.dbWriter?.write { db in
            try CloudKitOutboxEntry.enqueueOfflineReconciliation(in: db)
            try enqueueDefaultStyleSettingIfNeeded(syncId: defaultStyleSyncId, in: db)
        }
    }

    func enqueueDefaultStyleSettingIfNeeded(syncId: String?, in db: Database) throws {
        guard let syncId,
              try !OnboardingLocalRecord.isMarked(recordType: .style, syncId: syncId, in: db) else {
            return
        }
        let setting = try CloudKitSettingRecord.current(in: db)
        let modificationTime: Int64
        if setting.defaultStyleSyncId == syncId, setting.defaultStyleModificationTime > 0 {
            modificationTime = setting.defaultStyleModificationTime
        } else {
            // Prefer the locally-tracked change time (written even when sync is off)
            // so an offline default-style swap doesn't get re-stamped with the moment
            // of re-enable, which would silently overwrite a newer remote setting.
            // No recorded change at all means the user never explicitly picked a
            // default (legacy-upgrade fallback selection) — don't push an implicit
            // choice with a fresh timestamp over a peer's explicit one.
            let localChange = CloudKitSync.defaultStyleLocalModificationTime
            guard localChange > 0 else { return }
            modificationTime = localChange
        }
        try CloudKitSettingRecord.saveDefaultStyle(syncId: syncId, modificationTime: modificationTime, in: db)
        try CloudKitOutboxEntry.enqueueSetting(modificationTime: modificationTime, in: db)
    }

    func loadOutboxEntries() throws -> [CloudKitOutboxEntry] {
        var entries: [CloudKitOutboxEntry] = []
        try AppDatabase.shared.dbWriter?.read { db in
            entries = try CloudKitOutboxEntry
                .order(CloudKitOutboxEntry.Columns.updatedAt.asc, Column(CloudKitOutboxEntry.CodingKeys.id).asc)
                .fetchAll(db)
        }
        return entries
    }

    func hasOutboxFailures() throws -> Bool {
        var hasFailures = false
        try AppDatabase.shared.dbWriter?.read { db in
            hasFailures = try CloudKitOutboxEntry.failedCount(in: db) > 0
        }
        return hasFailures
    }

    func markRemoteDataMayExistBeforeSendingOutboxIfNeeded() throws {
        var hasOutbox = false
        try AppDatabase.shared.dbWriter?.read { db in
            hasOutbox = try CloudKitOutboxEntry.fetchCount(db) > 0
        }
        if hasOutbox {
            CloudKitSync.markRemoteDataMayExist()
        }
    }

    func markRemoteDataMayExistIfCloudKitStateExists() throws {
        var hasState = false
        try AppDatabase.shared.dbWriter?.read { db in
            let hasOutbox = try CloudKitOutboxEntry.fetchCount(db) > 0
            let hasMetadata = try CloudKitRecordMetadata.fetchCount(db) > 0
            hasState = hasOutbox || hasMetadata
        }
        if hasState {
            CloudKitSync.markRemoteDataMayExist()
        } else {
            CloudKitSync.clearRemoteDataMayExist()
        }
    }

    func enqueueExpiredTombstonePurgesIfNeeded() throws -> Bool {
        var didEnqueue = false
        let cutoff = Date().nanoSecondSince1970 - Self.tombstoneRetentionMilliseconds
        _ = try AppDatabase.shared.dbWriter?.write { db in
            let tombstones = try Row.fetchAll(
                db,
                sql: """
                    SELECT record_name, record_type
                    FROM cloudkit_record_metadata
                    WHERE is_deleted = 1
                      AND updated_at <= ?
                      AND NOT EXISTS (
                          SELECT 1
                          FROM cloudkit_outbox
                          WHERE cloudkit_outbox.record_name = cloudkit_record_metadata.record_name
                      )
                """,
                arguments: [cutoff]
            )

            for tombstone in tombstones {
                let recordName: String = tombstone["record_name"]
                let rawRecordType: String = tombstone["record_type"]
                guard let recordType = CloudKitRecordType(rawValue: rawRecordType) else { continue }
                try CloudKitOutboxEntry.enqueuePurge(
                    recordType: recordType,
                    recordName: recordName,
                    in: db
                )
                didEnqueue = true
            }
        }
        return didEnqueue
    }

    func syncEnginePendingChangesFromOutbox(_ engine: CKSyncEngine) throws {
        let desiredChanges = Set(try loadOutboxEntries().flatMap { pendingRecordZoneChanges(for: $0) })
        let currentChanges = Set(engine.state.pendingRecordZoneChanges.filter(isManagedRecordZoneChange))
        let staleChanges = currentChanges.subtracting(desiredChanges)
        let newChanges = desiredChanges.subtracting(currentChanges)

        if !staleChanges.isEmpty {
            engine.state.remove(pendingRecordZoneChanges: Array(staleChanges))
        }
        if !newChanges.isEmpty {
            engine.state.add(pendingRecordZoneChanges: Array(newChanges))
        }
    }

    func pendingRecordZoneChanges(for entry: CloudKitOutboxEntry) -> [CKSyncEngine.PendingRecordZoneChange] {
        guard let operation = entry.cloudKitOperation else { return [] }
        let recordID = CloudKitRecordName.recordID(entry.recordName)
        switch operation {
        case .save:
            return [.saveRecord(recordID)]
        case .delete:
            return [.saveRecord(recordID)]
        case .purge:
            return [.deleteRecord(recordID)]
        }
    }

    func isManagedRecordZoneChange(_ change: CKSyncEngine.PendingRecordZoneChange) -> Bool {
        recordID(for: change)?.zoneID == CloudKitRecordName.zoneID
    }

    func recordID(for change: CKSyncEngine.PendingRecordZoneChange) -> CKRecord.ID? {
        switch change {
        case .saveRecord(let recordID), .deleteRecord(let recordID):
            return recordID
        @unknown default:
            return nil
        }
    }

    func markOutboxFailures(_ failures: [(id: Int64, error: Error)]) throws {
        _ = try AppDatabase.shared.dbWriter?.write { db in
            for failure in failures {
                try CloudKitOutboxEntry.markFailed(ids: [failure.id], error: failure.error, in: db)
            }
        }
    }

    func clearOutbox(ids: [Int64]) throws {
        var recordNames: [String] = []
        _ = try AppDatabase.shared.dbWriter?.write { db in
            recordNames = try CloudKitOutboxEntry.filter(ids: ids).fetchAll(db).map(\.recordName)
            try CloudKitOutboxEntry.clear(ids: ids, in: db)
        }
        evictCachedServerRecords(for: recordNames)
    }

    func dropOutbox(ids: [Int64]) throws {
        var recordNames: [String] = []
        _ = try AppDatabase.shared.dbWriter?.write { db in
            recordNames = try CloudKitOutboxEntry.filter(ids: ids).fetchAll(db).map(\.recordName)
            try CloudKitOutboxEntry.drop(ids: ids, in: db)
        }
        evictCachedServerRecords(for: recordNames)
    }

    func evictCachedServerRecords(for recordNames: [String]) {
        guard !recordNames.isEmpty else { return }
        stateLock.lock()
        for name in recordNames {
            serverRecordCacheByRecordName.removeValue(forKey: name)
        }
        stateLock.unlock()
    }

    func fetchServerRecordState(for entries: [CloudKitOutboxEntry]) async throws -> ServerRecordState {
        let allRecordNames = Set(entries.map(\.recordName))
        let cachedRecords = consumeCachedServerRecords(for: allRecordNames)
        let uncachedRecordNames = allRecordNames.subtracting(cachedRecords.keys)
        let uncachedRecordIDs = uncachedRecordNames.map { CloudKitRecordName.recordID($0) }
        var recordsByName: [String: CKRecord] = cachedRecords
        if !uncachedRecordIDs.isEmpty {
            let fetched = try await fetchRecords(recordIDs: uncachedRecordIDs)
            recordsByName.merge(fetched) { _, new in new }
        }
        var activeRecordsByRecordName: [String: CKRecord] = [:]
        var tombstonesByDeletedRecordName: [String: RemoteTombstone] = [:]
        for record in recordsByName.values {
            guard let type = CloudKitRecordType(rawValue: record.recordType) else { continue }
            if isDeletedRecord(record),
               let tombstone = makeRemoteTombstone(from: record, type: type) {
                tombstonesByDeletedRecordName[tombstone.deletedRecordName] = tombstone
            } else {
                activeRecordsByRecordName[record.recordID.recordName] = record
            }
        }
        return ServerRecordState(
            recordsByRecordName: recordsByName,
            activeRecordsByRecordName: activeRecordsByRecordName,
            tombstonesByDeletedRecordName: tombstonesByDeletedRecordName
        )
    }

    func cacheServerRecord(_ record: CKRecord) {
        stateLock.lock()
        serverRecordCacheByRecordName[record.recordID.recordName] = record
        stateLock.unlock()
    }

    func evictCachedServerRecord(recordName: String) {
        stateLock.lock()
        serverRecordCacheByRecordName.removeValue(forKey: recordName)
        stateLock.unlock()
    }

    /// Read-and-remove the cached server records for the given names. The cache is
    /// populated by serverRecordChanged failures and consumed once by the next batch
    /// attempt; if that attempt fails again, the new error repopulates the cache.
    func consumeCachedServerRecords(for recordNames: Set<String>) -> [String: CKRecord] {
        stateLock.lock()
        defer { stateLock.unlock() }
        var result: [String: CKRecord] = [:]
        for name in recordNames {
            if let record = serverRecordCacheByRecordName.removeValue(forKey: name) {
                result[name] = record
            }
        }
        return result
    }

    func fetchRecords(recordIDs: [CKRecord.ID]) async throws -> [String: CKRecord] {
        try ensureSyncEnabled()
        return try await withCheckedThrowingContinuation { continuation in
            final class RecordBox {
                private let lock = NSLock()
                private var recordsByName: [String: CKRecord] = [:]
                private var firstError: Error?

                func store(recordID: CKRecord.ID, result: Result<CKRecord, Error>, recordNotFoundIsSuccess: (Error) -> Bool) {
                    lock.lock()
                    defer { lock.unlock() }
                    switch result {
                    case .success(let record):
                        recordsByName[recordID.recordName] = record
                    case .failure(let error):
                        if !recordNotFoundIsSuccess(error), firstError == nil {
                            firstError = error
                        }
                    }
                }

                func result() throws -> [String: CKRecord] {
                    lock.lock()
                    defer { lock.unlock() }
                    if let firstError {
                        throw firstError
                    }
                    return recordsByName
                }
            }

            let box = RecordBox()
            let operation = CKFetchRecordsOperation(recordIDs: recordIDs)
            operation.desiredKeys = [
                Field.modificationTime,
                Field.isDeleted,
                Field.deletedRecordType,
                Field.deletedRecordName,
                Field.deletionTime
            ]
            operation.perRecordResultBlock = { recordID, result in
                box.store(recordID: recordID, result: result, recordNotFoundIsSuccess: self.isRecordNotFound)
            }
            operation.fetchRecordsResultBlock = { result in
                switch result {
                case .success:
                    do {
                        continuation.resume(returning: try box.result())
                    } catch {
                        continuation.resume(throwing: error)
                    }
                case .failure(let error):
                    if self.isPartialFailure(error) {
                        do {
                            continuation.resume(returning: try box.result())
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    } else {
                        continuation.resume(throwing: error)
                    }
                }
            }
            addOperation(operation)
        }
    }

    func serverStateWins(
        entry: CloudKitOutboxEntry,
        operation: CloudKitOutboxEntry.Operation,
        against serverRecordState: ServerRecordState
    ) -> Bool {
        let recordName = entry.recordName
        let entryModificationTime = entry.modificationTime
        switch operation {
        case .delete, .purge:
            // Local deletes proceed against an older server state OR a server tombstone
            // (where merging is a no-op). A NEWER active server record means another
            // device updated this record after our delete was queued — let server win
            // so we don't tombstone newer data.
            if let serverRecord = serverRecordState.activeRecordsByRecordName[recordName],
               modificationTime(of: serverRecord) > entryModificationTime {
                return true
            }
            return false
        case .save:
            // Server-equal-time wins so a simultaneous remote delete isn't overwritten.
            if let tombstone = serverRecordState.tombstonesByDeletedRecordName[recordName],
               tombstone.deletionTime >= entryModificationTime {
                return true
            }
            guard let serverRecord = serverRecordState.activeRecordsByRecordName[recordName] else { return false }
            return modificationTime(of: serverRecord) > entryModificationTime
        }
    }
}

extension CloudKitRecordSyncManager {
    func makeRecord(
        for entry: CloudKitOutboxEntry,
        type: CloudKitRecordType,
        baseRecord: CKRecord?
    ) throws -> CKRecord? {
        switch type {
        case .post:
            guard let syncId = CloudKitRecordName.syncId(from: entry.recordName, type: .post) else { return nil }
            var post: Post?
            try AppDatabase.shared.dbWriter?.read { db in
                post = try Post
                    .filter(Column(Post.CodingKeys.syncId) == syncId)
                    .fetchOne(db)
            }
            guard let post else { return nil }
            return makeRecord(for: post, baseRecord: baseRecord)
        case .text:
            guard let syncId = CloudKitRecordName.syncId(from: entry.recordName, type: .text) else { return nil }
            var text: PostText?
            var postSyncId: String?
            try AppDatabase.shared.dbWriter?.read { db in
                text = try PostText
                    .filter(Column(PostText.CodingKeys.syncId) == syncId)
                    .fetchOne(db)
                if let text {
                    guard let post = try Post.fetchOne(db, id: text.postId) else {
                        throw CloudKitOutboxBuildError(recordName: entry.recordName, reason: "parent post is missing")
                    }
                    postSyncId = post.syncId
                }
            }
            guard let text, let postSyncId else { return nil }
            return makeRecord(for: text, postSyncId: postSyncId, baseRecord: baseRecord)
        case .image:
            guard let syncId = CloudKitRecordName.syncId(from: entry.recordName, type: .image) else { return nil }
            var image: PostImage?
            var postSyncId: String?
            try AppDatabase.shared.dbWriter?.read { db in
                image = try PostImage
                    .filter(Column(PostImage.CodingKeys.syncId) == syncId)
                    .fetchOne(db)
                if let image {
                    guard let post = try Post.fetchOne(db, id: image.postId) else {
                        throw CloudKitOutboxBuildError(recordName: entry.recordName, reason: "parent post is missing")
                    }
                    postSyncId = post.syncId
                }
            }
            guard let image, let postSyncId else { return nil }
            return try makeRecord(for: image, postSyncId: postSyncId, baseRecord: baseRecord)
        case .style:
            guard let syncId = CloudKitRecordName.syncId(from: entry.recordName, type: .style) else { return nil }
            var style: PostStyle?
            try AppDatabase.shared.dbWriter?.read { db in
                style = try PostStyle
                    .filter(Column(PostStyle.CodingKeys.syncId) == syncId)
                    .fetchOne(db)
            }
            guard let style else { return nil }
            return makeRecord(for: style, baseRecord: baseRecord)
        case .decoration:
            guard let syncId = CloudKitRecordName.syncId(from: entry.recordName, type: .decoration) else { return nil }
            var decoration: PostDecoration?
            var postSyncId: String?
            var styleSyncId: String?
            try AppDatabase.shared.dbWriter?.read { db in
                decoration = try PostDecoration
                    .filter(Column(PostDecoration.CodingKeys.syncId) == syncId)
                    .fetchOne(db)
                if let decoration {
                    guard let post = try Post.fetchOne(db, id: decoration.postId) else {
                        throw CloudKitOutboxBuildError(recordName: entry.recordName, reason: "parent post is missing")
                    }
                    guard let style = try PostStyle.fetchOne(db, id: decoration.styleId) else {
                        throw CloudKitOutboxBuildError(recordName: entry.recordName, reason: "style is missing")
                    }
                    postSyncId = post.syncId
                    styleSyncId = style.syncId
                }
            }
            guard let decoration, let postSyncId, let styleSyncId else { return nil }
            return makeRecord(for: decoration, postSyncId: postSyncId, styleSyncId: styleSyncId, baseRecord: baseRecord)
        case .setting:
            var record: CKRecord?
            try AppDatabase.shared.dbWriter?.read { db in
                record = try makeSettingsRecord(baseRecord: baseRecord, in: db)
            }
            return record
        }
    }

    func cloudKitRecord(type: CloudKitRecordType, recordName: String, baseRecord: CKRecord?) -> CKRecord {
        let record: CKRecord
        if let baseRecord {
            record = baseRecord
        } else {
            record = CKRecord(recordType: type.rawValue, recordID: CloudKitRecordName.recordID(recordName))
        }
        clearDeletionState(on: record)
        return record
    }

    func makeRecord(for post: Post, baseRecord: CKRecord?) -> CKRecord {
        let record = cloudKitRecord(type: .post, recordName: post.cloudKitRecordName, baseRecord: baseRecord)
        set(post.syncId, for: Field.syncId, on: record)
        set(post.creationTime, for: Field.creationTime, on: record)
        set(post.modificationTime, for: Field.modificationTime, on: record)
        set(post.expirationTime, for: Field.expirationTime, on: record)
        set(post.actionLink, for: Field.actionLink, on: record)
        set(post.isPinned, for: Field.isPinned, on: record)
        set(post.order, for: Field.order, on: record)
        return record
    }

    func makeRecord(for text: PostText, postSyncId: String, baseRecord: CKRecord?) -> CKRecord {
        let record = cloudKitRecord(type: .text, recordName: text.cloudKitRecordName, baseRecord: baseRecord)
        set(text.syncId, for: Field.syncId, on: record)
        set(text.creationTime, for: Field.creationTime, on: record)
        set(text.modificationTime, for: Field.modificationTime, on: record)
        set(postSyncId, for: Field.postSyncId, on: record)
        set(text.content, for: Field.content, on: record)
        set(text.order, for: Field.order, on: record)
        return record
    }

    func makeRecord(for image: PostImage, postSyncId: String, baseRecord: CKRecord?) throws -> CKRecord {
        let originalURL = ImageCacheManager.shared.getURL(name: image.original, type: .original)
        let processedURL = ImageCacheManager.shared.getURL(name: image.processed, type: .processed)
        guard let originalURL, let processedURL else {
            throw CloudKitOutboxBuildError(recordName: image.cloudKitRecordName, reason: "cached image files are missing")
        }
        let uploadAssetFiles = try temporaryUploadAssetFiles(for: image, originalURL: originalURL, processedURL: processedURL)

        let record = cloudKitRecord(type: .image, recordName: image.cloudKitRecordName, baseRecord: baseRecord)
        set(image.syncId, for: Field.syncId, on: record)
        set(image.creationTime, for: Field.creationTime, on: record)
        set(image.modificationTime, for: Field.modificationTime, on: record)
        set(postSyncId, for: Field.postSyncId, on: record)
        set(image.original, for: Field.originalFileName, on: record)
        set(image.processed, for: Field.processedFileName, on: record)
        set(image.orientation, for: Field.orientation, on: record)
        set(image.minX, for: Field.minX, on: record)
        set(image.minY, for: Field.minY, on: record)
        set(image.maxX, for: Field.maxX, on: record)
        set(image.maxY, for: Field.maxY, on: record)
        set(image.order, for: Field.order, on: record)
        record[Field.originalAsset] = CKAsset(fileURL: uploadAssetFiles.original)
        record[Field.processedAsset] = CKAsset(fileURL: uploadAssetFiles.processed)
        registerUploadAssetFiles(recordName: image.cloudKitRecordName, urls: [uploadAssetFiles.original, uploadAssetFiles.processed])
        return record
    }

    func temporaryUploadAssetFiles(for image: PostImage, originalURL: URL, processedURL: URL) throws -> (original: URL, processed: URL) {
        var copiedURLs: [URL] = []
        do {
            let originalAssetURL = try temporaryUploadAssetFile(from: originalURL, preferredFileName: "\(image.syncId)-original")
            copiedURLs.append(originalAssetURL)
            let processedAssetURL = try temporaryUploadAssetFile(from: processedURL, preferredFileName: "\(image.syncId)-processed")
            copiedURLs.append(processedAssetURL)
            return (originalAssetURL, processedAssetURL)
        } catch {
            for url in copiedURLs {
                try? FileManager.default.removeItem(at: url)
            }
            throw error
        }
    }

    func temporaryUploadAssetFile(from sourceURL: URL, preferredFileName: String) throws -> URL {
        let directory = temporaryUploadAssetDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pathExtension = sourceURL.pathExtension
        let baseName = URL(fileURLWithPath: preferredFileName).lastPathComponent
        let fileName = pathExtension.isEmpty ? "\(baseName)-\(UUID().uuidString)" : "\(baseName)-\(UUID().uuidString).\(pathExtension)"
        let destinationURL = directory.appendingPathComponent(fileName)
        do {
            try FileManager.default.linkItem(at: sourceURL, to: destinationURL)
        } catch {
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        }
        return destinationURL
    }

    func temporaryUploadAssetDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PinItCloudKitUploadAssets", isDirectory: true)
    }

    func cleanupTemporaryUploadAssetDirectory() {
        try? FileManager.default.removeItem(at: temporaryUploadAssetDirectory())
    }

    func registerUploadAssetFiles(recordName: String, urls: [URL]) {
        stateLock.lock()
        uploadAssetFilesByRecordName[recordName, default: []].append(contentsOf: urls)
        stateLock.unlock()
    }

    func cleanupUploadAssetFiles(for recordNames: [String]) {
        guard !recordNames.isEmpty else { return }
        stateLock.lock()
        let urls = recordNames.flatMap { recordName in
            uploadAssetFilesByRecordName.removeValue(forKey: recordName) ?? []
        }
        stateLock.unlock()
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func cleanupAllUploadAssetFiles() {
        stateLock.lock()
        let urls = uploadAssetFilesByRecordName.values.flatMap { $0 }
        uploadAssetFilesByRecordName.removeAll()
        stateLock.unlock()
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func makeRecord(for style: PostStyle, baseRecord: CKRecord?) -> CKRecord {
        let record = cloudKitRecord(type: .style, recordName: style.cloudKitRecordName, baseRecord: baseRecord)
        set(style.syncId, for: Field.syncId, on: record)
        set(style.creationTime, for: Field.creationTime, on: record)
        set(style.modificationTime, for: Field.modificationTime, on: record)
        set(style.name, for: Field.name, on: record)
        set(style.lockBackgroundColor, for: Field.lockBackgroundColor, on: record)
        set(style.lockTextColor, for: Field.lockTextColor, on: record)
        set(Int64(style.lockTextSize.rawValue), for: Field.lockTextSize, on: record)
        set(Int64(style.lockTextAlignment.rawValue), for: Field.lockTextAlignment, on: record)
        set(style.islandTextColor, for: Field.islandTextColor, on: record)
        set(Int64(style.islandTextSize.rawValue), for: Field.islandTextSize, on: record)
        set(Int64(style.islandTextAlignment.rawValue), for: Field.islandTextAlignment, on: record)
        set(style.symbol, for: Field.symbol, on: record)
        set(style.symbolColor, for: Field.symbolColor, on: record)
        set(Int64(style.symbolAngle), for: Field.symbolAngle, on: record)
        set(Int64(style.imageDisplayMode.rawValue), for: Field.imageDisplayMode, on: record)
        set(Int64(style.controlAlpha), for: Field.controlAlpha, on: record)
        return record
    }

    func makeRecord(for decoration: PostDecoration, postSyncId: String, styleSyncId: String, baseRecord: CKRecord?) -> CKRecord {
        let record = cloudKitRecord(type: .decoration, recordName: decoration.cloudKitRecordName, baseRecord: baseRecord)
        set(decoration.syncId, for: Field.syncId, on: record)
        set(decoration.creationTime, for: Field.creationTime, on: record)
        set(decoration.modificationTime, for: Field.modificationTime, on: record)
        set(postSyncId, for: Field.postSyncId, on: record)
        set(styleSyncId, for: Field.styleSyncId, on: record)
        return record
    }

    func makeSettingsRecord(baseRecord: CKRecord?, in db: Database) throws -> CKRecord? {
        let setting = try CloudKitSettingRecord.current(in: db)
        if let defaultStyleSyncId = setting.defaultStyleSyncId {
            guard try !OnboardingLocalRecord.isMarked(recordType: .style, syncId: defaultStyleSyncId, in: db) else {
                return nil
            }
            let styleExists = try PostStyle
                .filter(Column(PostStyle.CodingKeys.syncId) == defaultStyleSyncId)
                .fetchCount(db) > 0
            guard styleExists else { return nil }
        }

        let record = cloudKitRecord(type: .setting, recordName: CloudKitRecordName.settingsName, baseRecord: baseRecord)
        set(setting.defaultStyleSyncId, for: Field.defaultStyleSyncId, on: record)
        set(setting.defaultStyleModificationTime, for: Field.modificationTime, on: record)
        return record
    }

    func makeDeletedRecord(for entry: CloudKitOutboxEntry, deletedRecordType: CloudKitRecordType, baseRecord: CKRecord?) -> CKRecord {
        let record = cloudKitRecord(type: deletedRecordType, recordName: entry.recordName, baseRecord: baseRecord)
        set(true, for: Field.isDeleted, on: record)
        set(CloudKitRecordName.syncId(from: entry.recordName, type: deletedRecordType), for: Field.syncId, on: record)
        set(deletedRecordType.rawValue, for: Field.deletedRecordType, on: record)
        set(entry.recordName, for: Field.deletedRecordName, on: record)
        set(entry.modificationTime, for: Field.deletionTime, on: record)
        set(entry.modificationTime, for: Field.modificationTime, on: record)
        clearPayloadFields(for: deletedRecordType, on: record)
        return record
    }

    func clearDeletionState(on record: CKRecord) {
        set(false, for: Field.isDeleted, on: record)
        record[Field.deletedRecordType] = nil
        record[Field.deletedRecordName] = nil
        record[Field.deletionTime] = nil
    }

    func clearPayloadFields(for type: CloudKitRecordType, on record: CKRecord) {
        switch type {
        case .post:
            record[Field.expirationTime] = nil
            record[Field.actionLink] = nil
            record[Field.isPinned] = nil
            record[Field.order] = nil
        case .text:
            record[Field.postSyncId] = nil
            record[Field.content] = nil
            record[Field.order] = nil
        case .image:
            record[Field.postSyncId] = nil
            record[Field.originalFileName] = nil
            record[Field.processedFileName] = nil
            record[Field.originalAsset] = nil
            record[Field.processedAsset] = nil
            record[Field.orientation] = nil
            record[Field.minX] = nil
            record[Field.minY] = nil
            record[Field.maxX] = nil
            record[Field.maxY] = nil
            record[Field.order] = nil
        case .style:
            record[Field.name] = nil
            record[Field.lockBackgroundColor] = nil
            record[Field.lockTextColor] = nil
            record[Field.lockTextSize] = nil
            record[Field.lockTextAlignment] = nil
            record[Field.islandTextColor] = nil
            record[Field.islandTextSize] = nil
            record[Field.islandTextAlignment] = nil
            record[Field.symbol] = nil
            record[Field.symbolColor] = nil
            record[Field.symbolAngle] = nil
            record[Field.imageDisplayMode] = nil
            record[Field.controlAlpha] = nil
        case .decoration:
            record[Field.postSyncId] = nil
            record[Field.styleSyncId] = nil
        case .setting:
            record[Field.defaultStyleSyncId] = nil
        }
    }
}

extension CloudKitRecordSyncManager {
    func applyRemoteChanges(
        _ changes: RemoteChangeSet,
        missingDependenciesAreOrphans: Bool,
        prunesMissingLocalRecords: Bool,
        probesZoneDiscontinuity: Bool = false,
        pendingStateSerialization: CKSyncEngine.State.Serialization? = nil
    ) throws {
        let imageRecordNamesToStage = try imageRecordNamesToStage(changes)
        var stagedImageAssets = try stageImageAssets(changes, allowedRecordNames: imageRecordNamesToStage)
        let allStagedImageFiles = stagedImageAssets.values.flatMap(\.copiedFiles)
        // Read outside the write transaction (goes through DataManager's reader).
        let probeDefaultStyleSyncId = probesZoneDiscontinuity
            ? DataManager.shared.fetchStyle(by: Int64(DefaultStyle.getValue().rawValue))?.syncId
            : nil
        var deletedImageFiles: [(String, CacheImageType)] = []
        var didChangeDatabase = false
        var didApplyRemoteUserContent = false
        var shouldRunOnboardingSetup = false
        var hasDeferredRemoteRecords = false
        var shouldPruneMissingLocalRecords = prunesMissingLocalRecords

        do {
            try AppDatabase.shared.dbWriter?.write { db in
                try ensureSyncEnabled()
                if probesZoneDiscontinuity {
                    let storedGeneration = try CloudKitSyncState.zoneGeneration(in: db)
                    if let fetchedGeneration = changes.zoneResetGeneration, fetchedGeneration != storedGeneration {
                        // A peer deliberately rebuilt the zone (reset/rebuild/clear):
                        // adopt its snapshot. Previously-synced records missing from
                        // it are pruned below; pending local changes survive via the
                        // outbox protections inside the prune. Divergent local edits
                        // (made while sync was off, or not yet pulled by the
                        // rebuilding peer) gain that protection here.
                        try CloudKitOutboxEntry.enqueueDivergentSaves(in: db)
                        shouldPruneMissingLocalRecords = true
                    } else {
                        // No marker (accidental zone loss, legacy zone) or unchanged
                        // generation (expired change token): keep local data and
                        // re-upload — the pre-marker merge behavior.
                        try CloudKitOutboxEntry.enqueueBootstrapSaves(in: db)
                        try enqueueDefaultStyleSettingIfNeeded(syncId: probeDefaultStyleSyncId, in: db)
                    }
                    try CloudKitSyncState.clearZoneDiscontinuityProbe(in: db)
                }
                if let fetchedGeneration = changes.zoneResetGeneration {
                    try CloudKitSyncState.setZoneGeneration(fetchedGeneration, in: db)
                }
                let pendingDeletes = try pendingDeleteOutboxByRecordName(in: db)
                let localTombstones = try CloudKitLocalTombstone.allByRecordName(in: db)
                // Tombstone-beats-remote-active should fire on every fetch, not only
                // pruning ones. activeRemoteRecords would otherwise filter out the
                // stale active record (because of the local tombstone) without ever
                // pushing the delete to CloudKit, leaving the stale record alive on
                // other devices.
                try enqueueDeletesForLocalTombstonesThatBeatActiveRemoteRecords(
                    changes,
                    pendingDeletes: pendingDeletes,
                    localTombstones: localTombstones,
                    in: db
                )
                let postIdBySyncIdBefore = try idMap(table: Post.databaseTableName, in: db)
                let styleIdBySyncIdBefore = try idMap(table: PostStyle.databaseTableName, in: db)
                let postModificationTimeBySyncIdBefore = try modificationTimeMap(table: Post.databaseTableName, in: db)
                let styleModificationTimeBySyncIdBefore = try modificationTimeMap(table: PostStyle.databaseTableName, in: db)

                for record in activeRemoteRecords(type: .style, changes: changes, pendingDeletes: pendingDeletes, localTombstones: localTombstones) {
                    try ensureSyncEnabled()
                    let didApply = try applyStyleRecord(record, in: db)
                    if didApply {
                        didChangeDatabase = true
                        didApplyRemoteUserContent = true
                    }
                    try clearOutboxIfRemoteWins(record, in: db)
                    try markServerRecordMetadata(record, type: .style, in: db)
                    try clearLocalTombstone(recordName: record.recordID.recordName, in: db)
                }
                for record in activeRemoteRecords(type: .post, changes: changes, pendingDeletes: pendingDeletes, localTombstones: localTombstones) {
                    try ensureSyncEnabled()
                    let didApply = try applyPostRecord(record, in: db)
                    if didApply {
                        didChangeDatabase = true
                        didApplyRemoteUserContent = true
                    }
                    try clearOutboxIfRemoteWins(record, in: db)
                    try markServerRecordMetadata(record, type: .post, in: db)
                    try clearLocalTombstone(recordName: record.recordID.recordName, in: db)
                }

                let postIdBySyncId = try idMap(table: Post.databaseTableName, in: db).merging(postIdBySyncIdBefore) { current, _ in current }
                let styleIdBySyncId = try idMap(table: PostStyle.databaseTableName, in: db).merging(styleIdBySyncIdBefore) { current, _ in current }
                let postModificationTimeBySyncId = try modificationTimeMap(table: Post.databaseTableName, in: db)
                    .merging(postModificationTimeBySyncIdBefore) { current, _ in current }
                let styleModificationTimeBySyncId = try modificationTimeMap(table: PostStyle.databaseTableName, in: db)
                    .merging(styleModificationTimeBySyncIdBefore) { current, _ in current }

                for record in activeRemoteRecords(type: .text, changes: changes, pendingDeletes: pendingDeletes, localTombstones: localTombstones) {
                    try ensureSyncEnabled()
                    let textApply = try applyTextRecord(
                        record,
                        postIdBySyncId: postIdBySyncId,
                        postModificationTimeBySyncId: postModificationTimeBySyncId,
                        changes: changes,
                        localTombstones: localTombstones,
                        missingDependenciesAreOrphans: missingDependenciesAreOrphans,
                        in: db
                    )
                    if textApply.isDeferred {
                        hasDeferredRemoteRecords = true
                    }
                    if textApply.didChangeDatabase {
                        didChangeDatabase = true
                        didApplyRemoteUserContent = true
                    }
                    if !textApply.isDeferred {
                        try clearOutboxIfRemoteWins(record, in: db)
                        try markServerRecordMetadata(record, type: .text, in: db)
                        try clearLocalTombstone(recordName: record.recordID.recordName, in: db)
                    }
                    deletedImageFiles.append(contentsOf: textApply.deletedImageFiles)
                }
                for record in activeRemoteRecords(type: .image, changes: changes, pendingDeletes: pendingDeletes, localTombstones: localTombstones) {
                    try ensureSyncEnabled()
                    let imageApply = try applyImageRecord(
                        record,
                        postIdBySyncId: postIdBySyncId,
                        postModificationTimeBySyncId: postModificationTimeBySyncId,
                        changes: changes,
                        localTombstones: localTombstones,
                        missingDependenciesAreOrphans: missingDependenciesAreOrphans,
                        stagedAssets: stagedImageAssets[record.recordID.recordName],
                        in: db
                    )
                    if imageApply.isDeferred {
                        hasDeferredRemoteRecords = true
                    }
                    if imageApply.didChangeDatabase {
                        didChangeDatabase = true
                        didApplyRemoteUserContent = true
                        stagedImageAssets.removeValue(forKey: record.recordID.recordName)
                    }
                    if !imageApply.isDeferred {
                        // LWW arbitration applies even when the record couldn't be
                        // applied for missing assets: a judged-loser local intent
                        // (e.g. an older offline delete) left in the outbox would
                        // otherwise be pushed and delete the newer server version.
                        try clearOutboxIfRemoteWins(record, in: db)
                        try clearLocalTombstone(recordName: record.recordID.recordName, in: db)
                        // But a record skipped for missing assets was NOT applied:
                        // advancing its metadata would (a) claim a server version
                        // the local row doesn't have, and (b) for a brand-new image
                        // leave a metadata row with no local row behind, which a
                        // later offline reconciliation would misread as an offline
                        // delete and push a tombstone — deleting the photo on every
                        // device.
                        if !imageApply.skippedForMissingAssets {
                            try markServerRecordMetadata(record, type: .image, in: db)
                        }
                    }
                    deletedImageFiles.append(contentsOf: imageApply.deletedImageFiles)
                }
                for record in activeRemoteRecords(type: .decoration, changes: changes, pendingDeletes: pendingDeletes, localTombstones: localTombstones) {
                    try ensureSyncEnabled()
                    let decorationApply = try applyDecorationRecord(
                        record,
                        postIdBySyncId: postIdBySyncId,
                        styleIdBySyncId: styleIdBySyncId,
                        postModificationTimeBySyncId: postModificationTimeBySyncId,
                        styleModificationTimeBySyncId: styleModificationTimeBySyncId,
                        changes: changes,
                        localTombstones: localTombstones,
                        missingDependenciesAreOrphans: missingDependenciesAreOrphans,
                        in: db
                    )
                    if decorationApply.isDeferred {
                        hasDeferredRemoteRecords = true
                    }
                    if decorationApply.didChangeDatabase {
                        didChangeDatabase = true
                        didApplyRemoteUserContent = true
                    }
                    if !decorationApply.isDeferred {
                        try clearOutboxIfRemoteWins(record, in: db)
                        try markServerRecordMetadata(record, type: .decoration, in: db)
                        try clearLocalTombstone(recordName: record.recordID.recordName, in: db)
                    }
                }

                for tombstone in visibleRemoteTombstones(changes) {
                    try ensureSyncEnabled()
                    if tombstone.deletedRecordType == .post || tombstone.deletedRecordType == .style {
                        shouldRunOnboardingSetup = true
                    }
                    try CloudKitLocalTombstone.store(
                        recordType: tombstone.deletedRecordType,
                        recordName: tombstone.deletedRecordName,
                        deletionTime: tombstone.deletionTime,
                        in: db
                    )
                    if let pendingDelete = pendingDeletes[tombstone.deletedRecordName],
                       pendingDelete.modificationTime > tombstone.deletionTime {
                        continue
                    }
                    let deletion = try applyTombstone(tombstone, in: db)
                    if deletion.didChangeDatabase {
                        didChangeDatabase = true
                        deletedImageFiles.append(contentsOf: deletion.deletedImageFiles)
                    }
                    // Use the explicit tombstoneApplied flag so a tombstone that's
                    // already-applied (local row was missing) is still recorded as
                    // deleted in metadata. Only the local-wins path keeps isDeleted
                    // false so enqueueExpiredTombstonePurgesIfNeeded doesn't later
                    // purge the still-live record on CloudKit.
                    try markServerTombstoneMetadata(tombstone, isDeleted: deletion.tombstoneApplied, in: db)
                    try CloudKitOutboxEntry.clear(recordName: tombstone.deletedRecordName, modifiedBefore: tombstone.deletionTime, in: db)
                }

                let styleIdBySyncIdAfterDeletes = try idMap(table: PostStyle.databaseTableName, in: db)
                let localTombstonesAfterDeletes = try CloudKitLocalTombstone.allByRecordName(in: db)
                for record in activeRemoteRecords(type: .setting, changes: changes, pendingDeletes: pendingDeletes, localTombstones: localTombstonesAfterDeletes) {
                    try ensureSyncEnabled()
                    let didApply = try applySettingsRecord(
                        record,
                        styleIdBySyncId: styleIdBySyncIdAfterDeletes,
                        styleModificationTimeBySyncId: try modificationTimeMap(table: PostStyle.databaseTableName, in: db),
                        changes: changes,
                        localTombstones: localTombstonesAfterDeletes,
                        in: db
                    )
                    if didApply {
                        didChangeDatabase = true
                    }
                    try clearOutboxIfRemoteWins(record, in: db)
                    try markServerRecordMetadata(record, type: .setting, in: db)
                    try clearLocalTombstone(recordName: record.recordID.recordName, in: db)
                }
                if try DefaultStyle.applyPendingCloudKitDefaultStyleIfPossible(styleIdBySyncId: styleIdBySyncIdAfterDeletes, in: db) {
                    didChangeDatabase = true
                }

                if shouldPruneMissingLocalRecords {
                    let pruning = try pruneLocalRecordsMissingFromFullFetch(changes, in: db)
                    if pruning.didChangeDatabase {
                        didChangeDatabase = true
                        deletedImageFiles.append(contentsOf: pruning.deletedImageFiles)
                    }
                    if try Post.fetchCount(db) == 0 || PostStyle.fetchCount(db) == 0 {
                        shouldRunOnboardingSetup = true
                    }
                }

                if didApplyRemoteUserContent {
                    try ensureSyncEnabled()
                    didChangeDatabase = try OnboardingManager.shared.removeLocalOnlyOnboardingData(in: db) || didChangeDatabase
                    if try Post.fetchCount(db) == 0 || PostStyle.fetchCount(db) == 0 {
                        shouldRunOnboardingSetup = true
                    }
                }

                try ensureSyncEnabled()
                if hasDeferredRemoteRecords {
                    // The "needs full fetch" intent is in-memory only. If we also
                    // advanced the on-disk state token here, a kill before reset
                    // ForRequestedFullFetchIfNeeded would leave us past the deferred
                    // record permanently. Leave the token at its previous value so
                    // CKSyncEngine re-delivers everything on next launch.
                    cloudKitSyncLog.info("deferred remote records until their dependencies arrive")
                    requestFullFetchAfterCurrentSync()
                } else if let pendingStateSerialization {
                    try CloudKitSyncState.setSyncEngineStateSerialization(pendingStateSerialization, in: db)
                }
            }
        } catch {
            cleanupCopiedImageFiles(allStagedImageFiles)
            throw error
        }

        cleanupCopiedImageFiles(stagedImageAssets.values.flatMap(\.copiedFiles))
        for (fileName, type) in deletedImageFiles {
            _ = ImageCacheManager.shared.deleteImage(fileName: fileName, type: type)
        }

        if shouldRunOnboardingSetup {
            OnboardingManager.shared.requestOnboardingSeed()
        }
        if didChangeDatabase || shouldRunOnboardingSetup {
            OnboardingManager.shared.setupOnboardingDataIfNeeded()
            postCloudKitOriginatedUpdate(.DatabaseUpdated)
        }
    }

    func pendingDeleteOutboxByRecordName(in db: Database) throws -> [String: CloudKitOutboxEntry] {
        let entries = try CloudKitOutboxEntry
            .filter(CloudKitOutboxEntry.Columns.operation == CloudKitOutboxEntry.Operation.delete.rawValue)
            .fetchAll(db)
        return Dictionary(uniqueKeysWithValues: entries.map { ($0.recordName, $0) })
    }

    func pendingSaveOutboxRecordNames(in db: Database) throws -> Set<String> {
        let entries = try CloudKitOutboxEntry
            .filter(CloudKitOutboxEntry.Columns.operation == CloudKitOutboxEntry.Operation.save.rawValue)
            .fetchAll(db)
        return Set(entries.map(\.recordName))
    }

    func remoteSnapshotRecordNames(_ changes: RemoteChangeSet) -> Set<String> {
        var names = Set(visibleRemoteTombstones(changes).map(\.deletedRecordName))
        for records in changes.activeRecordsByType.values {
            names.formUnion(records.map(\.recordID.recordName))
        }
        return names
    }

    func activeSnapshotRecordNames(_ changes: RemoteChangeSet) -> Set<String> {
        var names = Set<String>()
        for records in changes.activeRecordsByType.values {
            names.formUnion(records.map(\.recordID.recordName))
        }
        return names
    }

    func enqueueDeletesForLocalTombstonesThatBeatActiveRemoteRecords(
        _ changes: RemoteChangeSet,
        pendingDeletes: [String: CloudKitOutboxEntry],
        localTombstones: [String: CloudKitLocalTombstone],
        in db: Database
    ) throws {
        for (recordType, records) in changes.activeRecordsByType {
            for record in records {
                let recordName = record.recordID.recordName
                guard let tombstone = localTombstones[recordName],
                      tombstone.deletionTime >= modificationTime(of: record),
                      (pendingDeletes[recordName]?.modificationTime ?? 0) < tombstone.deletionTime else {
                    continue
                }
                try CloudKitOutboxEntry.enqueueDelete(
                    recordType: recordType,
                    recordName: recordName,
                    deletionTime: tombstone.deletionTime,
                    in: db
                )
            }
        }
    }

    func visibleRemoteTombstones(_ changes: RemoteChangeSet) -> [RemoteTombstone] {
        Array(changes.tombstonesByDeletedRecordName.values)
    }

    func pruneLocalRecordsMissingFromFullFetch(_ changes: RemoteChangeSet, in db: Database) throws -> (didChangeDatabase: Bool, deletedImageFiles: [(String, CacheImageType)]) {
        let remoteRecordNames = remoteSnapshotRecordNames(changes)
        let pendingSaveRecordNames = try pendingSaveOutboxRecordNames(in: db)
        let knownRecordNames = Set(try CloudKitRecordMetadata
            .select(Column(CloudKitRecordMetadata.CodingKeys.recordName), as: String.self)
            .fetchAll(db))
        let defaultStyleSyncId = try CloudKitSettingRecord.current(in: db).defaultStyleSyncId
        var didChangeDatabase = false
        var deletedImageFiles: [(String, CacheImageType)] = []
        // Children of a graph kept alive by a pending save must survive the
        // per-type loops below, or the re-uploaded post/style comes back as an
        // empty shell (no text, no image, no decoration).
        var protectedRecordNames = Set<String>()

        // Only prune records the manager has previously synced (i.e. there's a metadata
        // row for them). A record without metadata was created locally while sync was
        // off (or otherwise never reached CloudKit). Pruning those would silently lose
        // user data on the very first re-enable; let them stay until they get enqueued
        // through normal write paths.
        func shouldPrune(_ recordName: String) -> Bool {
            knownRecordNames.contains(recordName)
                && !remoteRecordNames.contains(recordName)
                && !pendingSaveRecordNames.contains(recordName)
        }

        // Pruned rows must drop their sync bookkeeping too: a leftover metadata
        // row keeps remoteDataMayExist stuck on, and makes a later re-enable
        // reconciliation mistake the pruned record for an offline delete —
        // backfilling tombstones into the zone a peer just reset.
        func clearPrunedRecordState(_ recordNames: [String]) throws {
            for recordName in recordNames {
                try CloudKitRecordMetadata.deleteOne(db, key: recordName)
                try CloudKitLocalTombstone.deleteOne(db, key: recordName)
            }
        }

        for post in try Post.fetchAll(db) {
            guard let postId = post.id else { continue }
            let images = try PostImage
                .filter(Column(PostImage.CodingKeys.postId) == postId)
                .fetchAll(db)
            let texts = try PostText
                .filter(Column(PostText.CodingKeys.postId) == postId)
                .fetchAll(db)
            let decorations = try PostDecoration
                .filter(Column(PostDecoration.CodingKeys.postId) == postId)
                .fetchAll(db)
            let graphRecordNames = [post.cloudKitRecordName]
                + images.map(\.cloudKitRecordName)
                + texts.map(\.cloudKitRecordName)
                + decorations.map(\.cloudKitRecordName)
            if graphRecordNames.contains(where: { pendingSaveRecordNames.contains($0) }) {
                protectedRecordNames.formUnion(graphRecordNames)
                var graphModificationTime = post.modificationTime ?? 0
                for image in images {
                    graphModificationTime = max(graphModificationTime, image.modificationTime ?? 0)
                }
                for text in texts {
                    graphModificationTime = max(graphModificationTime, text.modificationTime ?? 0)
                }
                for decoration in decorations {
                    graphModificationTime = max(graphModificationTime, decoration.modificationTime ?? 0)
                }
                if graphModificationTime > (post.modificationTime ?? 0) {
                    try Post
                        .filter(Column(Post.CodingKeys.id) == postId)
                        .updateAll(db, Column(Post.CodingKeys.modificationTime).set(to: graphModificationTime))
                }
                try CloudKitOutboxEntry.enqueueSave(recordType: .post, syncId: post.syncId, modificationTime: graphModificationTime, in: db)
                continue
            }
            guard shouldPrune(post.cloudKitRecordName) else { continue }
            try PostImage.deleteAll(db, ids: images.compactMap(\.id))
            try PostText.deleteAll(db, ids: texts.compactMap(\.id))
            try PostDecoration.deleteAll(db, ids: decorations.compactMap(\.id))
            try Post.deleteAll(db, ids: [postId])
            try OnboardingLocalRecord.unmark(recordType: .post, syncId: post.syncId, in: db)
            try OnboardingLocalRecord.unmark(recordType: .image, syncIds: images.map(\.syncId), in: db)
            try OnboardingLocalRecord.unmark(recordType: .text, syncIds: texts.map(\.syncId), in: db)
            try OnboardingLocalRecord.unmark(recordType: .decoration, syncIds: decorations.map(\.syncId), in: db)
            try clearPrunedRecordState(graphRecordNames)
            deletedImageFiles.append(contentsOf: imageFiles(for: images))
            didChangeDatabase = true
        }

        // Styles before the per-type child loops so a protected style graph
        // exempts its decorations from the generic decoration prune.
        for style in try PostStyle.fetchAll(db) {
            guard let styleId = style.id else { continue }
            let decorations = try PostDecoration
                .filter(Column(PostDecoration.CodingKeys.styleId) == styleId)
                .fetchAll(db)
            let graphRecordNames = [style.cloudKitRecordName] + decorations.map(\.cloudKitRecordName)
            if graphRecordNames.contains(where: { pendingSaveRecordNames.contains($0) })
                || (pendingSaveRecordNames.contains(CloudKitRecordName.settingsName) && defaultStyleSyncId == style.syncId) {
                protectedRecordNames.formUnion(graphRecordNames)
                var graphModificationTime = style.modificationTime ?? 0
                for decoration in decorations {
                    graphModificationTime = max(graphModificationTime, decoration.modificationTime ?? 0)
                }
                if graphModificationTime > (style.modificationTime ?? 0) {
                    try PostStyle
                        .filter(Column(PostStyle.CodingKeys.id) == styleId)
                        .updateAll(db, Column(PostStyle.CodingKeys.modificationTime).set(to: graphModificationTime))
                }
                try CloudKitOutboxEntry.enqueueSave(recordType: .style, syncId: style.syncId, modificationTime: graphModificationTime, in: db)
                continue
            }
            guard shouldPrune(style.cloudKitRecordName) else { continue }
            let fallbackStyle = try PostStyle
                .filter(PostStyle.Columns.id != styleId)
                .order(PostStyle.Columns.id.asc)
                .fetchOne(db)
            try PostDecoration.deleteAll(db, ids: decorations.compactMap(\.id))
            try PostStyle.deleteAll(db, ids: [styleId])
            _ = try DefaultStyle.replaceDeletedStyleIfNeeded(
                deletedStyle: style,
                fallbackStyle: fallbackStyle,
                modificationTime: try db.transactionDate.nanoSecondSince1970,
                in: db
            )
            try OnboardingLocalRecord.unmark(recordType: .style, syncId: style.syncId, in: db)
            try OnboardingLocalRecord.unmark(recordType: .decoration, syncIds: decorations.map(\.syncId), in: db)
            try clearPrunedRecordState(graphRecordNames)
            didChangeDatabase = true
        }

        for image in try PostImage.fetchAll(db)
        where shouldPrune(image.cloudKitRecordName) && !protectedRecordNames.contains(image.cloudKitRecordName) {
            guard let imageId = image.id else { continue }
            try PostImage.deleteAll(db, ids: [imageId])
            try OnboardingLocalRecord.unmark(recordType: .image, syncId: image.syncId, in: db)
            try clearPrunedRecordState([image.cloudKitRecordName])
            deletedImageFiles.append(contentsOf: imageFiles(for: [image]))
            didChangeDatabase = true
        }

        for text in try PostText.fetchAll(db)
        where shouldPrune(text.cloudKitRecordName) && !protectedRecordNames.contains(text.cloudKitRecordName) {
            guard let textId = text.id else { continue }
            try PostText.deleteAll(db, ids: [textId])
            try OnboardingLocalRecord.unmark(recordType: .text, syncId: text.syncId, in: db)
            try clearPrunedRecordState([text.cloudKitRecordName])
            didChangeDatabase = true
        }

        for decoration in try PostDecoration.fetchAll(db)
        where shouldPrune(decoration.cloudKitRecordName) && !protectedRecordNames.contains(decoration.cloudKitRecordName) {
            guard let decorationId = decoration.id else { continue }
            try PostDecoration.deleteAll(db, ids: [decorationId])
            try OnboardingLocalRecord.unmark(recordType: .decoration, syncId: decoration.syncId, in: db)
            try clearPrunedRecordState([decoration.cloudKitRecordName])
            didChangeDatabase = true
        }

        if !remoteRecordNames.contains(CloudKitRecordName.settingsName),
           !pendingSaveRecordNames.contains(CloudKitRecordName.settingsName) {
            if try DefaultStyle.clearCloudKitStateForMissingRemoteSetting(in: db) {
                didChangeDatabase = true
            }
            try CloudKitRecordMetadata.deleteOne(db, key: CloudKitRecordName.settingsName)
        }

        return (didChangeDatabase, deletedImageFiles)
    }

    func activeRemoteRecords(
        type: CloudKitRecordType,
        changes: RemoteChangeSet,
        pendingDeletes: [String: CloudKitOutboxEntry],
        localTombstones: [String: CloudKitLocalTombstone]
    ) -> [CKRecord] {
        (changes.activeRecordsByType[type] ?? [])
            .filter { record in
            let recordName = record.recordID.recordName
            let remoteModificationTime = modificationTime(of: record)
            if let pendingDelete = pendingDeletes[recordName],
               pendingDelete.modificationTime >= remoteModificationTime {
                return false
            }
            guard let deletionTime = knownDeletionTime(
                recordName: recordName,
                changes: changes,
                localTombstones: localTombstones
            ) else {
                return true
            }
            return remoteModificationTime > deletionTime
        }
    }

    func knownDeletionTime(
        recordName: String,
        changes: RemoteChangeSet,
        localTombstones: [String: CloudKitLocalTombstone]
    ) -> Int64? {
        let remoteDeletionTime = changes.tombstonesByDeletedRecordName[recordName]?.deletionTime
        let localDeletionTime = localTombstones[recordName]?.deletionTime
        switch (remoteDeletionTime, localDeletionTime) {
        case (.some(let remote), .some(let local)):
            return max(remote, local)
        case (.some(let remote), .none):
            return remote
        case (.none, .some(let local)):
            return local
        case (.none, .none):
            return nil
        }
    }

    func dependencyState(
        recordType: CloudKitRecordType,
        syncId: String,
        idBySyncId: [String: Int64],
        modificationTimeBySyncId: [String: Int64],
        remoteModificationTime: Int64,
        changes: RemoteChangeSet,
        localTombstones: [String: CloudKitLocalTombstone],
        missingDependenciesAreOrphans: Bool
    ) -> DependencyState {
        let recordName = CloudKitRecordName.make(recordType, syncId: syncId)
        let localId = idBySyncId[syncId]
        if let deletionTime = knownDeletionTime(
            recordName: recordName,
            changes: changes,
            localTombstones: localTombstones
        ), localId == nil || deletionTime >= (modificationTimeBySyncId[syncId] ?? 0) {
            return .deleted(max(deletionTime, remoteModificationTime))
        }
        guard let localId else {
            return missingDependenciesAreOrphans ? .deleted(remoteModificationTime) : .missing
        }
        return .available(localId)
    }

    func idMap(table: String, in db: Database) throws -> [String: Int64] {
        let rows = try Table(table)
            .select(Column("id"), Column("sync_id"))
            .filter(Column("sync_id") != nil)
            .fetchAll(db)
        var result: [String: Int64] = [:]
        for row in rows {
            let id: Int64 = row["id"]
            let syncId: String = row["sync_id"]
            result[syncId] = id
        }
        return result
    }

    func modificationTimeMap(table: String, in db: Database) throws -> [String: Int64] {
        let rows = try Table(table)
            .select(Column("sync_id"), Column("modification_time"))
            .filter(Column("sync_id") != nil)
            .fetchAll(db)
        var result: [String: Int64] = [:]
        for row in rows {
            let syncId: String = row["sync_id"]
            result[syncId] = row["modification_time"] ?? 0
        }
        return result
    }

    func clearOutboxIfRemoteWins(_ record: CKRecord, in db: Database) throws {
        _ = try CloudKitOutboxEntry
            .filter(
                CloudKitOutboxEntry.Columns.recordName == record.recordID.recordName
                && CloudKitOutboxEntry.Columns.modificationTime < modificationTime(of: record)
            )
            .deleteAll(db)
    }

    func clearLocalTombstone(recordName: String, in db: Database) throws {
        _ = try CloudKitLocalTombstone
            .filter(CloudKitLocalTombstone.Columns.recordName == recordName)
            .deleteAll(db)
    }

    func markServerRecordMetadata(_ record: CKRecord, type: CloudKitRecordType, in db: Database) throws {
        try CloudKitRecordMetadata.markServerRecord(
            recordName: record.recordID.recordName,
            recordType: type,
            aggregateType: type == .setting ? .setting : .record,
            aggregateName: record.recordID.recordName,
            serverChangeTag: record.recordChangeTag,
            version: modificationTime(of: record),
            isDeleted: false,
            in: db
        )
    }

    func markServerTombstoneMetadata(_ tombstone: RemoteTombstone, isDeleted: Bool, in db: Database) throws {
        try CloudKitRecordMetadata.markServerRecord(
            recordName: tombstone.deletedRecordName,
            recordType: tombstone.deletedRecordType,
            aggregateType: .record,
            aggregateName: tombstone.deletedRecordName,
            serverChangeTag: nil,
            version: tombstone.deletionTime,
            isDeleted: isDeleted,
            in: db
        )
    }
}

extension CloudKitRecordSyncManager {
    func applyStyleRecord(_ record: CKRecord, in db: Database) throws -> Bool {
        guard let syncId = stringValue(Field.syncId, in: record),
              let name = stringValue(Field.name, in: record),
              let lockTextSizeRaw = intValue(Field.lockTextSize, in: record),
              let lockTextAlignmentRaw = intValue(Field.lockTextAlignment, in: record),
              let islandTextSizeRaw = intValue(Field.islandTextSize, in: record),
              let islandTextAlignmentRaw = intValue(Field.islandTextAlignment, in: record),
              let symbol = stringValue(Field.symbol, in: record),
              let symbolAngle = intValue(Field.symbolAngle, in: record),
              let imageDisplayModeRaw = intValue(Field.imageDisplayMode, in: record),
              let controlAlpha = intValue(Field.controlAlpha, in: record) else {
            cloudKitSyncLog.info("style import skipped: missing fields for \(record.recordID.recordName, privacy: .private)")
            return false
        }
        let existing = try PostStyle
            .filter(Column(PostStyle.CodingKeys.syncId) == syncId)
            .fetchOne(db)
        let remoteModificationTime = modificationTime(of: record)
        guard existing == nil || remoteModificationTime > (existing?.modificationTime ?? 0) else { return false }

        var style = PostStyle(
            name: name,
            lockBackgroundColor: stringValue(Field.lockBackgroundColor, in: record),
            lockTextColor: stringValue(Field.lockTextColor, in: record),
            lockTextSize: PostTextSize(rawValue: lockTextSizeRaw) ?? .automatic,
            lockTextAlignment: PostTextAlignment(rawValue: lockTextAlignmentRaw) ?? .center,
            islandTextColor: stringValue(Field.islandTextColor, in: record),
            islandTextSize: PostTextSize(rawValue: islandTextSizeRaw) ?? .automatic,
            islandTextAlignment: PostTextAlignment(rawValue: islandTextAlignmentRaw) ?? .center,
            symbol: symbol,
            symbolColor: stringValue(Field.symbolColor, in: record),
            symbolAngle: symbolAngle,
            imageDisplayMode: PostImageDisplayMode(rawValue: imageDisplayModeRaw) ?? .aspectFit,
            controlAlpha: controlAlpha
        )
        style.id = existing?.id
        style.syncId = syncId
        style.creationTime = int64Value(Field.creationTime, in: record) ?? existing?.creationTime
        style.modificationTime = remoteModificationTime
        try style.save(db)
        return true
    }

    func applyPostRecord(_ record: CKRecord, in db: Database) throws -> Bool {
        guard let syncId = stringValue(Field.syncId, in: record),
              let isPinned = boolValue(Field.isPinned, in: record),
              let order = int64Value(Field.order, in: record) else {
            cloudKitSyncLog.info("post import skipped: missing fields for \(record.recordID.recordName, privacy: .private)")
            return false
        }
        let existing = try Post
            .filter(Column(Post.CodingKeys.syncId) == syncId)
            .fetchOne(db)
        let remoteModificationTime = modificationTime(of: record)
        guard existing == nil || remoteModificationTime > (existing?.modificationTime ?? 0) else { return false }

        var post = Post(
            expirationTime: int64Value(Field.expirationTime, in: record),
            actionLink: stringValue(Field.actionLink, in: record) ?? "",
            isPinned: isPinned,
            order: order
        )
        post.id = existing?.id
        post.syncId = syncId
        post.creationTime = int64Value(Field.creationTime, in: record) ?? existing?.creationTime
        post.modificationTime = remoteModificationTime
        try post.save(db)
        if post.isPinned, MaxPinnedPosts.current == .one {
            try unpinOtherPinnedPostsForRemoteAppliedPost(syncId: syncId, modificationTime: remoteModificationTime, in: db)
        }
        return true
    }

    func applyTextRecord(
        _ record: CKRecord,
        postIdBySyncId: [String: Int64],
        postModificationTimeBySyncId: [String: Int64],
        changes: RemoteChangeSet,
        localTombstones: [String: CloudKitLocalTombstone],
        missingDependenciesAreOrphans: Bool,
        in db: Database
    ) throws -> (didChangeDatabase: Bool, isDeferred: Bool, deletedImageFiles: [(String, CacheImageType)]) {
        guard let syncId = stringValue(Field.syncId, in: record),
              let postSyncId = stringValue(Field.postSyncId, in: record),
              let content = stringValue(Field.content, in: record),
              let order = int64Value(Field.order, in: record) else {
            cloudKitSyncLog.info("text import skipped: missing fields for \(record.recordID.recordName, privacy: .private)")
            return (false, false, [])
        }
        let remoteModificationTime = modificationTime(of: record)
        let postId: Int64
        switch dependencyState(
            recordType: .post,
            syncId: postSyncId,
            idBySyncId: postIdBySyncId,
            modificationTimeBySyncId: postModificationTimeBySyncId,
            remoteModificationTime: remoteModificationTime,
            changes: changes,
            localTombstones: localTombstones,
            missingDependenciesAreOrphans: missingDependenciesAreOrphans
        ) {
        case .available(let id):
            postId = id
        case .deleted(let deletionTime):
            try enqueueCloudKitDeleteIfNeeded(recordType: .text, syncId: syncId, deletionTime: deletionTime, in: db)
            return (false, false, [])
        case .missing:
            return (false, true, [])
        }
        let existing = try PostText
            .filter(Column(PostText.CodingKeys.syncId) == syncId)
            .fetchOne(db)
        guard existing == nil || remoteModificationTime > (existing?.modificationTime ?? 0) else { return (false, false, []) }

        let images = try PostImage
            .filter(Column(PostImage.CodingKeys.postId) == postId)
            .fetchAll(db)
        if let latestImageModificationTime = images.map({ $0.modificationTime ?? 0 }).max(),
           latestImageModificationTime > remoteModificationTime {
            try enqueueCloudKitDeleteIfNeeded(
                recordType: .text,
                syncId: syncId,
                deletionTime: latestImageModificationTime,
                in: db
            )
            return (false, false, [])
        }
        for image in images {
            try enqueueCloudKitDeleteIfNeeded(recordType: .image, syncId: image.syncId, deletionTime: remoteModificationTime, in: db)
        }
        try PostImage.deleteAll(db, ids: images.compactMap(\.id))
        try OnboardingLocalRecord.unmark(recordType: .image, syncIds: images.map(\.syncId), in: db)

        var text = PostText(
            postId: postId,
            content: content,
            order: order
        )
        text.id = existing?.id
        text.syncId = syncId
        text.creationTime = int64Value(Field.creationTime, in: record) ?? existing?.creationTime
        text.modificationTime = remoteModificationTime
        try text.save(db)
        return (true, false, imageFiles(for: images))
    }

    func applyImageRecord(
        _ record: CKRecord,
        postIdBySyncId: [String: Int64],
        postModificationTimeBySyncId: [String: Int64],
        changes: RemoteChangeSet,
        localTombstones: [String: CloudKitLocalTombstone],
        missingDependenciesAreOrphans: Bool,
        stagedAssets: StagedImageAssets?,
        in db: Database
    ) throws -> (didChangeDatabase: Bool, isDeferred: Bool, deletedImageFiles: [(String, CacheImageType)], skippedForMissingAssets: Bool) {
        guard let syncId = stringValue(Field.syncId, in: record),
              let postSyncId = stringValue(Field.postSyncId, in: record),
              let orientation = int64Value(Field.orientation, in: record),
              let minX = int64Value(Field.minX, in: record),
              let minY = int64Value(Field.minY, in: record),
              let maxX = int64Value(Field.maxX, in: record),
              let maxY = int64Value(Field.maxY, in: record),
              let order = int64Value(Field.order, in: record) else {
            cloudKitSyncLog.info("image import skipped: missing fields for \(record.recordID.recordName, privacy: .private)")
            return (false, false, [], false)
        }
        let remoteModificationTime = modificationTime(of: record)
        let postId: Int64
        switch dependencyState(
            recordType: .post,
            syncId: postSyncId,
            idBySyncId: postIdBySyncId,
            modificationTimeBySyncId: postModificationTimeBySyncId,
            remoteModificationTime: remoteModificationTime,
            changes: changes,
            localTombstones: localTombstones,
            missingDependenciesAreOrphans: missingDependenciesAreOrphans
        ) {
        case .available(let id):
            postId = id
        case .deleted(let deletionTime):
            try enqueueCloudKitDeleteIfNeeded(recordType: .image, syncId: syncId, deletionTime: deletionTime, in: db)
            return (false, false, [], false)
        case .missing:
            return (false, true, [], false)
        }
        let existing = try PostImage
            .filter(Column(PostImage.CodingKeys.syncId) == syncId)
            .fetchOne(db)
        if let existing, remoteModificationTime <= (existing.modificationTime ?? 0) {
            guard remoteModificationTime == (existing.modificationTime ?? 0) else { return (false, false, [], false) }
            let didRestore = try restoreMissingImageFiles(for: existing, stagedAssets: stagedAssets, in: db)
            return (didRestore, false, [], false)
        }

        let texts = try PostText
            .filter(Column(PostText.CodingKeys.postId) == postId)
            .fetchAll(db)
        if let latestTextModificationTime = texts.map({ $0.modificationTime ?? 0 }).max(),
           latestTextModificationTime > remoteModificationTime {
            try enqueueCloudKitDeleteIfNeeded(
                recordType: .image,
                syncId: syncId,
                deletionTime: latestTextModificationTime,
                in: db
            )
            return (false, false, [], false)
        }

        let remoteOriginalFileName = stringValue(Field.originalFileName, in: record)
        let remoteProcessedFileName = stringValue(Field.processedFileName, in: record)
        let hasExistingOriginalFile = existing.map { ImageCacheManager.shared.getURL(name: $0.original, type: .original) != nil } ?? false
        let hasExistingProcessedFile = existing.map { ImageCacheManager.shared.getURL(name: $0.processed, type: .processed) != nil } ?? false
        let needsOriginalAsset = existing == nil
        || (remoteOriginalFileName != nil && remoteOriginalFileName != existing?.original)
        || !hasExistingOriginalFile
        let needsProcessedAsset = existing == nil
        || (remoteProcessedFileName != nil && remoteProcessedFileName != existing?.processed)
        || !hasExistingProcessedFile

        if (needsOriginalAsset && stagedAssets?.originalName == nil)
            || (needsProcessedAsset && stagedAssets?.processedName == nil) {
            cloudKitSyncLog.info("image import skipped: assets incomplete for \(record.recordID.recordName, privacy: .private)")
            CloudKitSync.setLastError(String(localized: "settings.cloudKitSync.error.imageAssetMissing"))
            return (false, false, [], true)
        }

        for text in texts {
            try enqueueCloudKitDeleteIfNeeded(recordType: .text, syncId: text.syncId, deletionTime: remoteModificationTime, in: db)
        }
        try PostText.deleteAll(db, ids: texts.compactMap(\.id))
        try OnboardingLocalRecord.unmark(recordType: .text, syncIds: texts.map(\.syncId), in: db)

        guard let originalName = stagedAssets?.originalName ?? remoteOriginalFileName ?? existing?.original,
              let processedName = stagedAssets?.processedName ?? remoteProcessedFileName ?? existing?.processed else {
            return (false, false, [], false)
        }

        var image = PostImage(
            postId: postId,
            original: originalName,
            processed: processedName,
            orientation: orientation,
            minX: minX,
            minY: minY,
            maxX: maxX,
            maxY: maxY,
            order: order
        )
        image.id = existing?.id
        image.syncId = syncId
        image.creationTime = int64Value(Field.creationTime, in: record) ?? existing?.creationTime
        image.modificationTime = remoteModificationTime
        try image.save(db)

        var deletedImageFiles: [(String, CacheImageType)] = []
        if let existing, existing.original != originalName {
            deletedImageFiles.append((existing.original, .original))
        }
        if let existing, existing.processed != processedName {
            deletedImageFiles.append((existing.processed, .processed))
        }
        return (true, false, deletedImageFiles, false)
    }

    /// Remote and local are at the same version, so the asset content matches
    /// the row; a lost cache file (e.g. an interrupted crop that deleted the old
    /// file before the replacement landed) can be restored from the staged
    /// download. modification_time stays untouched — no LWW impact, no echo
    /// back to the server.
    func restoreMissingImageFiles(for image: PostImage, stagedAssets: StagedImageAssets?, in db: Database) throws -> Bool {
        guard let imageId = image.id, let stagedAssets else { return false }
        var assignments: [ColumnAssignment] = []
        var consumedOriginal = false
        var consumedProcessed = false
        if ImageCacheManager.shared.getURL(name: image.original, type: .original) == nil,
           let stagedOriginal = stagedAssets.originalName {
            assignments.append(Column(PostImage.CodingKeys.original).set(to: stagedOriginal))
            consumedOriginal = true
        }
        if ImageCacheManager.shared.getURL(name: image.processed, type: .processed) == nil,
           let stagedProcessed = stagedAssets.processedName {
            assignments.append(Column(PostImage.CodingKeys.processed).set(to: stagedProcessed))
            consumedProcessed = true
        }
        guard !assignments.isEmpty else { return false }
        try PostImage
            .filter(Column(PostImage.CodingKeys.id) == imageId)
            .updateAll(db, assignments)
        // The caller drops the whole staged entry once anything was restored, so
        // clean the unconsumed half here instead of leaking it until the next
        // launch's orphan sweep.
        if !consumedOriginal, let stagedOriginal = stagedAssets.originalName, stagedOriginal != image.original {
            _ = ImageCacheManager.shared.deleteImage(fileName: stagedOriginal, type: .original)
        }
        if !consumedProcessed, let stagedProcessed = stagedAssets.processedName, stagedProcessed != image.processed {
            _ = ImageCacheManager.shared.deleteImage(fileName: stagedProcessed, type: .processed)
        }
        return true
    }

    func applyDecorationRecord(
        _ record: CKRecord,
        postIdBySyncId: [String: Int64],
        styleIdBySyncId: [String: Int64],
        postModificationTimeBySyncId: [String: Int64],
        styleModificationTimeBySyncId: [String: Int64],
        changes: RemoteChangeSet,
        localTombstones: [String: CloudKitLocalTombstone],
        missingDependenciesAreOrphans: Bool,
        in db: Database
    ) throws -> (didChangeDatabase: Bool, isDeferred: Bool) {
        guard let syncId = stringValue(Field.syncId, in: record),
              let postSyncId = stringValue(Field.postSyncId, in: record),
              let styleSyncId = stringValue(Field.styleSyncId, in: record) else {
            return (false, false)
        }
        let remoteModificationTime = modificationTime(of: record)
        let postState = dependencyState(
            recordType: .post,
            syncId: postSyncId,
            idBySyncId: postIdBySyncId,
            modificationTimeBySyncId: postModificationTimeBySyncId,
            remoteModificationTime: remoteModificationTime,
            changes: changes,
            localTombstones: localTombstones,
            missingDependenciesAreOrphans: missingDependenciesAreOrphans
        )
        let styleState = dependencyState(
            recordType: .style,
            syncId: styleSyncId,
            idBySyncId: styleIdBySyncId,
            modificationTimeBySyncId: styleModificationTimeBySyncId,
            remoteModificationTime: remoteModificationTime,
            changes: changes,
            localTombstones: localTombstones,
            missingDependenciesAreOrphans: missingDependenciesAreOrphans
        )

        let postId: Int64
        let styleId: Int64
        switch (postState, styleState) {
        case (.available(let resolvedPostId), .available(let resolvedStyleId)):
            postId = resolvedPostId
            styleId = resolvedStyleId
        case (.deleted(let deletionTime), _), (_, .deleted(let deletionTime)):
            try enqueueCloudKitDeleteIfNeeded(recordType: .decoration, syncId: syncId, deletionTime: deletionTime, in: db)
            return (false, false)
        case (.missing, _), (_, .missing):
            return (false, true)
        }
        let existing = try PostDecoration
            .filter(Column(PostDecoration.CodingKeys.syncId) == syncId)
            .fetchOne(db)
        guard existing == nil || remoteModificationTime > (existing?.modificationTime ?? 0) else { return (false, false) }

        let conflictingDecorations = try PostDecoration
            .filter(Column(PostDecoration.CodingKeys.postId) == postId && Column(PostDecoration.CodingKeys.syncId) != syncId)
            .fetchAll(db)
        if let latestDecorationModificationTime = conflictingDecorations.map({ $0.modificationTime ?? 0 }).max(),
           latestDecorationModificationTime > remoteModificationTime {
            try enqueueCloudKitDeleteIfNeeded(
                recordType: .decoration,
                syncId: syncId,
                deletionTime: latestDecorationModificationTime,
                in: db
            )
            return (false, false)
        }
        for decoration in conflictingDecorations {
            try enqueueCloudKitDeleteIfNeeded(recordType: .decoration, syncId: decoration.syncId, deletionTime: remoteModificationTime, in: db)
        }
        try PostDecoration.deleteAll(db, ids: conflictingDecorations.compactMap(\.id))
        try OnboardingLocalRecord.unmark(recordType: .decoration, syncIds: conflictingDecorations.map(\.syncId), in: db)

        var decoration = PostDecoration(styleId: styleId, postId: postId)
        decoration.id = existing?.id
        decoration.syncId = syncId
        decoration.creationTime = int64Value(Field.creationTime, in: record) ?? existing?.creationTime
        decoration.modificationTime = remoteModificationTime
        try decoration.save(db)
        return (true, false)
    }

    func applySettingsRecord(
        _ record: CKRecord,
        styleIdBySyncId: [String: Int64],
        styleModificationTimeBySyncId: [String: Int64],
        changes: RemoteChangeSet,
        localTombstones: [String: CloudKitLocalTombstone],
        in db: Database
    ) throws -> Bool {
        guard record.recordID.recordName == CloudKitRecordName.settingsName else {
            return false
        }
        let remoteModificationTime = modificationTime(of: record)
        guard let defaultStyleSyncId = stringValue(Field.defaultStyleSyncId, in: record) else {
            return try DefaultStyle.clearCloudKitDefaultStyle(
                modificationTime: remoteModificationTime,
                in: db
            )
        }
        switch dependencyState(
            recordType: .style,
            syncId: defaultStyleSyncId,
            idBySyncId: styleIdBySyncId,
            modificationTimeBySyncId: styleModificationTimeBySyncId,
            remoteModificationTime: remoteModificationTime,
            changes: changes,
            localTombstones: localTombstones,
            missingDependenciesAreOrphans: false
        ) {
        case .available(let styleId):
            return try DefaultStyle.applyCloudKitDefaultStyle(
                syncId: defaultStyleSyncId,
                localId: styleId,
                modificationTime: remoteModificationTime,
                in: db
            )
        case .deleted(_):
            return try DefaultStyle.clearPendingCloudKitDefaultStyleIfNeeded(syncId: defaultStyleSyncId, in: db)
        case .missing:
            return try DefaultStyle.storePendingCloudKitDefaultStyle(
                syncId: defaultStyleSyncId,
                modificationTime: remoteModificationTime,
                in: db
            )
        }
    }

    func enqueueCloudKitDeleteIfNeeded(recordType: CloudKitRecordType, syncId: String, deletionTime: Int64, in db: Database) throws {
        guard try !OnboardingLocalRecord.isMarked(recordType: recordType, syncId: syncId, in: db) else { return }
        try CloudKitOutboxEntry.enqueueDelete(recordType: recordType, syncId: syncId, deletionTime: deletionTime, in: db)
    }

    func enqueueCloudKitSaveIfNeeded(recordType: CloudKitRecordType, syncId: String, modificationTime: Int64?, in db: Database) throws {
        guard try !OnboardingLocalRecord.isMarked(recordType: recordType, syncId: syncId, in: db) else { return }
        try CloudKitOutboxEntry.enqueueSave(recordType: recordType, syncId: syncId, modificationTime: modificationTime, in: db)
    }

    func enqueuePostGraphSaveIfNeeded(postId: Int64, modificationTime: Int64?, in db: Database) throws {
        guard let post = try Post.fetchOne(db, id: postId),
              try !OnboardingLocalRecord.isMarked(recordType: .post, syncId: post.syncId, in: db) else { return }
        try CloudKitOutboxEntry.enqueuePostGraphSave(postId: postId, modificationTime: modificationTime, in: db)
    }

    func enqueueStyleGraphSaveIfNeeded(styleId: Int64, modificationTime: Int64?, in db: Database) throws {
        guard let style = try PostStyle.fetchOne(db, id: styleId),
              try !OnboardingLocalRecord.isMarked(recordType: .style, syncId: style.syncId, in: db) else { return }
        try CloudKitOutboxEntry.enqueueStyleGraphSave(styleId: styleId, modificationTime: modificationTime, in: db)
    }

    func unpinOtherPinnedPostsForRemoteAppliedPost(syncId: String, modificationTime: Int64, in db: Database) throws {
        let pinnedPosts = try Post
            .filter(Post.Columns.isPinned == true && Post.Columns.syncId != syncId)
            .order(Post.Columns.order.asc)
            .fetchAll(db)
        guard !pinnedPosts.isEmpty else { return }

        let firstOrder = try Int64.fetchOne(
            db,
            sql: #"SELECT COALESCE(MAX("order"), -1) + 1 FROM post WHERE is_pinned = 0"#
        ) ?? 0
        for (index, pinnedPost) in pinnedPosts.enumerated() {
            guard let postId = pinnedPost.id else { continue }
            let derivedModificationTime = max(
                try db.transactionDate.nanoSecondSince1970,
                modificationTime + Int64(index) + 1
            )
            try Post
                .filter(Column(Post.CodingKeys.id) == postId)
                .updateAll(
                    db,
                    Column(Post.CodingKeys.isPinned).set(to: false),
                    Column(Post.CodingKeys.order).set(to: firstOrder + Int64(index)),
                    Column(Post.CodingKeys.modificationTime).set(to: derivedModificationTime)
                )
            try enqueueCloudKitSaveIfNeeded(
                recordType: .post,
                syncId: pinnedPost.syncId,
                modificationTime: derivedModificationTime,
                in: db
            )
        }
    }
}
