//
//  CloudKitSettingsViewController.swift
//  Pin It
//
//  Created by Ci Zi on 2026/6/13.
//

import UIKit
import SnapKit
import MoreKit

final class CloudKitSettingsViewController: UIViewController {
    private enum Section: Hashable {
        case sync
        case rebuild
        case clear
    }

    private enum Item: Hashable {
        case sync(CloudKitSync)
        case status
        case rebuild
        case clear
        case diagnostics

        var title: String {
            switch self {
            case .sync:
                return CloudKitSync.getTitle()
            case .status:
                return String(localized: "settings.cloudKitSync.status")
            case .rebuild:
                return String(localized: "settings.cloudKitSync.rebuild")
            case .clear:
                return String(localized: "settings.cloudKitSync.clear")
            case .diagnostics:
                return String(localized: "settings.cloudKitSync.diagnostics")
            }
        }
    }

    private final class DataSource: UITableViewDiffableDataSource<Section, Item> {
        weak var owner: CloudKitSettingsViewController?

        override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
            switch sectionIdentifier(for: section) {
            case .sync:
                return owner?.cloudKitSyncFooter()
            case .rebuild:
                return String(localized: "settings.cloudKitSync.rebuild.footer")
            case .clear:
                return String(localized: "settings.cloudKitSync.clear.footer")
            case .none:
                return nil
            }
        }
    }

    private var tableView: UITableView!
    private var dataSource: DataSource!
    private var isChangingCloudKitSync = false
    private var isRebuildingCloudKitSync = false
    private var isClearingCloudKitData = false
    private var failedOutboxSummary: String?
    private var isLoadingFailedOutboxSummary = false
    private var needsAnotherFailedOutboxRefresh = false
    /// Whether the diagnostic event log has anything to export. Loaded off the
    /// main thread; the export/clear rows show when sync is enabled or this is true.
    private var hasDiagnosticEvents = false
    /// What the table last actually rendered for the CloudKit section footer.
    /// Diffable snapshot applies don't re-ask footer titles when item identities
    /// are unchanged, so reloadData() compares against this to decide whether
    /// the section needs an explicit reload.
    private var lastRenderedCloudKitFooter: String?

    init() {
        super.init(nibName: nil, bundle: nil)
        title = CloudKitSync.getTitle()
        hidesBottomBarWhenPushed = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = AppColor.background
        navigationController?.navigationBar.tintColor = .systemRed

        configureHierarchy()
        configureDataSource()
        reloadData()

        NotificationCenter.default.addObserver(self, selector: #selector(reloadData), name: .SettingsUpdate, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reloadData), name: .DatabaseUpdated, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reloadData), name: .cloudKitSyncActivityChanged, object: nil)
        // After a purchase/restore the Pro badge clears and enabling unlocks.
        NotificationCenter.default.addObserver(self, selector: #selector(reloadData), name: .LifetimeMembership, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reloadData), name: .StoreInfoLoaded, object: nil)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Reflect current state on (re)appear: reloadData reconfigures the sync
        // status row (its value is computed at cell-build time) and also kicks
        // the async failed-outbox / diagnostics refreshes. A sync pass whose
        // error text is unchanged posts no notification (setLastError dedupes),
        // so these can otherwise be stale when the page comes back on screen.
        reloadData()
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent
    }

    private func configureHierarchy() {
        tableView = UITableView(frame: .zero, style: .insetGrouped)
        tableView.backgroundColor = AppColor.background
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "reuseIdentifier")
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 50.0
        tableView.delegate = self
        view.addSubview(tableView)
        tableView.snp.makeConstraints { make in
            make.edges.equalTo(view)
        }
    }

    private func configureDataSource() {
        dataSource = DataSource(tableView: tableView) { [weak self] tableView, indexPath, item -> UITableViewCell? in
            guard let self else { return nil }
            let cell = tableView.dequeueReusableCell(withIdentifier: "reuseIdentifier", for: indexPath)
            cell.isUserInteractionEnabled = true
            cell.selectionStyle = .default

            switch item {
            case .sync(let cloudKitSync):
                cell.accessoryType = .disclosureIndicator
                var content = UIListContentConfiguration.valueCell()
                content.textProperties.color = .label
                // Mark sync as a Pro feature with an inline badge on the title,
                // shown regardless of membership status.
                content.attributedText = ProBadge.attributedTitle(
                    item.title,
                    font: .preferredFont(forTextStyle: .body),
                    color: .label,
                    traitCollection: cell.traitCollection
                )
                if isChangingCloudKitSync {
                    content.secondaryText = String(localized: "settings.cloudKitSync.checking")
                    cell.isUserInteractionEnabled = false
                } else {
                    content.secondaryText = cloudKitSync.getName()
                }
                cell.contentConfiguration = content
            case .status:
                // Tappable: triggers a manual sync (see didSelectRowAt). Default
                // selection + interaction from the top of the provider.
                cell.accessoryType = .none
                var content = UIListContentConfiguration.valueCell()
                content.text = item.title
                content.textProperties.color = .label
                content.secondaryText = cloudKitSyncStatusText()
                cell.contentConfiguration = content
            case .rebuild:
                cell.accessoryType = .none
                var content = UIListContentConfiguration.subtitleCell()
                content.text = item.title
                content.secondaryText = isRebuildingCloudKitSync ? String(localized: "settings.cloudKitSync.rebuilding") : nil
                content.textProperties.color = canRebuildCloudKit ? .systemRed : .secondaryLabel
                content.textProperties.alignment = .center
                cell.contentConfiguration = content
                cell.isUserInteractionEnabled = canRebuildCloudKit
            case .clear:
                cell.accessoryType = .none
                var content = UIListContentConfiguration.subtitleCell()
                content.text = item.title
                content.secondaryText = isClearingCloudKitData ? String(localized: "settings.cloudKitSync.clearing") : nil
                content.textProperties.color = canClearCloudKit ? .systemRed : .secondaryLabel
                content.textProperties.alignment = .center
                cell.contentConfiguration = content
                cell.isUserInteractionEnabled = canClearCloudKit
            case .diagnostics:
                cell.accessoryType = .disclosureIndicator
                var content = UIListContentConfiguration.valueCell()
                content.text = item.title
                content.textProperties.color = .label
                cell.contentConfiguration = content
            }

            return cell
        }
        dataSource.owner = self
    }

    @objc
    private func reloadData() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.reloadData()
            }
            return
        }

        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.sync])
        var syncItems: [Item] = [.sync(CloudKitSync.getValue())]
        if CloudKitSync.current == .enable {
            syncItems.append(.status)
        }
        syncItems.append(contentsOf: cloudKitDiagnosticsItems())
        snapshot.appendItems(syncItems, toSection: .sync)

        if shouldShowCloudKitActions {
            snapshot.appendSections([.rebuild])
            snapshot.appendItems([.rebuild], toSection: .rebuild)
            snapshot.appendSections([.clear])
            snapshot.appendItems([.clear], toSection: .clear)
        }

        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        // Footer titles aren't re-queried when the diff is empty; if the
        // CloudKit footer text changed, force the section to reload.
        if lastRenderedCloudKitFooter != nil, computedCloudKitSyncFooter() != lastRenderedCloudKitFooter {
            snapshot.reloadSections([.sync])
        }
        dataSource.apply(snapshot, animatingDifferences: false)
        refreshFailedOutboxSummary()
        refreshDiagnosticsAvailability()
    }

    /// Both the rebuild and clear sections show together whenever either action
    /// is conceptually relevant; each row enables only in its applicable state
    /// (see canRebuildCloudKit / canClearCloudKit) and is greyed out otherwise,
    /// so the user always sees both exist. State-based (not the tappability
    /// flags) so an in-progress rebuild/clear keeps its row on screen.
    private var shouldShowCloudKitActions: Bool {
        CloudKitSync.current == .enable
            || CloudKitSync.remoteDataMayExist
            || CloudKitSync.pendingRemoteReset
    }

    /// Rebuild re-uploads this device's library as the canonical cloud copy —
    /// only meaningful while sync is on.
    private var canRebuildCloudKit: Bool {
        CloudKitSync.current == .enable
            && !isChangingCloudKitSync
            && !isRebuildingCloudKitSync
            && !isClearingCloudKitData
    }

    /// Clear empties the cloud zone — only offered while sync is off and there is
    /// still remote data to remove.
    private var canClearCloudKit: Bool {
        CloudKitSync.current == .disable
            && (CloudKitSync.remoteDataMayExist || CloudKitSync.pendingRemoteReset)
            && !isChangingCloudKitSync
            && !isRebuildingCloudKitSync
            && !isClearingCloudKitData
    }

    private func cloudKitDiagnosticsItems() -> [Item] {
        // Reachable while sync is on (where problems happen) or, after the user
        // has turned it off, as long as there is still a log worth sending.
        guard CloudKitSync.current == .enable || hasDiagnosticEvents else { return [] }
        return [.diagnostics]
    }

    private func cloudKitSyncStatusText() -> String {
        if CloudKitRecordSyncManager.shared.isCurrentlySyncing() {
            return String(localized: "settings.cloudKitSync.syncing")
        }
        if CloudKitSync.lastError != nil {
            return String(localized: "settings.cloudKitSync.syncFailed")
        }
        return String(localized: "settings.cloudKitSync.upToDate")
    }

    private func cloudKitSyncFooter() -> String? {
        let footer = computedCloudKitSyncFooter()
        lastRenderedCloudKitFooter = footer
        return footer
    }

    private func computedCloudKitSyncFooter() -> String? {
        var parts = [CloudKitSync.getFooter()].compactMap(\.self)
        if let failedOutboxSummary {
            parts.append(failedOutboxSummary)
        }
        return parts.joined(separator: "\n")
    }

    private func refreshFailedOutboxSummary() {
        guard !isLoadingFailedOutboxSummary else {
            // Coalesce instead of dropping: a refresh requested while one is in
            // flight re-runs once the current load lands, so the footer can't
            // get stuck on a stale summary until the next SettingsUpdate.
            needsAnotherFailedOutboxRefresh = true
            return
        }
        isLoadingFailedOutboxSummary = true
        // A plain Task {} would inherit this controller's MainActor isolation and
        // run the database read on the main thread.
        Task.detached(priority: .utility) {
            let summary = CloudKitSettingsViewController.loadFailedOutboxSummary()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isLoadingFailedOutboxSummary = false
                defer {
                    if self.needsAnotherFailedOutboxRefresh {
                        self.needsAnotherFailedOutboxRefresh = false
                        self.refreshFailedOutboxSummary()
                    }
                }
                guard self.failedOutboxSummary != summary else { return }
                self.failedOutboxSummary = summary
                guard self.dataSource.snapshot().sectionIdentifiers.contains(.sync) else { return }
                var snapshot = self.dataSource.snapshot()
                snapshot.reloadSections([.sync])
                self.dataSource.apply(snapshot, animatingDifferences: false)
            }
        }
    }

    private func refreshDiagnosticsAvailability() {
        Task.detached(priority: .utility) {
            let hasEvents = CloudKitSyncEventLog.shared.hasEvents()
            await MainActor.run { [weak self] in
                guard let self, self.hasDiagnosticEvents != hasEvents else { return }
                self.hasDiagnosticEvents = hasEvents
                // Only the diagnostics section's presence depends on this flag;
                // rebuild the snapshot so the rows appear/disappear. reloadData
                // re-invokes this, but it no-ops once the value has converged.
                self.reloadData()
            }
        }
    }

    private nonisolated static func loadFailedOutboxSummary() -> String? {
        var failedCount = 0
        var entries: [CloudKitOutboxEntry] = []
        do {
            try AppDatabase.shared.dbWriter?.read { db in
                failedCount = try CloudKitOutboxEntry.failedCount(in: db)
                entries = try CloudKitOutboxEntry.failedEntries(limit: 3, in: db)
            }
        } catch {
            return nil
        }

        guard failedCount > 0 else { return nil }
        var lines = ["\(String(localized: "settings.cloudKitSync.failedRecords")): \(failedCount)"]
        lines.append(contentsOf: entries.map { entry in
            "\(cloudKitRecordTypeName(entry.cloudKitRecordType)): \(entry.lastError ?? String(localized: "settings.cloudKitSync.unknownError"))"
        })
        if failedCount > entries.count {
            lines.append("\(String(localized: "settings.cloudKitSync.moreFailedRecords")): \(failedCount - entries.count)")
        }
        return lines.joined(separator: "\n")
    }

    private nonisolated static func cloudKitRecordTypeName(_ recordType: CloudKitRecordType?) -> String {
        switch recordType {
        case .post:
            return String(localized: "settings.cloudKitSync.recordType.post")
        case .text:
            return String(localized: "settings.cloudKitSync.recordType.text")
        case .image:
            return String(localized: "settings.cloudKitSync.recordType.image")
        case .style:
            return String(localized: "settings.cloudKitSync.recordType.style")
        case .decoration:
            return String(localized: "settings.cloudKitSync.recordType.decoration")
        case .setting:
            return String(localized: "settings.cloudKitSync.recordType.setting")
        case .none:
            return String(localized: "settings.cloudKitSync.recordType.unknown")
        }
    }
}

