//
//  CloudKitDiagnosticsViewController.swift
//  Pin It
//
//  Sub-page of the CloudKit sync settings: export or clear the rotating,
//  content-free diagnostic event log (see CloudKitSyncEventLog).
//

import UIKit
import SnapKit
import MoreKit

final class CloudKitDiagnosticsViewController: UIViewController {
    private enum Row: Int, CaseIterable {
        case export
        case clear
    }

    private var tableView: UITableView!
    private var storageSummaryText: String?

    init() {
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "settings.cloudKitSync.diagnostics")
        hidesBottomBarWhenPushed = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = AppColor.background
        navigationController?.navigationBar.tintColor = .systemRed

        tableView = UITableView(frame: .zero, style: .insetGrouped)
        tableView.backgroundColor = AppColor.background
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "reuseIdentifier")
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 50.0
        tableView.dataSource = self
        tableView.delegate = self
        view.addSubview(tableView)
        tableView.snp.makeConstraints { make in
            make.edges.equalTo(view)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshStorageSummary()
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent
    }

    private func refreshStorageSummary() {
        Task.detached(priority: .utility) {
            let summary = CloudKitSyncEventLog.shared.storageSummary()
            let text = String(
                format: String(localized: "settings.cloudKitSync.diagnostics.stats"),
                summary.lines,
                summary.files
            )
            await MainActor.run { [weak self] in
                guard let self, self.storageSummaryText != text else { return }
                self.storageSummaryText = text
                self.tableView.reloadData()
            }
        }
    }
}

extension CloudKitDiagnosticsViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return Row.allCases.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "reuseIdentifier", for: indexPath)
        var content = UIListContentConfiguration.subtitleCell()
        content.textProperties.alignment = .center
        switch Row(rawValue: indexPath.row) {
        case .export:
            content.text = String(localized: "settings.cloudKitSync.exportDiagnostics")
            content.textProperties.color = .systemRed
        case .clear:
            content.text = String(localized: "settings.cloudKitSync.clearDiagnostics")
            content.textProperties.color = .systemRed
        case .none:
            break
        }
        cell.contentConfiguration = content
        return cell
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        return [String(localized: "settings.cloudKitSync.diagnostics.footer"), storageSummaryText]
            .compactMap(\.self)
            .joined(separator: "\n\n")
    }
}

extension CloudKitDiagnosticsViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch Row(rawValue: indexPath.row) {
        case .export:
            exportDiagnostics()
        case .clear:
            showClearDiagnosticsAlert()
        case .none:
            break
        }
    }
}

private extension CloudKitDiagnosticsViewController {
    func exportDiagnostics() {
        // Build the zip off the main thread: exportArchive flushes buffered
        // events, snapshots every segment, and zips them.
        Task.detached(priority: .userInitiated) { [weak self] in
            let header = Self.diagnosticsHeader()
            guard let url = CloudKitSyncEventLog.shared.exportArchive(header: header) else {
                await MainActor.run { [weak self] in
                    self?.presentAlert(
                        title: String(localized: "settings.cloudKitSync.exportDiagnostics.failure.title"),
                        message: String(localized: "settings.cloudKitSync.exportDiagnostics.failure.message")
                    )
                }
                return
            }
            await MainActor.run { [weak self] in
                self?.presentDiagnosticsShareSheet(for: url)
            }
        }
    }

    func presentDiagnosticsShareSheet(for url: URL) {
        guard view.window != nil, presentedViewController == nil else { return }
        let activityViewController = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        // iPad requires a valid popover anchor or presentation crashes. Resolve
        // the export row's current cell now rather than capturing it earlier.
        if let popover = activityViewController.popoverPresentationController {
            let exportIndexPath = IndexPath(row: Row.export.rawValue, section: 0)
            let anchor: UIView = tableView.cellForRow(at: exportIndexPath) ?? tableView
            popover.sourceView = anchor
            popover.sourceRect = anchor.bounds
            popover.permittedArrowDirections = [.up, .down]
        }
        present(activityViewController, animated: ConsideringUser.animated)
    }

    func showClearDiagnosticsAlert() {
        let alertController = UIAlertController(
            title: String(localized: "settings.cloudKitSync.clearDiagnostics.alert.title"),
            message: String(localized: "settings.cloudKitSync.clearDiagnostics.alert.message"),
            preferredStyle: .alert
        )
        alertController.addAction(UIAlertAction(title: String(localized: "settings.cloudKitSync.clearDiagnostics"), style: .destructive) { [weak self] _ in
            CloudKitSyncEventLog.shared.clear()
            self?.refreshStorageSummary()
        })
        alertController.addAction(UIAlertAction(title: String(localized: "button.cancel"), style: .cancel))
        present(alertController, animated: ConsideringUser.animated)
    }

    func presentAlert(title: String, message: String) {
        guard view.window != nil, presentedViewController == nil else { return }
        let alertController = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alertController.addAction(UIAlertAction(title: String(localized: "button.done"), style: .default))
        present(alertController, animated: ConsideringUser.animated)
    }

    /// Content-free context prepended to the exported log: app/OS/device, sync
    /// state, and local record counts — no post text, image, or style content.
    nonisolated static func diagnosticsHeader() -> String {
        var lines: [String] = ["Pin It CloudKit Sync Diagnostics"]
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        lines.append("App: \(version) (\(build))")
        lines.append("OS: \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
        lines.append("Device: \(deviceModelIdentifier())")
        lines.append("Sync: \(CloudKitSync.current == .enable ? "enabled" : "disabled")")
        lines.append("RemoteDataMayExist: \(CloudKitSync.remoteDataMayExist)")
        if let lastError = CloudKitSync.lastError {
            lines.append("LastError: \(lastError)")
        }
        var postCount = 0
        var styleCount = 0
        var failedOutbox = 0
        try? AppDatabase.shared.dbWriter?.read { db in
            postCount = try Post.fetchCount(db)
            styleCount = try PostStyle.fetchCount(db)
            failedOutbox = try CloudKitOutboxEntry.failedCount(in: db)
        }
        lines.append("Posts: \(postCount)  Styles: \(styleCount)  FailedOutbox: \(failedOutbox)")
        return lines.joined(separator: "\n")
    }

    nonisolated static func deviceModelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafeBytes(of: &systemInfo.machine) { rawBuffer -> String in
            let bytes = rawBuffer.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        return machine.isEmpty ? UIDevice.current.model : machine
    }
}
