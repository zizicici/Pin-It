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
        case action
        case diagnostics
    }

    private enum Item: Hashable {
        case sync(CloudKitSync)
        case rebuild
        case clear
        case diagnostics

        var title: String {
            switch self {
            case .sync:
                return CloudKitSync.getTitle()
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
            guard sectionIdentifier(for: section) == .sync else { return nil }
            return owner?.cloudKitSyncFooter()
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
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // The failed-outbox summary only refreshes on .SettingsUpdate /
        // .DatabaseUpdated; a sync pass whose error text is unchanged posts
        // neither (setLastError dedupes), so the counts can be stale when the
        // page comes back on screen.
        refreshFailedOutboxSummary()
        refreshDiagnosticsAvailability()
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

            switch item {
            case .sync(let cloudKitSync):
                cell.accessoryType = .disclosureIndicator
                var content = UIListContentConfiguration.valueCell()
                content.text = item.title
                content.textProperties.color = .label
                if isChangingCloudKitSync {
                    content.secondaryText = String(localized: "settings.cloudKitSync.checking")
                    cell.isUserInteractionEnabled = false
                } else {
                    content.secondaryText = cloudKitSync.getName()
                }
                cell.contentConfiguration = content
            case .rebuild:
                cell.accessoryType = .none
                var content = UIListContentConfiguration.subtitleCell()
                content.text = item.title
                content.secondaryText = isRebuildingCloudKitSync ? String(localized: "settings.cloudKitSync.rebuilding") : nil
                content.textProperties.color = isRebuildingCloudKitSync ? .secondaryLabel : .systemRed
                content.textProperties.alignment = .center
                cell.contentConfiguration = content
                cell.isUserInteractionEnabled = !isRebuildingCloudKitSync
            case .clear:
                cell.accessoryType = .none
                var content = UIListContentConfiguration.subtitleCell()
                content.text = item.title
                content.secondaryText = isClearingCloudKitData ? String(localized: "settings.cloudKitSync.clearing") : nil
                content.textProperties.color = isClearingCloudKitData ? .secondaryLabel : .systemRed
                content.textProperties.alignment = .center
                cell.contentConfiguration = content
                cell.isUserInteractionEnabled = !isClearingCloudKitData
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
        snapshot.appendItems([.sync(CloudKitSync.getValue())], toSection: .sync)

        let actionItems = cloudKitActionItems()
        if !actionItems.isEmpty {
            snapshot.appendSections([.action])
            snapshot.appendItems(actionItems, toSection: .action)
        }

        let diagnosticsItems = cloudKitDiagnosticsItems()
        if !diagnosticsItems.isEmpty {
            snapshot.appendSections([.diagnostics])
            snapshot.appendItems(diagnosticsItems, toSection: .diagnostics)
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

    private func cloudKitActionItems() -> [Item] {
        if CloudKitSync.current == .enable {
            return [.rebuild]
        } else if CloudKitSync.remoteDataMayExist || CloudKitSync.pendingRemoteReset {
            return [.clear]
        } else {
            return []
        }
    }

    private func cloudKitDiagnosticsItems() -> [Item] {
        // Reachable while sync is on (where problems happen) or, after the user
        // has turned it off, as long as there is still a log worth sending.
        guard CloudKitSync.current == .enable || hasDiagnosticEvents else { return [] }
        return [.diagnostics]
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