extension CloudKitSettingsViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }

        switch item {
        case .sync:
            showCloudKitSyncAlert()
        case .status:
            // Tap to sync now (like a pull-to-refresh); the activity notification
            // flips the row to "Syncing…" and back.
            CloudKitRecordSyncManager.shared.syncIfEnabled()
        case .rebuild:
            showCloudKitRebuildAlert()
        case .clear:
            showCloudKitClearAlert()
        case .diagnostics:
            navigationController?.pushViewController(CloudKitDiagnosticsViewController(), animated: ConsideringUser.pushAnimated)
        }
    }
}

private extension CloudKitSettingsViewController {
    func showCloudKitSyncAlert() {
        if CloudKitSync.current == .enable {
            let alertController = UIAlertController(
                title: String(localized: "settings.cloudKitSync.disable.alert.title"),
                message: String(localized: "settings.cloudKitSync.disable.alert.message"),
                preferredStyle: .alert
            )
            alertController.addAction(UIAlertAction(title: String(localized: "settings.disable"), style: .destructive) { [weak self] _ in
                self?.setCloudKitSync(.disable)
            })
            alertController.addAction(UIAlertAction(title: String(localized: "button.cancel"), style: .cancel))
            present(alertController, animated: ConsideringUser.animated)
        } else if User.shared.proTier() == .none {
            // Enabling sync is a Pro feature. Explain it, then send the user back
            // to the Settings page where the membership purchase cell lives. After
            // buying they re-enter and tap again — the gate clears once they're Pro.
            let alertController = UIAlertController(
                title: CloudKitSync.getTitle(),
                message: String(localized: "error.needsPro.message"),
                preferredStyle: .alert
            )
            alertController.addAction(UIAlertAction(title: String(localized: "membership.purchase"), style: .default) { [weak self] _ in
                self?.navigationController?.popToRootViewController(animated: ConsideringUser.pushAnimated)
            })
            alertController.addAction(UIAlertAction(title: String(localized: "button.cancel"), style: .cancel))
            present(alertController, animated: ConsideringUser.animated)
        } else {
            let alertController = UIAlertController(
                title: String(localized: "settings.cloudKitSync.enable.alert.title"),
                message: AppInfo.localized("settings.cloudKitSync.enable.alert.message"),
                preferredStyle: .alert
            )
            alertController.addAction(UIAlertAction(title: String(localized: "settings.enable"), style: .default) { [weak self] _ in
                self?.setCloudKitSync(.enable)
            })
            alertController.addAction(UIAlertAction(title: String(localized: "button.cancel"), style: .cancel))
            present(alertController, animated: ConsideringUser.animated)
        }
    }

