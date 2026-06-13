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

/// The engine generation was bumped mid-run (zone discontinuity reset, account
/// change, disable). Distinct from `CancellationError` on purpose: a superseded
/// run must fall through to the follow-up check — recovery (e.g. the
/// discontinuity probe) is usually queued via needsFollowUpSync and the app is
/// foreground-poll-only, so aborting would strand it until the next external
/// trigger. A genuine task cancellation, by contrast, aborts the run because
/// the debounce is about to start a fresh one.
private struct CloudKitEngineSupersededError: Error {}

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
    private var uploadAssetFilesByRecordName: [String: (generation: UInt64, urls: [URL])] = [:]
    private var syncRunID: UInt64 = 0
    private var engineGeneration: UInt64 = 0
    private var didEnsureRecordZone = false
    private var didDropOversizedRecords = false

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
        guard let syncRun = beginSync() else {
            throw CloudKitSyncInProgressError()
        }
        beginBackgroundTaskIfNeeded()

        do {
            clearFollowUpSync(runID: syncRun)
            try ensureSyncEnabled()
            let accountStatus = try await fetchAccountStatus()
            guard accountStatus == .available else {
                throw CloudKitUserVisibleError(message: cloudKitAccountStatusMessage(accountStatus))
            }
            // A rebuild deletes the zone and replaces it with this device's
            // library — it must never execute a stale intent against a
            // silently-switched account's data. The verify already wiped the
            // old bookkeeping; the user must explicitly re-confirm the rebuild
            // under the new account.
            if try await verifyCloudKitAccountIdentity() {
                throw CloudKitUserVisibleError(message: String(localized: "settings.cloudKitSync.error.accountChanged"))
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
            try await sendChangesAndCleanupUploadAssets(engine, generation: syncGeneration)
            try ensureEngineGeneration(syncGeneration)
            try syncEnginePendingChangesFromOutbox(engine)
            let hasOutboxFailures = try hasOutboxFailures()
            try markRemoteDataMayExistIfCloudKitStateExists()
            CloudKitSync.setPendingRemoteReset(false)
            // A rebuild deletes the zone and stamps a fresh reset marker — it
            // fully supersedes any interrupted clear.
            CloudKitSync.setPendingRemoteClear(false)
            // Consumed unconditionally — short-circuiting would leak the flag
            // into an unrelated later run's error footer.
            let didDropOversizedRecords = takeDidDropOversizedRecords()
            if hasOutboxFailures {
                CloudKitSync.setLastError(String(localized: "settings.cloudKitSync.error.uploadFailed"))
            } else if didDropOversizedRecords {
                CloudKitSync.setLastError(String(localized: "settings.cloudKitSync.error.recordTooLarge"))
            } else {
                CloudKitSync.setLastError(nil)
            }
            runOnboardingAfterInitialCloudGateIfNeeded()
            let needsSync = finishExclusiveSync(runID: syncRun)
            if needsSync {
                syncIfEnabled()
            }
            return hasOutboxFailures
        } catch is CancellationError {
            _ = finishExclusiveSync(runID: syncRun)
            throw CancellationError()
        } catch is CloudKitEngineSupersededError {
            // Converted at this public boundary: supersession is not a
            // user-visible failure (pendingRemoteReset is still set, so the
            // rebuild re-queues on the next trigger), and callers — the retry
            // loop and the settings screen — already treat CancellationError
            // as exactly that silent preemption.
            _ = finishExclusiveSync(runID: syncRun)
            throw CancellationError()
        } catch {
            CloudKitSync.setLastError(error.localizedDescription)
            _ = finishExclusiveSync(runID: syncRun)
            throw error
        }
    }

    /// Returns true when an account switch was detected and handled (the
    /// enable flow proceeds regardless; destructive flows must abort).
    @discardableResult
    func validateAccountForEnabling() async throws -> Bool {
        let accountStatus = try await fetchAccountStatus()
        guard accountStatus == .available else {
            throw CloudKitUserVisibleError(message: cloudKitAccountStatusMessage(accountStatus))
        }
        return try await verifyCloudKitAccountIdentity()
    }

    func clearCloudKitData() async throws {
        guard let syncRun = beginSync() else {
            throw CloudKitSyncInProgressError()
        }
        beginBackgroundTaskIfNeeded()

        do {
            clearFollowUpSync(runID: syncRun)
            // A clear empties the zone — never execute it as a stale intent
            // against a silently-switched account's data.
            if try await validateAccountForEnabling() {
                throw CloudKitUserVisibleError(message: String(localized: "settings.cloudKitSync.error.accountChanged"))
            }
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
            // Same follow-up contract as rebuildCloudKitData: a sync request
            // that bounced off this exclusive run (e.g. the user re-enabled
            // sync mid-clear) must not be silently dropped.
            let needsSync = finishExclusiveSync(runID: syncRun)
            if needsSync {
                syncIfEnabled()
            }
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
            // IfIdle, not Needed: clearCloudKitData runs while sync is
            // DISABLED and holds the shared background task — a stray sync
            // trigger landing here must not strip its keep-alive mid-clear.
            endBackgroundTaskIfIdle()
            return
        }
        guard !CloudKitSync.pendingRemoteReset else {
            rebuildCloudKitDataAfterLocalReset()
            // IfIdle: a manual rebuild may be mid-flight holding the shared
            // background task — stripping it here would suspend the app in
            // the middle of its zone delete + re-upload.
            endBackgroundTaskIfIdle()
            return
        }
        guard let runID = beginSync() else {
            return
        }
        beginBackgroundTaskIfNeeded()

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
            } catch is CloudKitEngineSupersededError {
                // The engine was replaced mid-run (discontinuity reset, account
                // change): the recovery work is queued via needsFollowUpSync —
                // fall through to the follow-up check and run it in this run.
                runOnboardingAfterInitialCloudGateIfNeeded()
            } catch is CancellationError {
                // The debounce cancelled this run because a newer trigger is
                // about to start its own; spinning on in a cancelled task would
                // burn the failure budget with zero-delay retries (Task.sleep
                // returns immediately once cancelled).
                runOnboardingAfterInitialCloudGateIfNeeded()
                abortSyncRun(runID: runID)
                return
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
                cloudKitSyncLog.error("sync failed: \(error.localizedDescription, privacy: .private)")
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
                    if Task.isCancelled {
                        // Cancelled mid-backoff (debounce superseded the run):
                        // the sleep returned immediately and every further
                        // retry would too — yield to the upcoming run instead
                        // of burning the failure budget.
                        abortSyncRun(runID: runID)
                        return
                    }
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
        // Order matters: the full-fetch recovery reset clears the local-record
        // preservation flag (its reset doesn't preserve), so it must run BEFORE
        // the interrupted-clear recovery arms that flag — never after.
        try recoverPendingFullFetchRecoveryIfNeeded()
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

        let hasEngineState = hasActiveSyncEngine() ? true : try hasStoredSyncEngineState()
        if !hasEngineState {
            // A live engine (or one restored from stored state) surfaces account
            // changes itself via .accountChange; a fresh engine has nothing to
            // compare against and needs the explicit identity check — before the
            // zone ensure, so a switched account never sees the old account's
            // bookkeeping.
            try await verifyCloudKitAccountIdentity()
        }

        if zoneNeedsEnsure() {
            // CKModifyRecordZonesOperation is a full server round trip; do it once
            // per launch. zoneNotFound recovery paths reset the flag if the zone
            // disappears later.
            try await ensureRecordZone()
            setDidEnsureRecordZone(true)
        }
        let syncGeneration = currentEngineGeneration()
        if !hasEngineState {
            // Both passes only matter before a fresh engine enqueues pre-existing
            // rows (bootstrap / offline reconciliation / discontinuity probe):
            // seed marking keeps onboarding data out of the upload and the
            // orphan sweep keeps broken graphs from failing record builds.
            // Steady-state syncs were paying a write transaction plus full-table
            // scans per pass for rows the transactional write paths can't
            // produce.
            OnboardingManager.shared.markExistingOnboardingRecordsIfNeeded()
            try cleanupLocalCloudKitOrphans()
        }

        let freshEngineMode = try prepareFreshEngineOutbox(hasStoredEngineState: hasEngineState)

        // Before the engine exists: from the moment the engine can emit
        // events, shouldDeferStateUpdates() must already see the accumulator,
        // or an early .stateUpdate could persist a token while a probe/full
        // snapshot is still pending.
        beginFetchAccumulation(
            isFullSnapshot: !hasEngineState,
            prunesMissingLocalRecords: freshEngineMode.prunesMissingLocalRecords,
            probesZoneDiscontinuity: freshEngineMode.probesZoneDiscontinuity
        )
        let engine = try syncEngineInstance(expectedGeneration: syncGeneration)
        try ensureEngineGeneration(syncGeneration)
        try syncEnginePendingChangesFromOutbox(engine)
        do {
            try await engine.fetchChanges()
        } catch {
            discardFetchAccumulation()
            if isZoneNotFound(error) || isChangeTokenExpired(error) {
                try resetSyncEngineStateForZoneDiscontinuity(
                    cause: isZoneNotFound(error) ? .zoneLost : .tokenExpired
                )
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
        try await sendChangesAndCleanupUploadAssets(engine, generation: syncGeneration)
        try ensureEngineGeneration(syncGeneration)
        try syncEnginePendingChangesFromOutbox(engine)

        if try enqueueExpiredTombstonePurgesIfNeeded() {
            try syncEnginePendingChangesFromOutbox(engine)
            try ensureSyncEnabled()
            try markRemoteDataMayExistBeforeSendingOutboxIfNeeded()
            try await sendChangesAndCleanupUploadAssets(engine, generation: syncGeneration)
            try ensureEngineGeneration(syncGeneration)
            try syncEnginePendingChangesFromOutbox(engine)
        }

        if try resetForRequestedFullFetchIfNeeded() {
            runOnboardingAfterInitialCloudGateIfNeeded()
            return
        }

        let hasOutboxFailures = try hasOutboxFailures()
        let didDropOversizedRecords = takeDidDropOversizedRecords()
        try markRemoteDataMayExistIfCloudKitStateExists()
        if hasOutboxFailures {
            CloudKitSync.setLastError(String(localized: "settings.cloudKitSync.error.uploadFailed"))
        } else if didDropOversizedRecords {
            CloudKitSync.setLastError(String(localized: "settings.cloudKitSync.error.recordTooLarge"))
        } else {
            CloudKitSync.setLastError(nil)
        }
        runOnboardingAfterInitialCloudGateIfNeeded()
    }
}

extension CloudKitRecordSyncManager: CKSyncEngineDelegate {
    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        // Generation captured atomically with the identity gate: every
        // generation-guarded write below (the state-token persists in
        // particular) must be scoped to the engine THIS event came from.
        // Re-reading the current generation at write time would self-validate
        // after a reset that completed in between — and re-persist the very
        // token the reset just wiped.
        guard let eventGeneration = engineGenerationIfCurrent(syncEngine) else { return }
        do {
            switch event {
            case .stateUpdate(let stateUpdate):
                if shouldDeferStateUpdates() {
                    setPendingFetchStateSerialization(stateUpdate.stateSerialization, generation: eventGeneration)
                } else {
                    try persistSyncEngineStateSerialization(stateUpdate.stateSerialization, expectedGeneration: eventGeneration)
                }
            case .accountChange(let accountChange):
                try handleAccountChange(accountChange.changeType)
                requestFollowUpSync()
            case .fetchedDatabaseChanges(let changes):
                try handleFetchedDatabaseChanges(changes)
            case .fetchedRecordZoneChanges(let changes):
                try handleFetchedRecordZoneChanges(changes, generation: eventGeneration)
            case .sentDatabaseChanges(let changes):
                try handleSentDatabaseChanges(changes, syncEngine: syncEngine)
            case .sentRecordZoneChanges(let changes):
                try handleSentRecordZoneChanges(changes, syncEngine: syncEngine)
            case .didFetchRecordZoneChanges(let changes):
                if let error = changes.error, isZoneNotFound(error) || isChangeTokenExpired(error) {
                    discardFetchAccumulation()
                    try resetSyncEngineStateForZoneDiscontinuity(
                        cause: isZoneNotFound(error) ? .zoneLost : .tokenExpired
                    )
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
        } catch is CloudKitEngineSupersededError {
            // A reset/disable superseded this engine mid-event. Whoever bumped
            // the generation owns the recovery; surfacing the bare error would
            // pin a meaningless footer message.
            requestFollowUpSync()
        } catch {
            cloudKitSyncLog.error("sync engine event failed: \(error.localizedDescription, privacy: .private)")
            CloudKitSync.setLastError(error.localizedDescription)
            requestFollowUpSync()
        }
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        // Same gate as handleEvent: a superseded engine's internal send
        // operation cannot be cancelled and keeps requesting batches — it
        // must not read the live outbox (uploading after a disable/reset),
        // consume the server-record conflict cache, or stage asset files
        // under a stale generation.
        guard isCurrentSyncEngine(syncEngine) else { return nil }
        do {
            return try await makeRecordZoneChangeBatch(context: context, syncEngine: syncEngine)
        } catch {
            cloudKitSyncLog.error("sync engine batch failed: \(error.localizedDescription, privacy: .private)")
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

        // Checked FIRST: the manager's own post-apply .DatabaseUpdated echo
        // routinely lands while isApplyingRemoteChanges is still raised (the
        // flag drops only after the late-state drain). Classifying the echo
        // as a concurrent local edit would buy a wasted follow-up round after
        // nearly every apply. Real local edits never arrive inside the
        // posting window — they come through DatabaseUpdateNotifier on a
        // separate main-queue tick.
        if isPostingCloudKitOriginatedUpdate {
            return false
        }
        if isApplyingRemoteChanges {
            needsFollowUpSync = true
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
            throw CloudKitEngineSupersededError()
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
        wantsBackgroundTask = false
        let task = backgroundTaskIdentifier
        backgroundTaskIdentifier = .invalid
        stateLock.unlock()
        endBackgroundTask(task)
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
        wantsBackgroundTask = false
        let task = backgroundTaskIdentifier
        backgroundTaskIdentifier = .invalid
        stateLock.unlock()
        endBackgroundTask(task)
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
        let shouldStartBackgroundTask = wantsBackgroundTask
            && backgroundTaskIdentifier == .invalid
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

        endBackgroundTask(task)
    }

    func endBackgroundTask(_ task: UIBackgroundTaskIdentifier) {
        guard task != .invalid else { return }
        if Thread.isMainThread {
            UIApplication.shared.endBackgroundTask(task)
        } else {
            DispatchQueue.main.async {
                UIApplication.shared.endBackgroundTask(task)
            }
        }
    }

    /// The background task is one shared slot, not per-run. Paths that merely
    /// bounced off an active run (a failed exclusive beginSync, the
    /// queue-a-rebuild branch) must not strip THAT run's grace time — the
    /// active run ends the task itself when it finishes. A queued local-reset
    /// rebuild counts as active too: between its 500 ms retries nothing is
    /// syncing, but stripping the task there would let the app suspend with
    /// the rebuild still pending (its defer clears the flag, then re-enters
    /// here to end the task for real).
    func endBackgroundTaskIfIdle() {
        stateLock.lock()
        guard !isSyncing, !isLocalResetRebuildQueued else {
            stateLock.unlock()
            return
        }
        wantsBackgroundTask = false
        let task = backgroundTaskIdentifier
        backgroundTaskIdentifier = .invalid
        stateLock.unlock()
        endBackgroundTask(task)
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
        var task: UIBackgroundTaskIdentifier = .invalid
        if runID == syncRunID {
            isSyncing = false
            wantsBackgroundTask = false
            task = backgroundTaskIdentifier
            backgroundTaskIdentifier = .invalid
        }
        stateLock.unlock()
        endBackgroundTask(task)
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

    func markDidDropOversizedRecords() {
        stateLock.lock()
        didDropOversizedRecords = true
        stateLock.unlock()
    }

    func takeDidDropOversizedRecords() -> Bool {
        stateLock.lock()
        let value = didDropOversizedRecords
        didDropOversizedRecords = false
        stateLock.unlock()
        return value
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

    /// Atomic check-and-set: two concurrent callers (app launch + didBecomeActive,
    /// or a database-update trigger racing either) must not both queue a rebuild —
    /// the loser would run a SECOND full zone delete + re-upload after the winner
    /// finished.
    private func claimLocalResetRebuild() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !isLocalResetRebuildQueued else { return false }
        isLocalResetRebuildQueued = true
        return true
    }

    func rebuildCloudKitDataAfterLocalReset() {
        guard claimLocalResetRebuild() else {
            endBackgroundTaskIfIdle()
            return
        }

        Task {
            defer {
                self.setLocalResetRebuildQueued(false)
                self.endBackgroundTaskIfIdle()
            }
            while CloudKitSync.current == .enable {
                // A manual rebuild (settings) may have completed the reset
                // while this task waited for its turn — don't run a second
                // full zone delete + re-upload.
                guard CloudKitSync.pendingRemoteReset else { return }
                do {
                    _ = try await self.rebuildCloudKitData()
                    return
                } catch is CloudKitSyncInProgressError {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                } catch is CancellationError {
                    // Includes engine supersession (converted at the
                    // rebuildCloudKitData boundary).
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
            // No remote data to restore from — a leftover cascade-abort
            // recovery flag would only suppress the re-enable bootstrap.
            try CloudKitSyncState.clearPendingFullFetchRecovery(in: db)
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
        // Reset the engine state alongside arming the preservation flag, so
        // the flag is consumed by the IMMEDIATELY following fresh-engine pass
        // (keep + bootstrap merge). Merely setting the flag would let it go
        // stale when the interrupted clear never actually deleted the zone
        // (stored engine state intact, steady-state delta syncs resume) — a
        // stale preservation flag fired by a much later discontinuity probe
        // would force a full re-upload and resurrect long-deleted records.
        try resetSyncEngineStateForFullFetch(suppressesBootstrap: false, preservesLocalRecords: true)
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
        // Staged upload asset files are deliberately NOT deleted here: the
        // superseded engine's internal modify operation cannot be cancelled
        // and may still be streaming them. The superseded run's own
        // generation-scoped drain (sendChangesAndCleanupUploadAssets) removes
        // them once its sendChanges returns; anything truly orphaned is swept
        // from the temp directory on the next launch.
    }
}

extension CloudKitRecordSyncManager {
    func handleFetchedDatabaseChanges(_ changes: CKSyncEngine.Event.FetchedDatabaseChanges) throws {
        guard changes.deletions.contains(where: { $0.zoneID == CloudKitRecordName.zoneID }) else { return }
        try resetSyncEngineStateForZoneDiscontinuity(cause: .zoneLost)
        CloudKitSync.setLastError(String(localized: "settings.cloudKitSync.error.fullRefresh"))
        requestFollowUpSync()
    }

    func handleAccountChange(_ changeType: CKSyncEngine.Event.AccountChange.ChangeType) throws {
        switch changeType {
        case .signIn:
            // An account appeared where the engine saw none before (e.g. iCloud
            // became reachable again). Stored sync state belonging to a
            // *different* account would surface as .switchAccounts instead, so
            // the destructive wipe below would only throw away valid metadata
            // and disable sync for nothing. Re-ensure the zone and let the
            // follow-up sync continue.
            setDidEnsureRecordZone(false)
            return
        case .signOut, .switchAccounts:
            break
        @unknown default:
            // Unknown transitions get the conservative treatment below.
            break
        }

        cancelActiveOperations()
        endBackgroundTaskIfNeeded()
        setDidEnsureRecordZone(false)
        do {
            _ = try AppDatabase.shared.dbWriter?.write { db in
                // The new identity is unknown inside the engine event; the next
                // enable re-fetches and stores it.
                try Self.clearLocalStateForAccountSwitch(newUserRecordName: nil, in: db)
            }
        } catch {
            // The wipe failed (transient DB error): sync must still not stay
            // enabled under the new account with the old account's outbox and
            // metadata — the next send would upload them into the wrong
            // private database. The pending intent flags survive for a retry.
            CloudKitSync.disableAfterAccountChange()
            throw error
        }
        // Intent flags only drop once the wipe committed; clearing them first
        // would irrecoverably lose a pending clear/reset when the wipe throws.
        CloudKitSync.clearRemoteDataMayExist()
        CloudKitSync.setPendingRemoteReset(false)
        // An interrupted clear of the OLD account's zone must not be re-run
        // (or surfaced) against the new account.
        CloudKitSync.setPendingRemoteClear(false)
        // The account-change wipe above is a superset of the disable cleanup.
        CloudKitSync.setPendingDisableCleanup(false)

        CloudKitSync.disableAfterAccountChange()
    }

    /// The sync bookkeeping wipe shared by the live `.switchAccounts`/`.signOut`
    /// engine event and the stored-identity mismatch check
    /// (`verifyCloudKitAccountIdentity`). Local user records are preserved.
    static func clearLocalStateForAccountSwitch(newUserRecordName: String?, in db: Database) throws {
        try CloudKitSyncState.clearSyncEngineStateSerialization(in: db)
        try CloudKitSyncState.clearBootstrapSuppression(in: db)
        // The new account's zone has its own generation history.
        try CloudKitSyncState.clearZoneDiscontinuityProbe(in: db)
        try CloudKitSyncState.clearZoneGeneration(in: db)
        // A pending cascade-abort recovery targeted the OLD account's zone;
        // the preserve-and-bootstrap path below supersedes it.
        try CloudKitSyncState.clearPendingFullFetchRecovery(in: db)
        try CloudKitOutboxEntry.deleteAll(db)
        try CloudKitRecordMetadata.deleteAll(db)
        try CloudKitLocalTombstone.deleteAll(db)
        try CloudKitSettingRecord.deleteAll(db)
        // Without this flag the next fresh-engine fetch would set prunesMissing
        // LocalRecords=true and wipe user data to match the new account's zone.
        try CloudKitSyncState.preserveLocalRecordsForNextFullFetch(in: db)
        if let newUserRecordName {
            try CloudKitSyncState.setAccountUserRecordName(newUserRecordName, in: db)
        } else {
            try CloudKitSyncState.clearAccountUserRecordName(in: db)
        }
    }

    /// Detects an iCloud account switch that happened while no engine state was
    /// around to surface `.switchAccounts` — typically: sync disabled, account
    /// switched, sync re-enabled. Without this check the next fresh-engine full
    /// fetch would prune the entire local library against the new account's
    /// empty zone and upload leftover outbox entries into the wrong account.
    /// A mismatch gets the same wipe-and-preserve treatment as the live event,
    /// except sync stays enabled and the caller continues — the next
    /// fresh-engine pass bootstraps the local library into the new account's
    /// zone. A failed identity fetch aborts the caller (retryable) rather than
    /// guessing.
    /// Returns true when an account switch was detected and handled — callers
    /// about to run DESTRUCTIVE remote operations (rebuild, clear) must abort
    /// then, so the stale intent never executes against the new account's data.
    @discardableResult
    func verifyCloudKitAccountIdentity() async throws -> Bool {
        let currentUserRecordName = try await client.userRecordID().recordName
        return try applyVerifiedAccountIdentity(currentUserRecordName)
    }

    private func applyVerifiedAccountIdentity(_ currentUserRecordName: String) throws -> Bool {
        var storedUserRecordName: String?
        try AppDatabase.shared.dbWriter?.read { db in
            storedUserRecordName = try CloudKitSyncState.accountUserRecordName(in: db)
        }
        guard let storedUserRecordName else {
            _ = try AppDatabase.shared.dbWriter?.write { db in
                try CloudKitSyncState.setAccountUserRecordName(currentUserRecordName, in: db)
            }
            return false
        }
        guard storedUserRecordName != currentUserRecordName else { return false }

        cloudKitSyncLog.info("cloudkit account identity changed while no engine state existed; resetting sync bookkeeping")
        // An engine instance created under the old account must not keep
        // serving (its in-memory state token belongs to the old zone).
        invalidateSyncEngineForRedelivery()
        // DB wipe first; the UserDefaults intent flags only drop after the
        // transaction committed, so a failure leaves them for a retry.
        _ = try AppDatabase.shared.dbWriter?.write { db in
            try Self.clearLocalStateForAccountSwitch(newUserRecordName: currentUserRecordName, in: db)
        }
        setDidEnsureRecordZone(false)
        CloudKitSync.clearRemoteDataMayExist()
        CloudKitSync.setPendingRemoteReset(false)
        // An interrupted clear/reset of the OLD account's zone must not be
        // re-run against the new account.
        CloudKitSync.setPendingRemoteClear(false)
        CloudKitSync.setPendingDisableCleanup(false)
        return true
    }

    func handleFetchedRecordZoneChanges(_ changes: CKSyncEngine.Event.FetchedRecordZoneChanges, generation: UInt64) throws {
        appendFetchedRecordZoneChanges(changes, generation: generation)
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
        var failedEntries: [(entry: CloudKitOutboxEntry, error: Error)] = []
        var clearedEntries: [CloudKitOutboxEntry] = []
        var oversizedSnapshotEntries: [CloudKitOutboxEntry] = []
        var oversizedSaveRecordNames: [String] = []

        for entry in try loadOutboxEntries() {
            guard entry.id != nil,
                  let operation = entry.cloudKitOperation else {
                continue
            }
            switch operation {
            case .save, .delete:
                if let savedVersion = savedRecordVersions[entry.recordName],
                   savedVersion >= entry.localVersion {
                    clearedEntries.append(entry)
                } else if savedRecordVersions[entry.recordName] != nil {
                    requestFollowUpSync()
                } else if let failure = failedSaveResults[entry.recordName],
                          failure.version >= entry.localVersion {
                    failedEntries.append((entry, failure.error))
                    if isLimitExceeded(failure.error) {
                        oversizedSnapshotEntries.append(entry)
                        oversizedSaveRecordNames.append(entry.recordName)
                    }
                }
            case .purge:
                if deletedRecordNames.contains(entry.recordName) {
                    clearedEntries.append(entry)
                } else if let error = failedDeleteErrors[CloudKitRecordName.recordID(entry.recordName)] {
                    failedEntries.append((entry, error))
                }
            }
        }

        // .limitExceeded is permanent for a record (its payload exceeds
        // CloudKit's per-record cap): retrying every round would pin a generic
        // error footer forever and waste a send per round. Drop the entry and
        // surface a specific message — the record stays local-only; any later
        // local edit re-enqueues it (and gets re-dropped if still too large).
        let oversizedEntries = failedEntries.filter { isLimitExceeded($0.error) }
        if !oversizedEntries.isEmpty {
            failedEntries.removeAll { isLimitExceeded($0.error) }
            try dropOutbox(matching: oversizedSnapshotEntries)
            syncEngine.state.remove(pendingRecordZoneChanges: oversizedSaveRecordNames.map {
                .saveRecord(CloudKitRecordName.recordID($0))
            })
            // Dropped entries no longer count as outbox failures; the run-end
            // error update reads this flag, or the message would be erased
            // before the user ever sees it.
            markDidDropOversizedRecords()
            CloudKitSync.setLastError(String(localized: "settings.cloudKitSync.error.recordTooLarge"))
        }
        if failedEntries.contains(where: { isServerRecordChanged($0.error) }) {
            requestFollowUpSync()
        }
        // A peer deleted the zone between this round's fetch and send: every
        // save fails with zoneNotFound. Re-arm the zone ensure and request a
        // follow-up so recovery happens this run (the follow-up's fetch then
        // also detects the deletion) instead of stalling until the next
        // external trigger. Strictly zone-level codes here — isZoneNotFound
        // also matches per-record .unknownItem, which must not trigger a
        // zone round trip.
        let isZoneGone: (Error) -> Bool = { error in
            let code = (error as? CKError)?.code
            return code == .zoneNotFound || code == .userDeletedZone
        }
        if changes.failedRecordSaves.contains(where: { isZoneGone($0.error) })
            || failedDeleteErrors.values.contains(where: isZoneGone) {
            setDidEnsureRecordZone(false)
            requestFollowUpSync()
        }
        try markOutboxFailures(failedEntries)
        try clearOutbox(matching: clearedEntries)
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
        try dropOutbox(matching: batch.skippedEntries)
        if !batch.abortedCascadeEntries.isEmpty {
            let withdrawn = try abortLosingCascadeDeletes(batch.abortedCascadeEntries)
            let withdrawnChanges = withdrawn.flatMap { pendingRecordZoneChanges(for: $0) }
            if !withdrawnChanges.isEmpty {
                syncEngine.state.remove(pendingRecordZoneChanges: withdrawnChanges)
            }
        }

        guard !batch.recordsToSave.isEmpty || !batch.recordIDsToDelete.isEmpty else {
            let retiredEntries = !batch.skippedEntries.isEmpty
                || !batch.abortedCascadeEntries.isEmpty
            if (retiredEntries || !batch.failedEntries.isEmpty),
               try hasOutboxEntries(excludingMatching: batch.failedEntries.map(\.entry)) {
                requestFollowUpSync()
            }
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
        skippedEntries: [CloudKitOutboxEntry],
        failedEntries: [(entry: CloudKitOutboxEntry, error: Error)],
        changesToRemove: [CKSyncEngine.PendingRecordZoneChange],
        abortedCascadeEntries: [CloudKitOutboxEntry]
    ) {
        var recordsToSave: [CKRecord] = []
        var recordIDsToDelete: [CKRecord.ID] = []
        // Snapshot rows, not bare ids: the drop is conditioned on the row still
        // carrying this operation+localVersion (see dropOutbox(matching:)).
        var skippedEntries: [CloudKitOutboxEntry] = []
        var failedEntries: [(entry: CloudKitOutboxEntry, error: Error)] = []
        var changesToRemove: [CKSyncEngine.PendingRecordZoneChange] = []
        var abortedCascadeEntries: [CloudKitOutboxEntry] = []

        // Post/style deletes that lost to a newer active server record: the
        // whole cascade is withdrawn, not just the root — sending the child
        // deletes anyway would tombstone the (unmodified) children on the
        // server and converge every device to an empty shell.
        var lostCascadeRoots: Set<String> = []
        for entry in entries {
            guard entry.cloudKitOperation == .delete,
                  entry.cloudKitRecordType == .post || entry.cloudKitRecordType == .style,
                  let serverRecord = serverRecordState.activeRecordsByRecordName[entry.recordName],
                  modificationTime(of: serverRecord) > entry.modificationTime else { continue }
            lostCascadeRoots.insert(entry.recordName)
        }

        for entry in entries {
            guard entry.id != nil,
                  let type = entry.cloudKitRecordType,
                  let operation = entry.cloudKitOperation else {
                if entry.id != nil {
                    skippedEntries.append(entry)
                }
                continue
            }

            let pendingChanges = pendingRecordZoneChanges(for: entry).filter { scopedChanges.contains($0) }
            guard !pendingChanges.isEmpty else { continue }

            do {
                if operation == .delete, cascadeDeleteLost(
                    entry: entry,
                    type: type,
                    lostCascadeRoots: lostCascadeRoots,
                    serverRecordState: serverRecordState
                ) {
                    abortedCascadeEntries.append(entry)
                    changesToRemove.append(contentsOf: pendingChanges)
                    continue
                }
                if operation == .delete,
                   let serverTombstone = serverRecordState.tombstonesByDeletedRecordName[entry.recordName],
                   serverTombstone.deletionTime >= entry.modificationTime {
                    // Already tombstoned at an equal-or-newer time (a peer's
                    // delete landed between our fetch and this send). Uploading
                    // ours would REGRESS the wire deletionTime — a third
                    // device's offline edit between the two times would then
                    // wrongly win and resurrect the record everywhere. The
                    // newer tombstone reaches this device through the normal
                    // fetch; just retire the entry.
                    skippedEntries.append(entry)
                    changesToRemove.append(contentsOf: pendingChanges)
                    continue
                }
                if serverStateWins(entry: entry, operation: operation, against: serverRecordState) {
                    if operation == .purge {
                        // A purge only garbage-collects a server TOMBSTONE; any
                        // active record for the name makes it permanently moot.
                        // Drop it instead of requesting a full fetch — keeping
                        // the entry would re-run this dance every round (the
                        // expired-tombstone sweep re-enqueues purges while the
                        // local metadata still says deleted), and the active
                        // record reaches this device through the normal fetch
                        // anyway, flipping that metadata when it applies.
                        skippedEntries.append(entry)
                        changesToRemove.append(contentsOf: pendingChanges)
                        continue
                    }
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
                        skippedEntries.append(entry)
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
                failedEntries.append((entry, error))
                changesToRemove.append(contentsOf: pendingChanges)
            }
        }

        return (
            recordsToSave: recordsToSave,
            recordIDsToDelete: recordIDsToDelete,
            skippedEntries: skippedEntries,
            failedEntries: failedEntries,
            changesToRemove: changesToRemove,
            abortedCascadeEntries: abortedCascadeEntries
        )
    }

    private func cascadeDeleteLost(
        entry: CloudKitOutboxEntry,
        type: CloudKitRecordType,
        lostCascadeRoots: Set<String>,
        serverRecordState: ServerRecordState
    ) -> Bool {
        if type == .post || type == .style {
            return lostCascadeRoots.contains(entry.recordName)
        }
        switch CloudKitAggregateType(rawValue: entry.aggregateType) {
        case .postGraph, .styleGraph:
            if lostCascadeRoots.contains(entry.aggregateName) {
                return true
            }
            // The root entry may already be gone (cleared by a remote-wins
            // apply when the resurrected parent was fetched): arbitrate the
            // child against the parent's server state directly.
            if let parentRecord = serverRecordState.activeRecordsByRecordName[entry.aggregateName],
               modificationTime(of: parentRecord) > entry.modificationTime {
                return true
            }
            return false
        case .record, .setting, nil:
            return false
        }
    }

    /// Withdraws a lost cascade: drops the cascade's outbox entries (including
    /// same-cascade children outside the current batch window), their local
    /// tombstones and metadata in ONE transaction, and arms a durable
    /// full-fetch so the locally-deleted family is restored from the server.
    /// Local tombstone removal is what stops
    /// `enqueueDeletesForLocalTombstonesThatBeatActiveRemoteRecords` from
    /// re-tombstoning the unmodified children when the restore fetch lands;
    /// metadata removal stops a later offline reconciliation from reading
    /// "metadata alive, no local row" as an offline delete.
    /// Returns every withdrawn entry so the caller can clear their pending
    /// changes from the engine state.
    func abortLosingCascadeDeletes(_ entries: [CloudKitOutboxEntry]) throws -> [CloudKitOutboxEntry] {
        guard !entries.isEmpty else { return [] }
        var withdrawn: [CloudKitOutboxEntry] = []
        _ = try AppDatabase.shared.dbWriter?.write { db in
            let rootNames = entries
                .filter { $0.cloudKitRecordType == .post || $0.cloudKitRecordType == .style }
                .map(\.recordName)
            var swept = entries
            if !rootNames.isEmpty {
                let knownIDs = Set(entries.compactMap(\.id))
                let sweptChildren = try CloudKitOutboxEntry
                    .filter(CloudKitOutboxEntry.Columns.operation == CloudKitOutboxEntry.Operation.delete.rawValue)
                    .filter([CloudKitAggregateType.postGraph.rawValue, CloudKitAggregateType.styleGraph.rawValue].contains(CloudKitOutboxEntry.Columns.aggregateType))
                    .filter(rootNames.contains(CloudKitOutboxEntry.Columns.aggregateName))
                    .fetchAll(db)
                swept.append(contentsOf: sweptChildren.filter { child in
                    child.id.map { !knownIDs.contains($0) } ?? false
                })
            }
            for entry in swept {
                try CloudKitLocalTombstone.deleteOne(db, key: entry.recordName)
                try CloudKitRecordMetadata.deleteOne(db, key: entry.recordName)
            }
            try CloudKitOutboxEntry.drop(ids: swept.compactMap(\.id), in: db)
            try CloudKitSyncState.markPendingFullFetchRecovery(in: db)
            withdrawn = swept
        }
        evictCachedServerRecords(for: withdrawn.map(\.recordName))
        requestFullFetchAfterCurrentSync()
        cloudKitSyncLog.info("withdrew \(withdrawn.count, privacy: .public) cascade delete(s) that lost to newer server state")
        return withdrawn
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

        let physicalDeletedRecordNamesWithoutTombstone = Set(
            physicalDeletedRecords
                .map(\.recordName)
                .filter { $0 != CloudKitRecordName.zoneMetaName && tombstonesByDeletedRecordName[$0] == nil }
        )

        return RemoteChangeSet(
            activeRecordsByType: activeRecordsByType,
            tombstonesByDeletedRecordName: tombstonesByDeletedRecordName,
            physicalDeletedRecordNamesWithoutTombstone: physicalDeletedRecordNamesWithoutTombstone,
            zoneResetGeneration: zoneResetGeneration
        )
    }

    /// A tombstone-less physical delete is only suspicious when local metadata
    /// still believes the record is alive on the server — that means some other
    /// client deleted it out-of-band and only a full re-fetch reconciles. The
    /// two benign shapes — a peer purging an expired tombstone (metadata says
    /// deleted) and a record this device never synced (no metadata) — used to
    /// trigger a full zone re-fetch on every peer for nothing.
    func hasUnexplainedPhysicalDeletes(_ changes: RemoteChangeSet) throws -> Bool {
        let recordNames = changes.physicalDeletedRecordNamesWithoutTombstone
        guard !recordNames.isEmpty else { return false }
        var hasLiveMetadata = false
        try AppDatabase.shared.dbWriter?.read { db in
            hasLiveMetadata = try CloudKitRecordMetadata
                .filter(keys: Array(recordNames))
                .filter(Column(CloudKitRecordMetadata.CodingKeys.isDeleted) == false)
                .fetchCount(db) > 0
        }
        return hasLiveMetadata
    }

    /// Companion to `hasUnexplainedPhysicalDeletes`: before the recovery
    /// full-fetch resets the engine state, give every affected record that is
    /// still alive locally an outbox save. The recovery fetch prunes records
    /// missing from the snapshot, and a record lost to a purge-vs-resurrection
    /// race is exactly that — present locally, marked synced in metadata,
    /// absent from the server — so without this protection the locally-newest
    /// copy would be pruned instead of restored.
    func enqueueRecoverySavesForUnexplainedPhysicalDeletes(_ changes: RemoteChangeSet) throws {
        let recordNames = changes.physicalDeletedRecordNamesWithoutTombstone
        guard !recordNames.isEmpty else { return }
        _ = try AppDatabase.shared.dbWriter?.write { db in
            let now = try db.transactionDate.millisecondsSince1970
            for recordName in recordNames {
                guard let metadata = try CloudKitRecordMetadata.fetchOne(db, key: recordName),
                      !metadata.isDeleted,
                      let recordType = CloudKitRecordType(rawValue: metadata.recordType),
                      let syncId = CloudKitRecordName.syncId(from: recordName, type: recordType) else {
                    continue
                }
                // Staleness discriminator: protection is only legitimate when
                // this device's view of the record (metadata.updatedAt) is
                // younger than the tombstone retention window. Within it, a
                // legitimate delete's tombstone CANNOT have been purged yet —
                // so a tombstone-less physical delete really is the purge
                // race. Beyond it, a peer's delete + 30-day purge may have
                // completed entirely inside this device's blind spot, and
                // re-uploading would resurrect a deliberately deleted record
                // on every device; let the recovery prune take it instead.
                guard now - metadata.updatedAt < Self.tombstoneRetentionMilliseconds else { continue }
                let modificationTime: Int64?
                switch recordType {
                case .post:
                    modificationTime = try Post
                        .filter(Column(Post.CodingKeys.syncId) == syncId)
                        .fetchOne(db)?.modificationTime
                case .text:
                    modificationTime = try PostText
                        .filter(Column(PostText.CodingKeys.syncId) == syncId)
                        .fetchOne(db)?.modificationTime
                case .image:
                    modificationTime = try PostImage
                        .filter(Column(PostImage.CodingKeys.syncId) == syncId)
                        .fetchOne(db)?.modificationTime
                case .style:
                    modificationTime = try PostStyle
                        .filter(Column(PostStyle.CodingKeys.syncId) == syncId)
                        .fetchOne(db)?.modificationTime
                case .decoration:
                    modificationTime = try PostDecoration
                        .filter(Column(PostDecoration.CodingKeys.syncId) == syncId)
                        .fetchOne(db)?.modificationTime
                case .setting:
                    modificationTime = nil
                }
                // No local row: nothing to restore — the recovery fetch's
                // prune cleans the dangling metadata.
                guard let modificationTime else { continue }
                try enqueueCloudKitSaveIfNeeded(recordType: recordType, syncId: syncId, modificationTime: modificationTime, in: db)
            }
        }
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
            // The clear empties the zone; a pending cascade-abort restore
            // fetch has nothing left to restore.
            try CloudKitSyncState.clearPendingFullFetchRecovery(in: db)
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

    func isLimitExceeded(_ error: Error) -> Bool {
        (error as? CKError)?.code == .limitExceeded
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
            throw CloudKitEngineSupersededError()
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
            throw CloudKitEngineSupersededError()
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

    /// The current generation, but only while `engine` is still the live
    /// instance — both read under one lock acquisition, so callers get a
    /// generation that provably belongs to the engine they are handling an
    /// event for.
    func engineGenerationIfCurrent(_ engine: CKSyncEngine) -> UInt64? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard syncEngine === engine else { return nil }
        return engineGeneration
    }

    func hasActiveSyncEngine() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return syncEngine != nil
    }

    func loadSyncEngineStateSerialization() throws -> CKSyncEngine.State.Serialization? {
        do {
            var serialization: CKSyncEngine.State.Serialization?
            try AppDatabase.shared.dbWriter?.read { db in
                serialization = try CloudKitSyncState.syncEngineStateSerialization(in: db)
            }
            return serialization
        } catch let error as CloudKitSyncStateDecodingError {
            // Self-heal: discard the corrupt state and continue as a fresh
            // engine — one full re-fetch, with offline reconciliation covering
            // any local drift. Leaving it in place would wedge sync forever.
            cloudKitSyncLog.error("stored sync engine state failed to decode; discarding it: \(error.underlying.localizedDescription, privacy: .private)")
            _ = try AppDatabase.shared.dbWriter?.write { db in
                try CloudKitSyncState.clearSyncEngineStateSerialization(in: db)
            }
            return nil
        }
    }

    func hasStoredSyncEngineState() throws -> Bool {
        try loadSyncEngineStateSerialization() != nil
    }

    /// Decides the fresh-engine mode AND enqueues the outbox protection that
    /// mode implies in the SAME write transaction as the flag consumption.
    /// Consuming `preserveLocalOnNextFullFetch` in one transaction and
    /// enqueueing the bootstrap saves in another would open a crash window
    /// where the flag is gone but the protection never landed — the following
    /// full fetch would then prune the entire local library.
    func prepareFreshEngineOutbox(hasStoredEngineState: Bool) throws -> FreshEngineMode {
        guard !hasStoredEngineState else {
            return FreshEngineMode(bootstrapsLocalRecords: false, prunesMissingLocalRecords: false)
        }
        // Read through UserDefaults / the reader connection before entering the
        // write transaction.
        let bootstrapDefaultStyleSyncId = DefaultStyle.currentStyleSyncIdForCloudKit()
        // The reconciliation path reads the actual local UserDefaults selection,
        // not currentStyleSyncIdForCloudKit which would prefer the (potentially
        // stale) CloudKitSettingRecord when remoteDataMayExist is true. During
        // the disabled period the user may have changed the default style
        // locally and that change must propagate.
        let reconciliationDefaultStyleSyncId = DataManager.shared.fetchStyle(by: Int64(DefaultStyle.getValue().rawValue))?.syncId
        let remoteDataMayExist = CloudKitSync.remoteDataMayExist

        var mode = FreshEngineMode(bootstrapsLocalRecords: false, prunesMissingLocalRecords: false)
        _ = try AppDatabase.shared.dbWriter?.write { db in
            // The probe flag is read, not consumed: it's cleared atomically inside
            // the apply transaction together with the keep-vs-prune outcome, so a
            // crash between fetch and apply simply probes again.
            if try CloudKitSyncState.isZoneDiscontinuityProbePending(in: db) {
                // Keep-vs-prune is decided inside the apply transaction once the
                // snapshot's reset marker is known; don't enqueue anything yet.
                mode = FreshEngineMode(
                    bootstrapsLocalRecords: false,
                    prunesMissingLocalRecords: false,
                    probesZoneDiscontinuity: true
                )
                return
            }
            let suppressesBootstrap = try CloudKitSyncState.consumeBootstrapSuppression(in: db)
            let preservesLocalRecords = try CloudKitSyncState.consumeLocalRecordPreservation(in: db)
            let bootstrapsLocalRecords = preservesLocalRecords || (!suppressesBootstrap && !remoteDataMayExist)
            if bootstrapsLocalRecords {
                try CloudKitOutboxEntry.enqueueBootstrapSaves(in: db)
                try enqueueDefaultStyleSettingIfNeeded(syncId: bootstrapDefaultStyleSyncId, in: db)
            } else {
                // Fresh engine without bootstrap = re-enable on a device that
                // already synced before. Reconcile any drift accumulated while
                // sync was off so the upcoming full-fetch's remote-wins logic
                // doesn't clobber local edits and so offline deletes actually
                // reach CloudKit.
                try CloudKitOutboxEntry.enqueueOfflineReconciliation(in: db)
                try enqueueDefaultStyleSettingIfNeeded(syncId: reconciliationDefaultStyleSyncId, in: db)
            }
            // Prune local-only records on a fresh full fetch unless we're
            // explicitly bootstrapping (uploading local). When the remote zone
            // is canonical we want stale local records to disappear.
            mode = FreshEngineMode(
                bootstrapsLocalRecords: bootstrapsLocalRecords,
                prunesMissingLocalRecords: !bootstrapsLocalRecords
            )
        }
        return mode
    }

    /// `expectedGeneration` must be captured when the serialization was
    /// HANDED OVER (event entry / accumulator take), never re-read at call
    /// time: a reset that completed in between would otherwise self-validate
    /// — the fresh read returns the post-bump generation — and the stale
    /// token would overwrite the state that reset just wiped, cancelling the
    /// full re-fetch it queued.
    func persistSyncEngineStateSerialization(_ serialization: CKSyncEngine.State.Serialization, expectedGeneration: UInt64) throws {
        _ = try AppDatabase.shared.dbWriter?.write { db in
            // Re-checked on the writer queue: a disable/account-change cleanup
            // that bumped the generation between the caller's engine gate and
            // this write must win — re-persisting a stale token would
            // resurrect state the cleanup just deleted and make the next
            // re-enable skip offline reconciliation.
            guard expectedGeneration == self.currentEngineGeneration() else { return }
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
            // This reset IS the recovery a cascade abort armed: the flag is
            // consumed in the same transaction that guarantees the full
            // re-fetch.
            try CloudKitSyncState.clearPendingFullFetchRecovery(in: db)
        }
    }

    /// A cascade abort armed a durable full-fetch (the locally-withdrawn
    /// family must be restored from the server), but the engine-state reset
    /// may not have happened yet — the app could have died between the abort
    /// transaction and the end-of-run reset. Perform it here; the flag is
    /// consumed inside the reset transaction.
    func recoverPendingFullFetchRecoveryIfNeeded() throws {
        var isPending = false
        var probeIsPending = false
        try AppDatabase.shared.dbWriter?.read { db in
            isPending = try CloudKitSyncState.isPendingFullFetchRecovery(in: db)
            probeIsPending = try CloudKitSyncState.isZoneDiscontinuityProbePending(in: db)
        }
        guard isPending else { return }
        guard !probeIsPending else {
            // The discontinuity probe already forces a full re-fetch (and owns
            // the keep-vs-prune decision); the recovery intent is subsumed.
            _ = try AppDatabase.shared.dbWriter?.write { db in
                try CloudKitSyncState.clearPendingFullFetchRecovery(in: db)
            }
            return
        }
        try resetSyncEngineStateForFullFetch(suppressesBootstrap: true)
    }

    /// The zone disappeared (deleted by a peer, zoneNotFound, expired change
    /// token). Whether the local data should be kept (accidental loss → merge)
    /// or pruned (a peer deliberately rebuilt → adopt its snapshot) can only be
    /// decided once the next full fetch reveals the zone's reset marker, so
    /// just flag the probe here.
    func resetSyncEngineStateForZoneDiscontinuity(cause: ZoneDiscontinuityCause) throws {
        try resetSyncEngineState { db in
            try CloudKitSyncState.markZoneDiscontinuityProbe(cause: cause, in: db)
            try CloudKitSyncState.clearBootstrapSuppression(in: db)
            // The local-record-preservation flag deliberately survives this
            // reset: it encodes "local data must survive the next full fetch
            // and re-upload" (account change, interrupted-clear recovery), an
            // intent only the probe's keep-vs-prune decision can honor. The
            // probe consumes it inside the apply transaction.
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

    /// Generation-gated like the state-token writes: a stale event resuming
    /// after a reset must not repopulate (or re-create) the accumulator the
    /// reset just cleared — the next take would stamp the dead lineage's
    /// records with the NEW generation and sail them through the apply
    /// transaction's generation check. Dropped records re-deliver from the
    /// last persisted token.
    func appendFetchedRecordZoneChanges(_ changes: CKSyncEngine.Event.FetchedRecordZoneChanges, generation: UInt64) {
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
        guard generation == engineGeneration else {
            stateLock.unlock()
            return
        }
        if fetchAccumulator == nil {
            fetchAccumulator = FetchAccumulator(isFullSnapshot: false, prunesMissingLocalRecords: false)
        }
        fetchAccumulator?.changedRecords.append(contentsOf: changedRecords)
        fetchAccumulator?.physicalDeletedRecords.append(contentsOf: physicalDeletedRecords)
        stateLock.unlock()
    }

    /// Take both the accumulator and the pending state token under a single lock.
    /// Splitting them lets a `.stateUpdate` event sneak in between the two takes,
    /// flip out of accumulator-mode and persist its newer state to disk while we
    /// still hold the older value in memory — which would then overwrite it.
    /// Also returns the generation at take time: the apply transaction and the
    /// post-apply token persists are valid only for THIS lineage, and must be
    /// re-checked against it (not against a fresh read) on the writer queue.
    func takeFetchAccumulatorAndPendingState() -> (FetchAccumulator?, CKSyncEngine.State.Serialization?, UInt64) {
        stateLock.lock()
        let generation = engineGeneration
        let accumulator = fetchAccumulator
        let serialization = pendingFetchStateSerialization
        fetchAccumulator = nil
        pendingFetchStateSerialization = nil
        if accumulator != nil {
            // Raised INSIDE the same lock acquisition that empties the
            // accumulator: shouldDeferStateUpdates() must never observe
            // "no accumulator, not applying" while the just-taken batch is
            // still unapplied — a .stateUpdate landing in that window would
            // persist a token past it, and a crash before the apply commits
            // would skip those records forever. The caller lowers the flag.
            isApplyingRemoteChanges = true
        }
        stateLock.unlock()
        return (accumulator, serialization, generation)
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

    /// Generation-gated: a stale event handler resuming after a reset must not
    /// repopulate the slot the reset just cleared — the next round's take
    /// would persist the dead engine's token over the new lineage.
    func setPendingFetchStateSerialization(_ serialization: CKSyncEngine.State.Serialization, generation: UInt64) {
        stateLock.lock()
        if generation == engineGeneration {
            pendingFetchStateSerialization = serialization
        }
        stateLock.unlock()
    }

    /// Generation-gated like the setter: a stale caller draining after a reset
    /// must not consume (and then discard at its pinned persist) a token the
    /// NEW lineage deferred — that would cost the new lineage its own advance.
    func takePendingFetchStateSerialization(generation: UInt64) -> CKSyncEngine.State.Serialization? {
        stateLock.lock()
        guard generation == engineGeneration else {
            stateLock.unlock()
            return nil
        }
        let serialization = pendingFetchStateSerialization
        pendingFetchStateSerialization = nil
        stateLock.unlock()
        return serialization
    }

    func applyAccumulatedFetchIfNeeded() throws {
        let (maybeAccumulator, pendingState, generation) = takeFetchAccumulatorAndPendingState()
        guard let accumulator = maybeAccumulator else {
            // No accumulator taken — the applying flag was not raised.
            // Same guard as the post-apply drain below: with a full fetch
            // already requested (e.g. the unexplained-deletes or asset-retry
            // branch of an earlier call this pass), the batch behind this token
            // was NOT applied. Persisting it and dying before resetForRequested
            // FullFetchIfNeeded wipes the disk state would skip that batch
            // forever — the reset rewrites the token anyway.
            if let pendingState, !needsFullFetchAfterCurrentSyncIsRequested() {
                try persistSyncEngineStateSerialization(pendingState, expectedGeneration: generation)
            }
            return
        }
        // Raised atomically by the take above; lowered on every exit path.
        defer { setApplyingRemoteChanges(false) }
        let remoteChanges = makeRemoteChangeSet(
            changedRecords: accumulator.changedRecords,
            physicalDeletedRecords: accumulator.physicalDeletedRecords
        )

        let hasUnexplainedDeletes: Bool
        if accumulator.isFullSnapshot {
            hasUnexplainedDeletes = false
        } else {
            do {
                hasUnexplainedDeletes = try hasUnexplainedPhysicalDeletes(remoteChanges)
            } catch {
                // Same window as a failed apply below: the accumulator is already
                // consumed and the engine's in-memory token has moved past these
                // records. Without dropping the engine they would never be
                // re-delivered.
                invalidateSyncEngineForRedelivery()
                throw error
            }
        }

        if hasUnexplainedDeletes {
            // The suspicious shape is "metadata says alive, record physically
            // gone, no tombstone" — most plausibly an expired-tombstone purge
            // that raced a resurrection THIS device already applied (the purge
            // guard is check-then-act). The full re-fetch alone would PRUNE
            // the local copy: nothing re-delivers the record, its metadata
            // marks it as previously synced, and reconciliation can't protect
            // it (modificationTime == lastSyncedVersion after the acked
            // resurrection). Queue saves for the affected live rows first so
            // the outbox carries them through the prune and re-uploads them.
            do {
                try enqueueRecoverySavesForUnexplainedPhysicalDeletes(remoteChanges)
            } catch {
                invalidateSyncEngineForRedelivery()
                throw error
            }
            if let pendingState {
                setPendingFetchStateSerialization(pendingState, generation: generation)
            }
            requestFullFetchAfterCurrentSync()
            return
        }

        do {
            try applyRemoteChanges(
                remoteChanges,
                missingDependenciesAreOrphans: accumulator.isFullSnapshot,
                prunesMissingLocalRecords: accumulator.isFullSnapshot && accumulator.prunesMissingLocalRecords,
                probesZoneDiscontinuity: accumulator.isFullSnapshot && accumulator.probesZoneDiscontinuity,
                pendingStateSerialization: pendingState,
                expectedGeneration: generation
            )
            // Drain anything a late .stateUpdate dropped into the pending slot while
            // apply was running. If apply requested a full fetch, discard — reset will
            // wipe disk state anyway. Otherwise persist; it's monotonically newer than
            // what apply just wrote inside its txn.
            if let lateState = takePendingFetchStateSerialization(generation: generation),
               !needsFullFetchAfterCurrentSyncIsRequested() {
                try persistSyncEngineStateSerialization(lateState, expectedGeneration: generation)
            }
        } catch is CloudKitEngineSupersededError {
            // The generation bumped while this apply was staging: the taken
            // lineage is already dead and whoever bumped it owns recovery.
            // Invalidating here would bump AGAIN and stomp the SUCCESSOR's
            // live engine and accumulator. The disk token never advanced past
            // the taken batch, so it re-delivers to the new lineage anyway.
            throw CloudKitEngineSupersededError()
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
                try enqueueCloudKitDeleteIfNeeded(recordType: .text, syncId: text.syncId, deletionTime: text.modificationTime ?? db.transactionDate.millisecondsSince1970, in: db)
                if let textId = text.id {
                    try PostText.deleteAll(db, ids: [textId])
                }
                try OnboardingLocalRecord.unmark(recordType: .text, syncId: text.syncId, in: db)
                didChangeDatabase = true
            }

            for image in try PostImage.fetchAll(db) {
                guard try Post.fetchOne(db, id: image.postId) == nil else { continue }
                try enqueueCloudKitDeleteIfNeeded(recordType: .image, syncId: image.syncId, deletionTime: image.modificationTime ?? db.transactionDate.millisecondsSince1970, in: db)
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
                try enqueueCloudKitDeleteIfNeeded(recordType: .decoration, syncId: decoration.syncId, deletionTime: decoration.modificationTime ?? db.transactionDate.millisecondsSince1970, in: db)
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
            // The rebuild replaces the zone wholesale; a pre-rebuild cascade-
            // abort recovery flag would only force a pointless engine-state
            // reset and full re-download right after the rebuild finished.
            try CloudKitSyncState.clearPendingFullFetchRecovery(in: db)
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

    /// `generation` must be the CALLING RUN's generation, captured at run
    /// start — never re-read here. A superseded run reaching this call after
    /// the bump would otherwise adopt the successor's generation and its
    /// defer would drain files the successor is still streaming.
    func sendChangesAndCleanupUploadAssets(_ engine: CKSyncEngine, generation: UInt64) async throws {
        // Per-record cleanup runs in handleSentRecordZoneChanges; this drains anything
        // left behind when sendChanges throws or completes without acking every entry.
        // Generation-scoped: when this run got superseded mid-send, a newer run's
        // freshly staged files must survive this drain.
        defer { cleanupUploadAssetFiles(generation: generation) }
        try await engine.sendChanges()
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

    func hasOutboxEntries(excludingMatching excludedEntries: [CloudKitOutboxEntry] = []) throws -> Bool {
        var hasEntries = false
        try AppDatabase.shared.dbWriter?.read { db in
            if excludedEntries.isEmpty {
                hasEntries = try CloudKitOutboxEntry.fetchCount(db) > 0
            } else {
                hasEntries = try CloudKitOutboxEntry.hasEntries(excludingMatching: excludedEntries, in: db)
            }
        }
        return hasEntries
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
        let cutoff = Date().millisecondsSince1970 - Self.tombstoneRetentionMilliseconds
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

    func markOutboxFailures(_ failures: [(entry: CloudKitOutboxEntry, error: Error)]) throws {
        _ = try AppDatabase.shared.dbWriter?.write { db in
            for failure in failures {
                try CloudKitOutboxEntry.markFailed(matching: [failure.entry], error: failure.error, in: db)
            }
        }
    }

    /// Clear/drop only rows that still match the caller's snapshot
    /// (operation + localVersion). Between the snapshot read and this write —
    /// a full network round trip on the batch-build path — the row may have
    /// been upserted into a NEWER intent under the same record name (a save
    /// becoming the user's delete is the dangerous one); deleting by id alone
    /// would silently discard that intent forever, with nothing left to
    /// re-enqueue it.
    func clearOutbox(matching entries: [CloudKitOutboxEntry]) throws {
        guard !entries.isEmpty else { return }
        _ = try AppDatabase.shared.dbWriter?.write { db in
            try CloudKitOutboxEntry.clear(matching: entries, in: db)
        }
        evictCachedServerRecords(for: entries.map(\.recordName))
    }

    func dropOutbox(matching entries: [CloudKitOutboxEntry]) throws {
        guard !entries.isEmpty else { return }
        _ = try AppDatabase.shared.dbWriter?.write { db in
            try CloudKitOutboxEntry.drop(matching: entries, in: db)
        }
        evictCachedServerRecords(for: entries.map(\.recordName))
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
        var allRecordNames = Set(entries.map(\.recordName))
        // Cascade child deletes are arbitrated against their PARENT's server
        // state; fetch it even when the parent entry itself is not in this
        // batch (e.g. it was already cleared by a remote-wins apply).
        for entry in entries where entry.cloudKitOperation == .delete {
            switch CloudKitAggregateType(rawValue: entry.aggregateType) {
            case .postGraph, .styleGraph:
                allRecordNames.insert(entry.aggregateName)
            case .record, .setting, nil:
                break
            }
        }
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
                // Newest-deletion-wins on duplicates. Tie direction differs
                // from makeRemoteChangeSet (`>` there lets the later arrival
                // win; `>=` here keeps the first seen) — unobservable either
                // way: tombstones live in-place under the deleted record's
                // own recordName, so one result set never carries two
                // tombstones for the same record.
                if let existing = tombstonesByDeletedRecordName[tombstone.deletedRecordName],
                   existing.deletionTime >= tombstone.deletionTime {
                    continue
                }
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
        case .delete:
            // Local deletes proceed against an older server state OR a server tombstone
            // (where merging is a no-op). A NEWER active server record means another
            // device updated this record after our delete was queued — let server win
            // so we don't tombstone newer data.
            if let serverRecord = serverRecordState.activeRecordsByRecordName[recordName],
               modificationTime(of: serverRecord) > entryModificationTime {
                return true
            }
            return false
        case .purge:
            // A purge's modificationTime is its wall-clock enqueue time
            // (tombstone deletion + retention), NOT an LWW time — never compare
            // the two. Purges exist solely to garbage-collect server tombstone
            // records; ANY active server record (e.g. a legitimate resurrection
            // by a peer whose newer edit beat the tombstone) means the purge is
            // stale and must not physically delete live data.
            return serverRecordState.activeRecordsByRecordName[recordName] != nil
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
        if var entry = uploadAssetFilesByRecordName[recordName], entry.generation == engineGeneration {
            entry.urls.append(contentsOf: urls)
            uploadAssetFilesByRecordName[recordName] = entry
        } else {
            // A leftover entry from a superseded generation may still be
            // mid-upload on the old engine — orphan its files to the
            // launch-time temp-directory sweep instead of deleting them
            // out from under that upload.
            uploadAssetFilesByRecordName[recordName] = (engineGeneration, urls)
        }
        stateLock.unlock()
    }

    func cleanupUploadAssetFiles(for recordNames: [String]) {
        guard !recordNames.isEmpty else { return }
        stateLock.lock()
        let urls = recordNames.flatMap { recordName in
            uploadAssetFilesByRecordName.removeValue(forKey: recordName)?.urls ?? []
        }
        stateLock.unlock()
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Removes only the files staged under the given engine generation: an
    /// overlapping newer run's staged files must never be deleted out from
    /// under its in-flight upload by a superseded run's drain.
    func cleanupUploadAssetFiles(generation: UInt64) {
        stateLock.lock()
        var urls: [URL] = []
        for (recordName, entry) in uploadAssetFilesByRecordName where entry.generation == generation {
            urls.append(contentsOf: entry.urls)
            uploadAssetFilesByRecordName.removeValue(forKey: recordName)
        }
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
        // Cascade tag, written AFTER the payload clear: a tombstone belonging
        // to a post/style cascade keeps a reference to its parent so receivers
        // can arbitrate the whole cascade as one graph-level intent. Reuses
        // the existing postSyncId/styleSyncId schema fields (always nil on
        // individual-delete tombstones).
        switch CloudKitAggregateType(rawValue: entry.aggregateType) {
        case .postGraph:
            set(CloudKitRecordName.syncId(from: entry.aggregateName, type: .post), for: Field.postSyncId, on: record)
        case .styleGraph:
            set(CloudKitRecordName.syncId(from: entry.aggregateName, type: .style), for: Field.styleSyncId, on: record)
        case .record, .setting, nil:
            break
        }
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
        pendingStateSerialization: CKSyncEngine.State.Serialization? = nil,
        expectedGeneration: UInt64? = nil
    ) throws {
        let imageRecordNamesToStage = try imageRecordNamesToStage(changes)
        var stagedImageAssets = try stageImageAssets(changes, allowedRecordNames: imageRecordNamesToStage)
        let allStagedImageFiles = stagedImageAssets.values.flatMap(\.copiedFiles)
        // Read outside the write transaction (goes through DataManager's reader).
        // Needed by the probe's keep branch AND the empty-markerless-zone keep
        // branch of a pruning fetch below.
        let fallbackDefaultStyleSyncId = (probesZoneDiscontinuity || prunesMissingLocalRecords)
            ? DataManager.shared.fetchStyle(by: Int64(DefaultStyle.getValue().rawValue))?.syncId
            : nil
        var deletedImageFiles: [(String, CacheImageType)] = []
        var didChangeDatabase = false
        var didChangeStyles = false
        var didApplyRemoteUserContent = false
        var shouldRunOnboardingSetup = false
        var hasDeferredRemoteRecords = false
        var hasAssetIncompleteImageRecords = false
        var shouldPruneMissingLocalRecords = prunesMissingLocalRecords
        var protectsRecentMarkerlessMissingRecords = false

        do {
            try AppDatabase.shared.dbWriter?.write { db in
                try ensureSyncEnabled()
                // Re-checked on the writer queue: a local reset, account-change
                // wipe, or disable that bumped the generation while this apply
                // was staging (sync stays ENABLED during a reset, so the check
                // above does not cover it) must win. Committing afterwards
                // would re-insert fetched rows into the freshly wiped library —
                // and the pendingRemoteReset rebuild would then upload that
                // resurrected data to every device.
                if let expectedGeneration {
                    try ensureEngineGeneration(expectedGeneration)
                }
                if probesZoneDiscontinuity {
                    let storedGeneration = try CloudKitSyncState.zoneGeneration(in: db)
                    // Consumed inside the same transaction as the enqueues it
                    // guards; a crash before commit leaves both the probe and
                    // the preservation flag intact, so the next pass re-probes
                    // with identical inputs.
                    let preservesLocalRecords = try CloudKitSyncState.consumeLocalRecordPreservation(in: db)
                    let snapshotIsEmpty = remoteSnapshotRecordNames(changes).isEmpty
                    // A marker-less but POPULATED zone is ambiguous: it is only
                    // safe to prune against when zone identity provably survived
                    // (expired token). After a zoneLost the zone may have been
                    // recreated and repopulated by a single peer whose library
                    // lacks records other devices hold — those must merge, not die.
                    let probeCause = try CloudKitSyncState.zoneDiscontinuityProbeCause(in: db)
                    if preservesLocalRecords
                        || (changes.zoneResetGeneration == nil && (snapshotIsEmpty || probeCause != .tokenExpired)) {
                        // Explicit preservation (account change, interrupted-clear
                        // recovery) or a marker-less zone after accidental loss
                        // (empty, or repopulated by a peer's bootstrap): keep local
                        // data and re-upload — the pre-marker merge behavior.
                        try CloudKitOutboxEntry.enqueueBootstrapSaves(in: db)
                        try enqueueDefaultStyleSettingIfNeeded(syncId: fallbackDefaultStyleSyncId, in: db)
                    } else if let fetchedGeneration = changes.zoneResetGeneration, fetchedGeneration != storedGeneration {
                        // A peer deliberately rebuilt the zone (reset/rebuild/clear):
                        // adopt its snapshot. Previously-synced records missing from
                        // it are pruned below; pending local changes survive via the
                        // outbox protections inside the prune. Divergent local edits
                        // (made while sync was off, or not yet pulled by the
                        // rebuilding peer) gain that protection here.
                        try CloudKitOutboxEntry.enqueueDivergentSaves(in: db)
                        shouldPruneMissingLocalRecords = true
                    } else {
                        // Unchanged generation, or an expired change token against
                        // a marker-less live zone. Re-upload only local divergence;
                        // clean rows absent from the full snapshot were deleted
                        // remotely while this device was offline (their tombstones
                        // may have been purged past the retention window) — prune
                        // them instead of resurrecting them on every peer.
                        try CloudKitOutboxEntry.enqueueDivergentSaves(in: db)
                        try enqueueDefaultStyleSettingIfNeeded(syncId: fallbackDefaultStyleSyncId, in: db)
                        shouldPruneMissingLocalRecords = true
                    }
                    try CloudKitSyncState.clearZoneDiscontinuityProbe(in: db)
                }
                // A pruning fresh-engine fetch (re-enable on a device that
                // synced before) against an EMPTY marker-less zone is treated
                // as an out-of-band wipe only inside the retention window.
                // Against a NON-empty marker-less zone, keep pruning enabled
                // but let the prune pass protect/re-upload only the specific
                // recently-seen records missing from the snapshot. Using the
                // whole library's newest metadata would resurrect unrelated
                // old deletes after an offline reconciliation touched one row.
                if shouldPruneMissingLocalRecords,
                   !probesZoneDiscontinuity,
                   changes.zoneResetGeneration == nil,
                   try CloudKitRecordMetadata.fetchCount(db) > 0 {
                    if remoteSnapshotRecordNames(changes).isEmpty {
                        let newestMetadataUpdate = try Int64.fetchOne(
                            db,
                            sql: "SELECT MAX(updated_at) FROM cloudkit_record_metadata"
                        ) ?? 0
                        let now = try db.transactionDate.millisecondsSince1970
                        if now - newestMetadataUpdate < Self.tombstoneRetentionMilliseconds {
                            shouldPruneMissingLocalRecords = false
                            try CloudKitOutboxEntry.enqueueBootstrapSaves(in: db)
                            try enqueueDefaultStyleSettingIfNeeded(syncId: fallbackDefaultStyleSyncId, in: db)
                        }
                    } else {
                        protectsRecentMarkerlessMissingRecords = true
                        try enqueueDefaultStyleSettingIfNeeded(syncId: fallbackDefaultStyleSyncId, in: db)
                    }
                }
                if let fetchedGeneration = changes.zoneResetGeneration {
                    try CloudKitSyncState.setZoneGeneration(fetchedGeneration, in: db)
                }
                let pendingDeletes = try pendingDeleteOutboxByRecordName(in: db)
                let localTombstones = try CloudKitLocalTombstone.allByRecordName(in: db)
                // A physical delete of a record we already track as deleted is a
                // peer's expired-tombstone purge arriving. Close the lifecycle
                // here so the metadata/tombstone rows don't linger for another
                // retention period and make this device send its own purge for
                // an already-deleted record. Runs AFTER the snapshots above so
                // the LWW filtering below still sees the local tombstone, and
                // skips records with an active record in this very batch — a
                // same-batch recreate (stale or genuine) must go through the
                // tombstone-vs-active arbitration, not lose its tombstone here.
                let activeBatchRecordNames = activeSnapshotRecordNames(changes)
                // Names with a pending DELETE are also skipped: that delete is
                // about to re-create the tombstone on the server, and dropping
                // the metadata row here would make its eventual markSynced
                // no-op — leaving a server tombstone this device could never
                // garbage-collect (the purge sweep is keyed on metadata).
                for recordName in changes.physicalDeletedRecordNamesWithoutTombstone
                where !activeBatchRecordNames.contains(recordName) && pendingDeletes[recordName] == nil {
                    guard let metadata = try CloudKitRecordMetadata.fetchOne(db, key: recordName),
                          metadata.isDeleted else { continue }
                    try CloudKitRecordMetadata.deleteOne(db, key: recordName)
                    try CloudKitLocalTombstone.deleteOne(db, key: recordName)
                    _ = try CloudKitOutboxEntry
                        .filter(
                            CloudKitOutboxEntry.Columns.recordName == recordName
                            && CloudKitOutboxEntry.Columns.operation == CloudKitOutboxEntry.Operation.purge.rawValue
                        )
                        .deleteAll(db)
                }
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
                    guard remoteRecordHasRequiredApplyFields(record, type: .style) else {
                        cloudKitSyncLog.info("style import skipped: missing fields for \(record.recordID.recordName, privacy: .private)")
                        // LWW arbitration still applies (a judged-loser local
                        // intent left in the outbox would be pushed against the
                        // newer server version on every round); only the
                        // metadata advance is withheld for the never-applied
                        // record.
                        try clearOutboxIfRemoteWins(record, in: db)
                        try clearLocalTombstone(recordName: record.recordID.recordName, in: db)
                        continue
                    }
                    let didApply = try applyStyleRecord(record, in: db)
                    if didApply {
                        didChangeDatabase = true
                        didChangeStyles = true
                        didApplyRemoteUserContent = true
                    }
                    try clearOutboxIfRemoteWins(record, in: db)
                    try markServerRecordMetadata(record, type: .style, in: db)
                    try clearLocalTombstone(recordName: record.recordID.recordName, in: db)
                }
                for record in activeRemoteRecords(type: .post, changes: changes, pendingDeletes: pendingDeletes, localTombstones: localTombstones) {
                    try ensureSyncEnabled()
                    guard remoteRecordHasRequiredApplyFields(record, type: .post) else {
                        cloudKitSyncLog.info("post import skipped: missing fields for \(record.recordID.recordName, privacy: .private)")
                        // LWW arbitration still applies (a judged-loser local
                        // intent left in the outbox would be pushed against the
                        // newer server version on every round); only the
                        // metadata advance is withheld for the never-applied
                        // record.
                        try clearOutboxIfRemoteWins(record, in: db)
                        try clearLocalTombstone(recordName: record.recordID.recordName, in: db)
                        continue
                    }
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
                    guard remoteRecordHasRequiredApplyFields(record, type: .text) else {
                        cloudKitSyncLog.info("text import skipped: missing fields for \(record.recordID.recordName, privacy: .private)")
                        // LWW arbitration still applies (a judged-loser local
                        // intent left in the outbox would be pushed against the
                        // newer server version on every round); only the
                        // metadata advance is withheld for the never-applied
                        // record.
                        try clearOutboxIfRemoteWins(record, in: db)
                        try clearLocalTombstone(recordName: record.recordID.recordName, in: db)
                        continue
                    }
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
                        if !textApply.shouldSkipServerMetadata {
                            try markServerRecordMetadata(record, type: .text, in: db)
                            try clearLocalTombstone(recordName: record.recordID.recordName, in: db)
                        }
                    }
                    deletedImageFiles.append(contentsOf: textApply.deletedImageFiles)
                }
                for record in activeRemoteRecords(type: .image, changes: changes, pendingDeletes: pendingDeletes, localTombstones: localTombstones) {
                    try ensureSyncEnabled()
                    guard remoteRecordHasRequiredApplyFields(record, type: .image) else {
                        cloudKitSyncLog.info("image import skipped: missing fields for \(record.recordID.recordName, privacy: .private)")
                        // LWW arbitration still applies (a judged-loser local
                        // intent left in the outbox would be pushed against the
                        // newer server version on every round); only the
                        // metadata advance is withheld for the never-applied
                        // record.
                        try clearOutboxIfRemoteWins(record, in: db)
                        try clearLocalTombstone(recordName: record.recordID.recordName, in: db)
                        continue
                    }
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
                    // An incremental fetch delivered an image record without its
                    // asset files (transient download/staging failure). The
                    // engine's token has already moved past it, so without
                    // intervention the image would stay missing on this device
                    // until the record happens to change again remotely. Hold
                    // the state token and request one full re-fetch as a retry.
                    // On the full-snapshot pass itself (missingDependenciesAre
                    // Orphans) accept the skip instead — a still-missing asset
                    // there means it's gone server-side, and looping full
                    // fetches would never converge.
                    if imageApply.skippedForMissingAssets, !missingDependenciesAreOrphans {
                        hasAssetIncompleteImageRecords = true
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
                        if !imageApply.shouldSkipServerMetadata {
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
                    }
                    deletedImageFiles.append(contentsOf: imageApply.deletedImageFiles)
                }
                for record in activeRemoteRecords(type: .decoration, changes: changes, pendingDeletes: pendingDeletes, localTombstones: localTombstones) {
                    try ensureSyncEnabled()
                    guard remoteRecordHasRequiredApplyFields(record, type: .decoration) else {
                        cloudKitSyncLog.info("decoration import skipped: missing fields for \(record.recordID.recordName, privacy: .private)")
                        // LWW arbitration still applies (a judged-loser local
                        // intent left in the outbox would be pushed against the
                        // newer server version on every round); only the
                        // metadata advance is withheld for the never-applied
                        // record.
                        try clearOutboxIfRemoteWins(record, in: db)
                        try clearLocalTombstone(recordName: record.recordID.recordName, in: db)
                        continue
                    }
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
                        didChangeStyles = true
                        didApplyRemoteUserContent = true
                    }
                    if !decorationApply.isDeferred {
                        try clearOutboxIfRemoteWins(record, in: db)
                        if !decorationApply.shouldSkipServerMetadata {
                            try markServerRecordMetadata(record, type: .decoration, in: db)
                            try clearLocalTombstone(recordName: record.recordID.recordName, in: db)
                        }
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
                        aggregateType: tombstone.cascadeAggregateType,
                        aggregateName: tombstone.cascadeParentRecordName,
                        in: db
                    )
                    if let pendingDelete = pendingDeletes[tombstone.deletedRecordName],
                       pendingDelete.modificationTime > tombstone.deletionTime {
                        continue
                    }
                    let deletion = try applyTombstone(
                        tombstone,
                        batchTombstones: changes.tombstonesByDeletedRecordName,
                        pendingDeletes: pendingDeletes,
                        in: db
                    )
                    if deletion.didChangeDatabase {
                        didChangeDatabase = true
                        deletedImageFiles.append(contentsOf: deletion.deletedImageFiles)
                        if tombstone.deletedRecordType == .style || tombstone.deletedRecordType == .decoration {
                            didChangeStyles = true
                        }
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
                    let pruning = try pruneLocalRecordsMissingFromFullFetch(
                        changes,
                        protectsRecentMarkerlessMissingRecords: protectsRecentMarkerlessMissingRecords,
                        in: db
                    )
                    if pruning.didChangeDatabase {
                        didChangeDatabase = true
                        deletedImageFiles.append(contentsOf: pruning.deletedImageFiles)
                    }
                    if pruning.didChangeStyles {
                        didChangeStyles = true
                    }
                    if try Post.fetchCount(db) == 0 || PostStyle.fetchCount(db) == 0 {
                        shouldRunOnboardingSetup = true
                    }
                }

                if didApplyRemoteUserContent {
                    try ensureSyncEnabled()
                    let onboardingCleanup = try OnboardingManager.shared.removeLocalOnlyOnboardingData(in: db)
                    didChangeDatabase = onboardingCleanup.didChangeDatabase || didChangeDatabase
                    didChangeStyles = onboardingCleanup.didChangeStyles || didChangeStyles
                    if try Post.fetchCount(db) == 0 || PostStyle.fetchCount(db) == 0 {
                        shouldRunOnboardingSetup = true
                    }
                }

                try ensureSyncEnabled()
                if hasDeferredRemoteRecords || hasAssetIncompleteImageRecords {
                    // The "needs full fetch" intent is in-memory only. If we also
                    // advanced the on-disk state token here, a kill before reset
                    // ForRequestedFullFetchIfNeeded would leave us past the deferred
                    // record permanently. Leave the token at its previous value so
                    // CKSyncEngine re-delivers everything on next launch.
                    cloudKitSyncLog.info("deferred remote records until their dependencies or assets arrive")
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
        // Cached conflict records for anything this batch touched are stale
        // now (clearOutboxIfRemoteWins deletes entries in-txn without passing
        // through the evicting clear/drop helpers). A later re-enqueued save
        // consuming a stale base would burn a guaranteed serverRecordChanged
        // round trip.
        evictCachedServerRecords(for: Array(remoteSnapshotRecordNames(changes)))
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
        if didChangeStyles {
            // Style menus (PostCell) listen to .DatabaseStyleUpdated only;
            // without this a remotely renamed/deleted style stays stale in
            // visible cells' menus until the next local style edit.
            postCloudKitOriginatedUpdate(.DatabaseStyleUpdated)
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
                    aggregateType: tombstone.cascadeAggregateType ?? .record,
                    aggregateName: tombstone.aggregateName,
                    in: db
                )
            }
        }
    }

    func visibleRemoteTombstones(_ changes: RemoteChangeSet) -> [RemoteTombstone] {
        Array(changes.tombstonesByDeletedRecordName.values)
    }

    func pruneLocalRecordsMissingFromFullFetch(
        _ changes: RemoteChangeSet,
        protectsRecentMarkerlessMissingRecords: Bool = false,
        in db: Database
    ) throws -> (didChangeDatabase: Bool, didChangeStyles: Bool, deletedImageFiles: [(String, CacheImageType)]) {
        let remoteRecordNames = remoteSnapshotRecordNames(changes)
        var pendingSaveRecordNames = try pendingSaveOutboxRecordNames(in: db)
        let metadataByRecordName = Dictionary(
            uniqueKeysWithValues: try CloudKitRecordMetadata.fetchAll(db).map { ($0.recordName, $0) }
        )
        let knownRecordNames = Set(metadataByRecordName.keys)
        var defaultStyleSyncId = try CloudKitSettingRecord.current(in: db).defaultStyleSyncId
        let pruneReferenceTime = try db.transactionDate.millisecondsSince1970
        var didChangeDatabase = false
        var didChangeStyles = false
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
        func shouldProtectRecentMarkerlessMissingRecord(_ recordName: String) -> Bool {
            guard protectsRecentMarkerlessMissingRecords,
                  !remoteRecordNames.contains(recordName),
                  !pendingSaveRecordNames.contains(recordName),
                  let metadata = metadataByRecordName[recordName],
                  !metadata.isDeleted else {
                return false
            }
            return pruneReferenceTime - metadata.updatedAt < Self.tombstoneRetentionMilliseconds
        }

        func shouldPrune(_ recordName: String) -> Bool {
            knownRecordNames.contains(recordName)
                && !remoteRecordNames.contains(recordName)
                && !pendingSaveRecordNames.contains(recordName)
                && !shouldProtectRecentMarkerlessMissingRecord(recordName)
        }

        // Graph-loop re-uploads must register in the in-memory set too, not
        // just the outbox: the style loop below consults
        // pendingSaveRecordNames, and a decoration enqueued by the post loop
        // would otherwise be invisible to its style's protection check — the
        // style prune's cascade would delete the row whose save is pending.
        func enqueueGraphMemberSave(
            recordType: CloudKitRecordType,
            syncId: String,
            recordName: String,
            modificationTime: Int64?
        ) throws {
            if try enqueueCloudKitSaveIfNeeded(recordType: recordType, syncId: syncId, modificationTime: modificationTime, in: db) {
                pendingSaveRecordNames.insert(recordName)
            }
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
            let recentlyProtectedRecordNames = Set(graphRecordNames.filter(shouldProtectRecentMarkerlessMissingRecord))
            let hasPendingGraphSave = graphRecordNames.contains { pendingSaveRecordNames.contains($0) }
            if hasPendingGraphSave || !recentlyProtectedRecordNames.isEmpty {
                let postMissingRemotely = !remoteRecordNames.contains(post.cloudKitRecordName)
                let recreatesMissingGraph = postMissingRemotely
                var graphVersionRecordNames = Set([post.cloudKitRecordName])
                if recreatesMissingGraph {
                    protectedRecordNames.formUnion(graphRecordNames)
                    graphVersionRecordNames.formUnion(graphRecordNames)
                } else {
                    protectedRecordNames.insert(post.cloudKitRecordName)
                    let protectedChildRecordNames = graphRecordNames.filter {
                        $0 != post.cloudKitRecordName
                            && (pendingSaveRecordNames.contains($0) || recentlyProtectedRecordNames.contains($0))
                    }
                    protectedRecordNames.formUnion(protectedChildRecordNames)
                    graphVersionRecordNames.formUnion(protectedChildRecordNames)
                }
                var graphModificationTime = post.modificationTime ?? 0
                for image in images where graphVersionRecordNames.contains(image.cloudKitRecordName) {
                    graphModificationTime = max(graphModificationTime, image.modificationTime ?? 0)
                }
                for text in texts where graphVersionRecordNames.contains(text.cloudKitRecordName) {
                    graphModificationTime = max(graphModificationTime, text.modificationTime ?? 0)
                }
                for decoration in decorations where graphVersionRecordNames.contains(decoration.cloudKitRecordName) {
                    graphModificationTime = max(graphModificationTime, decoration.modificationTime ?? 0)
                }
                if graphModificationTime > (post.modificationTime ?? 0) {
                    try Post
                        .filter(Column(Post.CodingKeys.id) == postId)
                        .updateAll(db, Column(Post.CodingKeys.modificationTime).set(to: graphModificationTime))
                }
                try CloudKitOutboxEntry.enqueueSave(recordType: .post, syncId: post.syncId, modificationTime: graphModificationTime, in: db)
                pendingSaveRecordNames.insert(post.cloudKitRecordName)
                // Only when the POST ITSELF is missing remotely is this a true
                // graph re-creation (peer rebuilt without it / never had it) —
                // then the re-upload must carry the children too, or peers
                // adopt an empty shell. When the post is alive in the snapshot,
                // re-upload only children with explicit local/preserved intent.
                if recreatesMissingGraph {
                    for text in texts where !remoteRecordNames.contains(text.cloudKitRecordName) {
                        try enqueueGraphMemberSave(recordType: .text, syncId: text.syncId, recordName: text.cloudKitRecordName, modificationTime: text.modificationTime)
                    }
                    for image in images where !remoteRecordNames.contains(image.cloudKitRecordName) {
                        try enqueueGraphMemberSave(recordType: .image, syncId: image.syncId, recordName: image.cloudKitRecordName, modificationTime: image.modificationTime)
                    }
                    for decoration in decorations where !remoteRecordNames.contains(decoration.cloudKitRecordName) {
                        try enqueueGraphMemberSave(recordType: .decoration, syncId: decoration.syncId, recordName: decoration.cloudKitRecordName, modificationTime: decoration.modificationTime)
                    }
                } else {
                    for text in texts where recentlyProtectedRecordNames.contains(text.cloudKitRecordName) {
                        try enqueueGraphMemberSave(recordType: .text, syncId: text.syncId, recordName: text.cloudKitRecordName, modificationTime: text.modificationTime)
                    }
                    for image in images where recentlyProtectedRecordNames.contains(image.cloudKitRecordName) {
                        try enqueueGraphMemberSave(recordType: .image, syncId: image.syncId, recordName: image.cloudKitRecordName, modificationTime: image.modificationTime)
                    }
                    for decoration in decorations where recentlyProtectedRecordNames.contains(decoration.cloudKitRecordName) {
                        try enqueueGraphMemberSave(recordType: .decoration, syncId: decoration.syncId, recordName: decoration.cloudKitRecordName, modificationTime: decoration.modificationTime)
                    }
                }
                continue
            }
            guard shouldPrune(post.cloudKitRecordName) else { continue }
            try PostImage.deleteAll(db, ids: images.compactMap(\.id))
            try PostText.deleteAll(db, ids: texts.compactMap(\.id))
            try PostDecoration.deleteAll(db, ids: decorations.compactMap(\.id))
            try Post.deleteAll(db, ids: [postId])
            if !decorations.isEmpty {
                didChangeStyles = true
            }
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
        let styles = try PostStyle.fetchAll(db).sorted { lhs, rhs in
            if lhs.syncId == defaultStyleSyncId {
                return true
            }
            if rhs.syncId == defaultStyleSyncId {
                return false
            }
            return (lhs.id ?? Int64.max) < (rhs.id ?? Int64.max)
        }
        for style in styles {
            guard let styleId = style.id else { continue }
            let decorations = try PostDecoration
                .filter(Column(PostDecoration.CodingKeys.styleId) == styleId)
                .fetchAll(db)
            let graphRecordNames = [style.cloudKitRecordName] + decorations.map(\.cloudKitRecordName)
            let recentlyProtectedRecordNames = Set(graphRecordNames.filter(shouldProtectRecentMarkerlessMissingRecord))
            let hasPendingGraphSave = graphRecordNames.contains { pendingSaveRecordNames.contains($0) }
            let hasPendingDefaultSetting = pendingSaveRecordNames.contains(CloudKitRecordName.settingsName)
                && defaultStyleSyncId == style.syncId
            let styleMissingRemotely = !remoteRecordNames.contains(style.cloudKitRecordName)
            // A graph member an earlier loop chose to keep (e.g. a decoration
            // alive in the snapshot whose recreated post graph was protected
            // above) must drag a missing style into the protective branch too:
            // pruning the style would cascade-delete the kept decoration.
            let hasProtectedGraphMember = styleMissingRemotely
                && graphRecordNames.contains { protectedRecordNames.contains($0) }
            if hasPendingGraphSave || hasPendingDefaultSetting || hasProtectedGraphMember || !recentlyProtectedRecordNames.isEmpty {
                let recreatesMissingGraph = styleMissingRemotely
                var graphVersionRecordNames = Set([style.cloudKitRecordName])
                if recreatesMissingGraph {
                    protectedRecordNames.formUnion(graphRecordNames)
                    graphVersionRecordNames.formUnion(graphRecordNames)
                } else {
                    protectedRecordNames.insert(style.cloudKitRecordName)
                    let protectedChildRecordNames = graphRecordNames.filter {
                        $0 != style.cloudKitRecordName
                            && (pendingSaveRecordNames.contains($0) || recentlyProtectedRecordNames.contains($0))
                    }
                    protectedRecordNames.formUnion(protectedChildRecordNames)
                    graphVersionRecordNames.formUnion(protectedChildRecordNames)
                }
                var graphModificationTime = style.modificationTime ?? 0
                for decoration in decorations where graphVersionRecordNames.contains(decoration.cloudKitRecordName) {
                    graphModificationTime = max(graphModificationTime, decoration.modificationTime ?? 0)
                }
                if graphModificationTime > (style.modificationTime ?? 0) {
                    try PostStyle
                        .filter(Column(PostStyle.CodingKeys.id) == styleId)
                        .updateAll(db, Column(PostStyle.CodingKeys.modificationTime).set(to: graphModificationTime))
                }
                try CloudKitOutboxEntry.enqueueSave(recordType: .style, syncId: style.syncId, modificationTime: graphModificationTime, in: db)
                pendingSaveRecordNames.insert(style.cloudKitRecordName)
                // Same discriminator as the protected post graph above: only a
                // style missing remotely is being re-created and needs its
                // decorations carried along; a live remote style with a missing
                // decoration means that decoration was deleted elsewhere.
                if recreatesMissingGraph {
                    for decoration in decorations where !remoteRecordNames.contains(decoration.cloudKitRecordName) {
                        try enqueueGraphMemberSave(recordType: .decoration, syncId: decoration.syncId, recordName: decoration.cloudKitRecordName, modificationTime: decoration.modificationTime)
                    }
                } else {
                    for decoration in decorations where recentlyProtectedRecordNames.contains(decoration.cloudKitRecordName) {
                        try enqueueGraphMemberSave(recordType: .decoration, syncId: decoration.syncId, recordName: decoration.cloudKitRecordName, modificationTime: decoration.modificationTime)
                    }
                }
                continue
            }
            guard shouldPrune(style.cloudKitRecordName) else { continue }
            // syncId order — deterministic across devices; see delete(style:).
            let fallbackStyle = try PostStyle
                .filter(PostStyle.Columns.id != styleId)
                .order(Column(PostStyle.CodingKeys.syncId).asc)
                .fetchOne(db)
            try PostDecoration.deleteAll(db, ids: decorations.compactMap(\.id))
            try PostStyle.deleteAll(db, ids: [styleId])
            let fallbackModificationTime = try db.transactionDate.millisecondsSince1970
            if try DefaultStyle.replaceDeletedStyleIfNeeded(
                deletedStyle: style,
                fallbackStyle: fallbackStyle,
                modificationTime: fallbackModificationTime,
                in: db
            ) {
                try CloudKitOutboxEntry.enqueueSetting(modificationTime: fallbackModificationTime, in: db)
                pendingSaveRecordNames.insert(CloudKitRecordName.settingsName)
                defaultStyleSyncId = try CloudKitSettingRecord.current(in: db).defaultStyleSyncId
                if let fallbackStyle,
                   defaultStyleSyncId == fallbackStyle.syncId,
                   try !OnboardingLocalRecord.isMarked(recordType: .style, syncId: fallbackStyle.syncId, in: db) {
                    try CloudKitOutboxEntry.enqueueSave(
                        recordType: .style,
                        syncId: fallbackStyle.syncId,
                        modificationTime: fallbackStyle.modificationTime,
                        in: db
                    )
                    pendingSaveRecordNames.insert(fallbackStyle.cloudKitRecordName)
                    protectedRecordNames.insert(fallbackStyle.cloudKitRecordName)
                }
            }
            try OnboardingLocalRecord.unmark(recordType: .style, syncId: style.syncId, in: db)
            try OnboardingLocalRecord.unmark(recordType: .decoration, syncIds: decorations.map(\.syncId), in: db)
            try clearPrunedRecordState(graphRecordNames)
            didChangeDatabase = true
            didChangeStyles = true
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
            didChangeStyles = true
        }

        if !remoteRecordNames.contains(CloudKitRecordName.settingsName) {
            if shouldProtectRecentMarkerlessMissingRecord(CloudKitRecordName.settingsName) {
                let setting = try CloudKitSettingRecord.current(in: db)
                let modificationTime = setting.defaultStyleModificationTime > 0
                    ? setting.defaultStyleModificationTime
                    : pruneReferenceTime
                try CloudKitOutboxEntry.enqueueSetting(modificationTime: modificationTime, in: db)
                pendingSaveRecordNames.insert(CloudKitRecordName.settingsName)
            } else if !pendingSaveRecordNames.contains(CloudKitRecordName.settingsName) {
                if try DefaultStyle.clearCloudKitStateForMissingRemoteSetting(in: db) {
                    didChangeDatabase = true
                }
                try CloudKitRecordMetadata.deleteOne(db, key: CloudKitRecordName.settingsName)
            }
        }

        return (didChangeDatabase, didChangeStyles, deletedImageFiles)
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
            if remoteModificationTime > deletionTime {
                // The incoming child is strictly newer than its parent's
                // deletion: a peer rescued the family (graph arbitration) and
                // its parent save is still in flight — sends are not atomic.
                // Re-tombstoning the child at its own time here would kill the
                // rescue on every device.
                if let localId {
                    // Parent row still alive locally: apply the child; the
                    // raised graph time makes the pending parent tombstone
                    // lose its arbitration.
                    return .available(localId)
                }
                if missingDependenciesAreOrphans {
                    // Full snapshot: a rescue save for the parent would be IN
                    // the snapshot — its absence means the rescue never landed
                    // and the deletion is canonical server-side. Deferring
                    // here would loop full fetches forever. Same policy as the
                    // orphan conversion below: delete at the child's own time,
                    // so the entry survives clearOutboxIfRemoteWins and
                    // propagates (a lower time would be erased in-loop and
                    // never reach the server). The apply loop preserves the
                    // local tombstone metadata for this judged-loser remote
                    // record so a later reconciliation does not reinterpret it
                    // as a live row missing locally.
                    return .deleted(remoteModificationTime)
                }
                // Incremental fetch, parent already gone here: defer until
                // the rescue save arrives and resurrects it.
                return .missing
            }
            return .deleted(deletionTime)
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
        // An active remote record arriving for this name means the record is
        // alive again (or never died here) — a pending purge left over from an
        // earlier interrupted send would otherwise survive (its wall-clock
        // enqueue time defeats clearOutboxIfRemoteWins' LWW comparison) and
        // later physically delete the live record from the server.
        _ = try CloudKitOutboxEntry
            .filter(
                CloudKitOutboxEntry.Columns.recordName == recordName
                && CloudKitOutboxEntry.Columns.operation == CloudKitOutboxEntry.Operation.purge.rawValue
            )
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
    /// Mirrors the required-field guards inside the apply functions. A record
    /// failing them must be skipped WITHOUT advancing its metadata: marking a
    /// never-applied record as synced leaves "metadata alive, no local row"
    /// behind, which a later offline reconciliation misreads as an offline
    /// delete and pushes a tombstone — deleting the record on every device.
    /// (The image apply guards its asset-skip case the same way.)
    func remoteRecordHasRequiredApplyFields(_ record: CKRecord, type: CloudKitRecordType) -> Bool {
        switch type {
        case .post:
            return stringValue(Field.syncId, in: record) != nil
                && boolValue(Field.isPinned, in: record) != nil
                && int64Value(Field.order, in: record) != nil
        case .text:
            return stringValue(Field.syncId, in: record) != nil
                && stringValue(Field.postSyncId, in: record) != nil
                && stringValue(Field.content, in: record) != nil
                && int64Value(Field.order, in: record) != nil
        case .image:
            return stringValue(Field.syncId, in: record) != nil
                && stringValue(Field.postSyncId, in: record) != nil
                && int64Value(Field.orientation, in: record) != nil
                && int64Value(Field.minX, in: record) != nil
                && int64Value(Field.minY, in: record) != nil
                && int64Value(Field.maxX, in: record) != nil
                && int64Value(Field.maxY, in: record) != nil
                && int64Value(Field.order, in: record) != nil
        case .style:
            return stringValue(Field.syncId, in: record) != nil
                && stringValue(Field.name, in: record) != nil
                && stringValue(Field.symbol, in: record) != nil
                && intValue(Field.lockTextSize, in: record) != nil
                && intValue(Field.lockTextAlignment, in: record) != nil
                && intValue(Field.islandTextSize, in: record) != nil
                && intValue(Field.islandTextAlignment, in: record) != nil
                && intValue(Field.symbolAngle, in: record) != nil
                && intValue(Field.imageDisplayMode, in: record) != nil
                && intValue(Field.controlAlpha, in: record) != nil
        case .decoration:
            return stringValue(Field.syncId, in: record) != nil
                && stringValue(Field.postSyncId, in: record) != nil
                && stringValue(Field.styleSyncId, in: record) != nil
        case .setting:
            // All setting fields are optional, and offline reconciliation
            // explicitly skips the setting record.
            return true
        }
    }

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
    ) throws -> (didChangeDatabase: Bool, isDeferred: Bool, deletedImageFiles: [(String, CacheImageType)], shouldSkipServerMetadata: Bool) {
        guard let syncId = stringValue(Field.syncId, in: record),
              let postSyncId = stringValue(Field.postSyncId, in: record),
              let content = stringValue(Field.content, in: record),
              let order = int64Value(Field.order, in: record) else {
            cloudKitSyncLog.info("text import skipped: missing fields for \(record.recordID.recordName, privacy: .private)")
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
            let deleteIntent = try enqueueCloudKitDeleteIfNeeded(recordType: .text, syncId: syncId, deletionTime: deletionTime, in: db)
            return (false, false, [], deleteIntent.shouldSkipServerMetadata)
        case .missing:
            return (false, true, [], false)
        }
        let existing = try PostText
            .filter(Column(PostText.CodingKeys.syncId) == syncId)
            .fetchOne(db)
        guard existing == nil || remoteModificationTime > (existing?.modificationTime ?? 0) else { return (false, false, [], false) }

        let images = try PostImage
            .filter(Column(PostImage.CodingKeys.postId) == postId)
            .fetchAll(db)
        if let latestImageModificationTime = images.map({ $0.modificationTime ?? 0 }).max(),
           latestImageModificationTime > remoteModificationTime {
            let deleteIntent = try enqueueCloudKitDeleteIfNeeded(
                recordType: .text,
                syncId: syncId,
                deletionTime: latestImageModificationTime,
                in: db
            )
            return (false, false, [], deleteIntent.shouldSkipServerMetadata)
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
        return (true, false, imageFiles(for: images), false)
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
    ) throws -> (didChangeDatabase: Bool, isDeferred: Bool, deletedImageFiles: [(String, CacheImageType)], skippedForMissingAssets: Bool, shouldSkipServerMetadata: Bool) {
        guard let syncId = stringValue(Field.syncId, in: record),
              let postSyncId = stringValue(Field.postSyncId, in: record),
              let orientation = int64Value(Field.orientation, in: record),
              let minX = int64Value(Field.minX, in: record),
              let minY = int64Value(Field.minY, in: record),
              let maxX = int64Value(Field.maxX, in: record),
              let maxY = int64Value(Field.maxY, in: record),
              let order = int64Value(Field.order, in: record) else {
            cloudKitSyncLog.info("image import skipped: missing fields for \(record.recordID.recordName, privacy: .private)")
            return (false, false, [], false, false)
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
            let deleteIntent = try enqueueCloudKitDeleteIfNeeded(recordType: .image, syncId: syncId, deletionTime: deletionTime, in: db)
            return (false, false, [], false, deleteIntent.shouldSkipServerMetadata)
        case .missing:
            return (false, true, [], false, false)
        }
        let existing = try PostImage
            .filter(Column(PostImage.CodingKeys.syncId) == syncId)
            .fetchOne(db)
        if let existing, remoteModificationTime <= (existing.modificationTime ?? 0) {
            guard remoteModificationTime == (existing.modificationTime ?? 0) else { return (false, false, [], false, false) }
            let restore = try restoreMissingImageFiles(for: existing, stagedAssets: stagedAssets, in: db)
            // A heal attempt that still lacks its asset (download/staging
            // failed) arms the same full-fetch retry as the strictly-newer
            // path — an unchanged record is never re-delivered incrementally,
            // so without it the lost cache file stays broken until some
            // device happens to edit the image.
            return (restore.didChange, false, [], restore.stillMissingAssets, false)
        }

        let texts = try PostText
            .filter(Column(PostText.CodingKeys.postId) == postId)
            .fetchAll(db)
        if let latestTextModificationTime = texts.map({ $0.modificationTime ?? 0 }).max(),
           latestTextModificationTime > remoteModificationTime {
            let deleteIntent = try enqueueCloudKitDeleteIfNeeded(
                recordType: .image,
                syncId: syncId,
                deletionTime: latestTextModificationTime,
                in: db
            )
            return (false, false, [], false, deleteIntent.shouldSkipServerMetadata)
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
            return (false, false, [], true, false)
        }

        for text in texts {
            try enqueueCloudKitDeleteIfNeeded(recordType: .text, syncId: text.syncId, deletionTime: remoteModificationTime, in: db)
        }
        try PostText.deleteAll(db, ids: texts.compactMap(\.id))
        try OnboardingLocalRecord.unmark(recordType: .text, syncIds: texts.map(\.syncId), in: db)

        guard let originalName = stagedAssets?.originalName ?? remoteOriginalFileName ?? existing?.original,
              let processedName = stagedAssets?.processedName ?? remoteProcessedFileName ?? existing?.processed else {
            return (false, false, [], false, false)
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
        return (true, false, deletedImageFiles, false, false)
    }

    /// Remote and local are at the same version, so the asset content matches
    /// the row; a lost cache file (e.g. an interrupted crop that deleted the old
    /// file before the replacement landed) can be restored from the staged
    /// download. modification_time stays untouched — no LWW impact, no echo
    /// back to the server. `stillMissingAssets` reports a file that is missing
    /// AND could not be restored (asset absent / staging failed), so the
    /// caller can arm the full-fetch retry.
    func restoreMissingImageFiles(for image: PostImage, stagedAssets: StagedImageAssets?, in db: Database) throws -> (didChange: Bool, stillMissingAssets: Bool) {
        guard let imageId = image.id else { return (false, false) }
        let originalMissing = ImageCacheManager.shared.getURL(name: image.original, type: .original) == nil
        let processedMissing = ImageCacheManager.shared.getURL(name: image.processed, type: .processed) == nil
        var assignments: [ColumnAssignment] = []
        var consumedOriginal = false
        var consumedProcessed = false
        var stillMissingAssets = false
        if originalMissing {
            if let stagedOriginal = stagedAssets?.originalName {
                assignments.append(Column(PostImage.CodingKeys.original).set(to: stagedOriginal))
                consumedOriginal = true
            } else {
                stillMissingAssets = true
            }
        }
        if processedMissing {
            if let stagedProcessed = stagedAssets?.processedName {
                assignments.append(Column(PostImage.CodingKeys.processed).set(to: stagedProcessed))
                consumedProcessed = true
            } else {
                stillMissingAssets = true
            }
        }
        guard !assignments.isEmpty else { return (false, stillMissingAssets) }
        try PostImage
            .filter(Column(PostImage.CodingKeys.id) == imageId)
            .updateAll(db, assignments)
        // The caller drops the whole staged entry once anything was restored, so
        // clean the unconsumed half here instead of leaking it until the next
        // launch's orphan sweep.
        if !consumedOriginal, let stagedOriginal = stagedAssets?.originalName, stagedOriginal != image.original {
            _ = ImageCacheManager.shared.deleteImage(fileName: stagedOriginal, type: .original)
        }
        if !consumedProcessed, let stagedProcessed = stagedAssets?.processedName, stagedProcessed != image.processed {
            _ = ImageCacheManager.shared.deleteImage(fileName: stagedProcessed, type: .processed)
        }
        return (true, stillMissingAssets)
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
    ) throws -> (didChangeDatabase: Bool, isDeferred: Bool, shouldSkipServerMetadata: Bool) {
        guard let syncId = stringValue(Field.syncId, in: record),
              let postSyncId = stringValue(Field.postSyncId, in: record),
              let styleSyncId = stringValue(Field.styleSyncId, in: record) else {
            return (false, false, false)
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
            let deleteIntent = try enqueueCloudKitDeleteIfNeeded(recordType: .decoration, syncId: syncId, deletionTime: deletionTime, in: db)
            return (false, false, deleteIntent.shouldSkipServerMetadata)
        case (.missing, _), (_, .missing):
            return (false, true, false)
        }
        let existing = try PostDecoration
            .filter(Column(PostDecoration.CodingKeys.syncId) == syncId)
            .fetchOne(db)
        guard existing == nil || remoteModificationTime > (existing?.modificationTime ?? 0) else { return (false, false, false) }

        let conflictingDecorations = try PostDecoration
            .filter(Column(PostDecoration.CodingKeys.postId) == postId && Column(PostDecoration.CodingKeys.syncId) != syncId)
            .fetchAll(db)
        if let latestDecorationModificationTime = conflictingDecorations.map({ $0.modificationTime ?? 0 }).max(),
           latestDecorationModificationTime > remoteModificationTime {
            let deleteIntent = try enqueueCloudKitDeleteIfNeeded(
                recordType: .decoration,
                syncId: syncId,
                deletionTime: latestDecorationModificationTime,
                in: db
            )
            return (false, false, deleteIntent.shouldSkipServerMetadata)
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
        return (true, false, false)
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

    enum CloudKitDeleteIntentResult {
        case enqueued
        case suppressedByOnboarding

        var shouldSkipServerMetadata: Bool {
            switch self {
            case .enqueued, .suppressedByOnboarding:
                return true
            }
        }
    }

    @discardableResult
    func enqueueCloudKitDeleteIfNeeded(
        recordType: CloudKitRecordType,
        syncId: String,
        deletionTime: Int64,
        aggregateType: CloudKitAggregateType = .record,
        aggregateName: String? = nil,
        in db: Database
    ) throws -> CloudKitDeleteIntentResult {
        guard try !OnboardingLocalRecord.isMarked(recordType: recordType, syncId: syncId, in: db) else {
            return .suppressedByOnboarding
        }
        try CloudKitOutboxEntry.enqueueDelete(
            recordType: recordType,
            syncId: syncId,
            deletionTime: deletionTime,
            aggregateType: aggregateType,
            aggregateName: aggregateName,
            in: db
        )
        return .enqueued
    }

    @discardableResult
    func enqueueCloudKitSaveIfNeeded(recordType: CloudKitRecordType, syncId: String, modificationTime: Int64?, in db: Database) throws -> Bool {
        guard try !OnboardingLocalRecord.isMarked(recordType: recordType, syncId: syncId, in: db) else { return false }
        try CloudKitOutboxEntry.enqueueSave(recordType: recordType, syncId: syncId, modificationTime: modificationTime, in: db)
        return true
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
                try db.transactionDate.millisecondsSince1970,
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