    func setCloudKitSync(_ value: CloudKitSync) {
        guard !isChangingCloudKitSync else { return }
        isChangingCloudKitSync = true
        reloadData()
        Task { [weak self] in
            defer {
                Task { @MainActor in
                    self?.isChangingCloudKitSync = false
                    self?.reloadData()
                }
            }
            do {
                if value == .enable {
                    try await CloudKitRecordSyncManager.shared.validateAccountForEnabling()
                }
                try CloudKitSync.setCurrent(value)
            } catch {
                CloudKitSync.setLastError(error.localizedDescription)
                await MainActor.run {
                    self?.showCloudKitResultAlert(
                        title: String(localized: "settings.cloudKitSync.enable.failure.title"),
                        message: error.localizedDescription,
                        isError: true
                    )
                }
            }
        }
    }

    func showCloudKitRebuildAlert() {
        let message = [
            AppInfo.localized("settings.cloudKitSync.rebuild.alert.message"),
            cloudKitLocalRecordSummary()
        ].compactMap(\.self).joined(separator: "\n\n")
        let alertController = UIAlertController(
            title: String(localized: "settings.cloudKitSync.rebuild.alert.title"),
            message: message,
            preferredStyle: .alert
        )
        let rebuildAction = UIAlertAction(title: String(localized: "settings.cloudKitSync.rebuild"), style: .destructive) { [weak self] _ in
            self?.rebuildCloudKitSync()
        }
        let cancelAction = UIAlertAction(title: String(localized: "button.cancel"), style: .cancel)
        alertController.addAction(rebuildAction)
        alertController.addAction(cancelAction)
        present(alertController, animated: ConsideringUser.animated)
    }

    func showCloudKitClearAlert() {
        let alertController = UIAlertController(
            title: String(localized: "settings.cloudKitSync.clear.alert.title"),
            message: AppInfo.localized("settings.cloudKitSync.clear.alert.message"),
            preferredStyle: .alert
        )
        let clearAction = UIAlertAction(title: String(localized: "settings.cloudKitSync.clear"), style: .destructive) { [weak self] _ in
            self?.clearCloudKitData()
        }
        let cancelAction = UIAlertAction(title: String(localized: "button.cancel"), style: .cancel)
        alertController.addAction(clearAction)
        alertController.addAction(cancelAction)
        present(alertController, animated: ConsideringUser.animated)
    }

    func rebuildCloudKitSync() {
        guard !isRebuildingCloudKitSync else { return }
        isRebuildingCloudKitSync = true
        reloadData()
        Task { [weak self] in
            defer {
                Task { @MainActor in
                    self?.isRebuildingCloudKitSync = false
                    self?.reloadData()
                }
            }
            do {
                let hasOutboxFailures = try await CloudKitRecordSyncManager.shared.rebuildCloudKitData()
                await MainActor.run {
                    self?.showCloudKitResultAlert(
                        title: hasOutboxFailures
                        ? String(localized: "settings.cloudKitSync.rebuild.partial.title")
                        : String(localized: "settings.cloudKitSync.rebuild.success.title"),
                        message: hasOutboxFailures
                        ? AppInfo.localized("settings.cloudKitSync.rebuild.partial.message")
                        : String(localized: "settings.cloudKitSync.rebuild.success.message")
                    )
                }
            } catch is CancellationError {
                // Preempted by a queued local-reset rebuild or an engine restart:
                // the rebuild has been re-queued and will complete on its own.
            } catch {
                await MainActor.run {
                    self?.showCloudKitResultAlert(
                        title: String(localized: "settings.cloudKitSync.rebuild.failure.title"),
                        message: error.localizedDescription,
                        isError: true
                    )
                }
            }
        }
    }

    func clearCloudKitData() {
        guard !isClearingCloudKitData else { return }
        isClearingCloudKitData = true
        reloadData()
        Task { [weak self] in
            defer {
                Task { @MainActor in
                    self?.isClearingCloudKitData = false
                    self?.reloadData()
                }
            }
            do {
                try await CloudKitRecordSyncManager.shared.clearCloudKitData()
                await MainActor.run {
                    self?.showCloudKitResultAlert(
                        title: String(localized: "settings.cloudKitSync.clear.success.title"),
                        message: AppInfo.localized("settings.cloudKitSync.clear.success.message")
                    )
                }
            } catch {
                await MainActor.run {
                    self?.showCloudKitResultAlert(
                        title: String(localized: "settings.cloudKitSync.clear.failure.title"),
                        message: error.localizedDescription,
                        isError: true
                    )
                }
            }
        }
    }

    func cloudKitLocalRecordSummary() -> String? {
        var postCount = 0
        var styleCount = 0
        do {
            try AppDatabase.shared.dbWriter?.read { db in
                postCount = try Post.fetchCount(db)
                styleCount = try PostStyle.fetchCount(db)
            }
        } catch {
            return nil
        }
        return String(
            format: String(localized: "settings.cloudKitSync.localRecordSummary"),
            postCount,
            styleCount
        )
    }

    func showCloudKitResultAlert(title: String, message: String, isError: Bool = false) {
        guard view.window != nil, presentedViewController == nil else {
            // Drop success notifications that can't be presented; only error text
            // belongs in the persistent footer slot.
            if isError {
                CloudKitSync.setLastError(message)
            }
            return
        }
        let alertController = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alertController.addAction(UIAlertAction(title: String(localized: "button.done"), style: .default))
        present(alertController, animated: ConsideringUser.animated)
    }
}
