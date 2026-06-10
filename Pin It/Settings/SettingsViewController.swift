//
//  SettingsViewController.swift
//  Pin It
//
//  Created by Ci Zi on 2025/11/1.
//

import UIKit
import SnapKit
import SafariServices
import StoreKit
import MoreKit

enum PinItPromotion {
    static var promotionConfig: PromotionCellConfiguration {
        PromotionCellConfiguration(
            title: String(localized: "promotion.title"),
            titleHighlight: "Pro",
            features: [
                String(localized: "promotion.first"),
                String(localized: "promotion.second"),
                String(localized: "promotion.future")
            ],
            gradientColors: [.systemRed.withAlphaComponent(0.7), .systemRed.withAlphaComponent(0.8)]
        )
    }

    static var gratefulConfig: GratefulCellConfiguration {
        GratefulCellConfiguration(
            title: String(localized: "grateful.title"),
            titleHighlight: "Pro",
            content: String(localized: "grateful.content"),
            gradientColors: [.systemRed.withAlphaComponent(0.7), .systemRed.withAlphaComponent(0.8)],
            titleHighlightColor: .systemYellow
        )
    }
}

class SettingsViewController: UIViewController {
    private var tableView: UITableView!
    private var dataSource: DataSource!
    private var isRebuildingCloudKitSync = false
    private var isChangingCloudKitSync = false
    private var isClearingCloudKitData = false
    private var isResettingData = false
    private var cloudKitFailedOutboxSummary: String?
    private var isLoadingCloudKitFailedOutboxSummary = false
    private var needsAnotherCloudKitFailedOutboxRefresh = false
    /// What the table last actually rendered for the CloudKit section footer.
    /// Diffable snapshot applies don't re-ask footer titles when item identities
    /// are unchanged, so reloadData() compares against this to decide whether
    /// the section needs an explicit reload (e.g. lastError appeared/cleared).
    private var lastRenderedCloudKitFooter: String?
    
    enum Section: Hashable {
        case membership
        case general
        case cloudKit
        case automatic
        case action
        case advanced
        case style
        case styleList
        case shortcuts
        case reset
        
        var header: String? {
            switch self {
            case .membership:
                return nil
            case .general:
                return String(localized: "more.section.general")
            case .cloudKit:
                return nil
            case .automatic:
                return nil
            case .action:
                return nil
            case .advanced:
                return nil
            case .style:
                return String(localized: "style.title")
            case .styleList:
                return String(localized: "style.list")
            case .shortcuts:
                return String(localized: "more.section.shortcuts")
            case .reset:
                return nil
            }
        }
        
        var footer: String? {
            return nil
        }
    }
    
    enum Item: Hashable {
        enum GeneralItem: Hashable {
            case language
            
            var title: String {
                switch self {
                case .language:
                    return String(localized: "more.item.settings.language")
                }
            }
            
            var value: String? {
                switch self {
                case .language:
                    return String(localized: "more.item.settings.language.value")
                }
            }
        }
        
        enum AutomaticItem: Hashable {
            case cloudKitSync(CloudKitSync)
            case autoStart(AutoStartLiveActivity)
            case autoEnd(AutoEndLiveActivity)

            var value: String {
                switch self {
                case .cloudKitSync(let cloudKitSync):
                    return cloudKitSync.getName()
                case .autoStart(let autoStartLiveActivity):
                    return autoStartLiveActivity.getName()
                case .autoEnd(let autoEndLiveActivity):
                    return autoEndLiveActivity.getName()
                }
            }
        }
        
        enum ActionItem: Hashable {
            case maxPinned(MaxPinnedPosts)
            case deletionConfirm(DeleteOperationConfirmation)
            
            var value: String {
                switch self {
                case .maxPinned(let maxPinnedPosts):
                    return maxPinnedPosts.getName()
                case .deletionConfirm(let item):
                    return item.getName()
                }
            }
        }
        
        enum ShortcutsItem: Hashable {
            case first
            case second
            case ai
            case pasteboard
            case copy
            
            var title: String {
                switch self {
                case .first:
                    return String(localized: "shortcuts.1.title")
                case .second:
                    return String(localized: "shortcuts.2.title")
                case .ai:
                    return String(localized: "shortcuts.3.title")
                case .pasteboard:
                    return String(localized: "shortcuts.pasteboard.title")
                case .copy:
                    return String(localized: "shortcuts.copy.title")
                }
            }
            
            var subtitle: String {
                switch self {
                case .first:
                    return String(localized: "shortcuts.1.subtitle")
                case .second:
                    return String(localized: "shortcuts.2.subtitle")
                case .ai:
                    return String(localized: "shortcuts.3.subtitle")
                case .pasteboard:
                    return String(localized: "shortcuts.pasteboard.subtitle")
                case .copy:
                    return String(localized: "shortcuts.copy.subtitle")
                }
            }
            
            var url: String {
                switch self {
                case .first:
                    return String(localized: "shortcuts.1.url")
                case .second:
                    return String(localized: "shortcuts.2.url")
                case .ai:
                    return String(localized: "shortcuts.3.url")
                case .pasteboard:
                    return String(localized: "shortcuts.pasteboard.url")
                case .copy:
                    return String(localized: "shortcuts.copy.url")
                }
            }
            
            var image: UIImage? {
                switch self {
                case .first:
                    return UIImage(systemName: "square.and.arrow.up.circle.fill")
                case .second:
                    return UIImage(systemName: "camera.viewfinder")
                case .ai:
                    return UIImage(systemName: "star.circle.fill")
                case .pasteboard:
                    return UIImage(systemName: "doc.circle")
                case .copy:
                    return UIImage(systemName: "doc.circle.fill")
                }
            }
        }
        
        enum AdvancedItem: Hashable {
            case expirationAction(ExpirationAction)
            case expirationTime(DefaultExpirationTime)
            
            var value: String {
                switch self {
                case .expirationAction(let value):
                    return value.getName()
                case .expirationTime(let value):
                    return value.getName()
                }
            }
        }
        
        case promotion(String)
        case thanks
        case general(GeneralItem)
        case automatic(AutomaticItem)
        case action(ActionItem)
        case advanced(AdvancedItem)
        case defaultStyle(DefaultStyle)
        case style(PostStyle)
        case addStyle
        case shortcuts(ShortcutsItem)
        case rebuildCloudKitSync
        case clearCloudKitData
        case reset
        
        var title: String {
            switch self {
            case .promotion, .thanks:
                return ""
            case .general(let item):
                return item.title
            case .automatic(let item):
                switch item {
                case .cloudKitSync:
                    return CloudKitSync.getTitle()
                case .autoStart:
                    return AutoStartLiveActivity.getTitle()
                case .autoEnd:
                    return AutoEndLiveActivity.getTitle()
                }
            case .action(let item):
                switch item {
                case .maxPinned:
                    return MaxPinnedPosts.getTitle()
                case .deletionConfirm:
                    return DeleteOperationConfirmation.getTitle()
                }
            case .advanced(let item):
                switch item {
                case .expirationAction:
                    return ExpirationAction.getTitle()
                case .expirationTime:
                    return DefaultExpirationTime.getTitle()
                }
            case .defaultStyle:
                return String(localized: "style.default")
            case .style(let style):
                return style.name
            case .addStyle:
                return String(localized: "style.add")
            case .shortcuts(let item):
                return item.title
            case .rebuildCloudKitSync:
                return String(localized: "settings.cloudKitSync.rebuild")
            case .clearCloudKitData:
                return String(localized: "settings.cloudKitSync.clear")
            case .reset:
                return String(localized: "settings.reset")
            }
        }
    }
    
    class DataSource: UITableViewDiffableDataSource<Section, Item> {
        weak var owner: SettingsViewController?

        override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
            let sectionKind = sectionIdentifier(for: section)
            return sectionKind?.header
        }
        
        override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
            let sectionKind = sectionIdentifier(for: section)
            if sectionKind == .cloudKit {
                return owner?.cloudKitSyncFooter()
            }
            return sectionKind?.footer
        }
    }

    func cloudKitSyncFooter() -> String? {
        let footer = computedCloudKitSyncFooter()
        lastRenderedCloudKitFooter = footer
        return footer
    }

    private func computedCloudKitSyncFooter() -> String? {
        var parts = [CloudKitSync.getFooter()].compactMap(\.self)
        if let failedOutboxSummary = cloudKitFailedOutboxSummary {
            parts.append(failedOutboxSummary)
        }
        return parts.joined(separator: "\n")
    }

    private nonisolated static func loadCloudKitFailedOutboxSummary() -> String? {
        var failedCount = 0
        var entries: [CloudKitOutboxEntry] = []
        do {
            try AppDatabase.shared.dbWriter?.read { db in
                failedCount = try CloudKitOutboxEntry.failedCount(in: db)
                entries = try CloudKitOutboxEntry.failedEntries(limit: 3, in: db)
            }
        } catch {
            return error.localizedDescription
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
    
    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        
        title = String(localized: "controller.settings.title")
        tabBarItem = UITabBarItem(title: String(localized: "controller.settings.title"), image: UIImage(systemName: "slider.horizontal.2.square"), tag: 2)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        print("SettingsViewController is deinited")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = AppColor.background

        navigationController?.navigationBar.tintColor = .systemRed

        configureHierarchy()
        configureDataSource()
        reloadData()

        if Store.shared.membershipDisplayPrice() == nil {
            Store.shared.retryRequestProducts()
        }

        NotificationCenter.default.addObserver(self, selector: #selector(reloadData), name: .SettingsUpdate, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reloadData), name: .DatabaseUpdated, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reloadData), name: .StoreInfoLoaded, object: nil)
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent
    }
    
    func configureHierarchy() {
        tableView = UITableView(frame: .zero, style: .insetGrouped)
        tableView.backgroundColor = AppColor.background
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "reuseIdentifier")
        tableView.register(PinItPromotionCell.self, forCellReuseIdentifier: NSStringFromClass(PinItPromotionCell.self))
        tableView.register(GratefulCell.self, forCellReuseIdentifier: NSStringFromClass(GratefulCell.self))
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 50.0
        tableView.delegate = self
        view.addSubview(tableView)
        tableView.snp.makeConstraints { make in
            make.edges.equalTo(view)
        }
        tableView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }
    
    func configureDataSource() {
        dataSource = DataSource(tableView: tableView) { [weak self] (tableView, indexPath, item) -> UITableViewCell? in
            guard let self = self else { return nil }
            guard let identifier = dataSource.itemIdentifier(for: indexPath) else { return nil }
            switch identifier {
            case .promotion(let price):
                let cell = tableView.dequeueReusableCell(withIdentifier: NSStringFromClass(PinItPromotionCell.self), for: indexPath)
                if let promotionCell = cell as? PromotionCellConfigurable {
                    promotionCell.update(configuration: PinItPromotion.promotionConfig)
                    promotionCell.update(price: price)
                    promotionCell.purchaseClosure = { [weak self] in
                        self?.lifetimeAction()
                    }
                    promotionCell.restoreClosure = { [weak self] in
                        self?.restorePurchases()
                    }
                }
                return cell
            case .thanks:
                let cell = tableView.dequeueReusableCell(withIdentifier: NSStringFromClass(GratefulCell.self), for: indexPath)
                if let cell = cell as? GratefulCell {
                    cell.update(configuration: PinItPromotion.gratefulConfig)
                }
                return cell
            case .general(let item):
                let cell = tableView.dequeueReusableCell(withIdentifier: "reuseIdentifier", for: indexPath)
                cell.accessoryType = .disclosureIndicator
                var content = UIListContentConfiguration.valueCell()
                content.text = identifier.title
                content.textProperties.color = .label
                content.secondaryText = item.value
                cell.contentConfiguration = content
                return cell
            case .automatic(let item):
                let cell = tableView.dequeueReusableCell(withIdentifier: "reuseIdentifier", for: indexPath)
                cell.accessoryType = .disclosureIndicator
                var content = UIListContentConfiguration.valueCell()
                content.text = identifier.title
                content.textProperties.color = .label
                if case .cloudKitSync = item, isChangingCloudKitSync {
                    content.secondaryText = String(localized: "settings.cloudKitSync.checking")
                } else {
                    content.secondaryText = item.value
                }
                cell.contentConfiguration = content
                return cell
            case .action(let item):
                let cell = tableView.dequeueReusableCell(withIdentifier: "reuseIdentifier", for: indexPath)
                cell.accessoryType = .disclosureIndicator
                var content = UIListContentConfiguration.valueCell()
                content.text = identifier.title
                content.textProperties.color = .label
                content.secondaryText = item.value
                cell.contentConfiguration = content
                return cell
            case .advanced(let item):
                let cell = tableView.dequeueReusableCell(withIdentifier: "reuseIdentifier", for: indexPath)
                cell.accessoryType = .disclosureIndicator
                var content = UIListContentConfiguration.valueCell()
                content.text = identifier.title
                content.textProperties.color = .label
                content.secondaryText = item.value
                cell.contentConfiguration = content
                return cell
            case .defaultStyle(let style):
                let cell = tableView.dequeueReusableCell(withIdentifier: "reuseIdentifier", for: indexPath)
                cell.accessoryType = .disclosureIndicator
                var content = UIListContentConfiguration.valueCell()
                content.text = identifier.title
                content.textProperties.color = .label
                content.secondaryText = style.getName()
                cell.contentConfiguration = content
                return cell
            case .style:
                let cell = tableView.dequeueReusableCell(withIdentifier: "reuseIdentifier", for: indexPath)
                cell.accessoryType = .disclosureIndicator
                var content = UIListContentConfiguration.valueCell()
                content.text = identifier.title
                content.textProperties.color = .label
                content.secondaryText = nil
                cell.contentConfiguration = content
                return cell
            case .addStyle:
                let cell = tableView.dequeueReusableCell(withIdentifier: "reuseIdentifier", for: indexPath)
                cell.accessoryType = .none
                var content = UIListContentConfiguration.subtitleCell()
                content.text = identifier.title
                content.textProperties.color = .systemRed
                content.textProperties.alignment = .center
                cell.contentConfiguration = content
                return cell
            case .shortcuts(let item):
                let cell = tableView.dequeueReusableCell(withIdentifier: "reuseIdentifier", for: indexPath)
                cell.accessoryType = .disclosureIndicator
                var content = UIListContentConfiguration.subtitleCell()
                content.text = identifier.title
                content.textProperties.color = .label
                content.secondaryText = item.subtitle
                content.image = item.image
                cell.contentConfiguration = content
                return cell
            case .rebuildCloudKitSync:
                let cell = tableView.dequeueReusableCell(withIdentifier: "reuseIdentifier", for: indexPath)
                cell.accessoryType = .none
                var content = UIListContentConfiguration.subtitleCell()
                content.text = identifier.title
                content.secondaryText = isRebuildingCloudKitSync ? String(localized: "settings.cloudKitSync.rebuilding") : nil
                content.textProperties.color = isRebuildingCloudKitSync ? .secondaryLabel : .systemRed
                content.textProperties.alignment = .center
                cell.contentConfiguration = content
                cell.isUserInteractionEnabled = !isRebuildingCloudKitSync
                return cell
            case .clearCloudKitData:
                let cell = tableView.dequeueReusableCell(withIdentifier: "reuseIdentifier", for: indexPath)
                cell.accessoryType = .none
                var content = UIListContentConfiguration.subtitleCell()
                content.text = identifier.title
                content.secondaryText = isClearingCloudKitData ? String(localized: "settings.cloudKitSync.clearing") : nil
                content.textProperties.color = isClearingCloudKitData ? .secondaryLabel : .systemRed
                content.textProperties.alignment = .center
                cell.contentConfiguration = content
                cell.isUserInteractionEnabled = !isClearingCloudKitData
                return cell
            case .reset:
                let cell = tableView.dequeueReusableCell(withIdentifier: "reuseIdentifier", for: indexPath)
                cell.accessoryType = .none
                var content = UIListContentConfiguration.subtitleCell()
                content.text = identifier.title
                content.secondaryText = isResettingData ? String(localized: "settings.resetting") : nil
                content.textProperties.color = isResettingData ? .secondaryLabel : .systemRed
                content.textProperties.alignment = .center
                cell.contentConfiguration = content
                cell.isUserInteractionEnabled = !isResettingData
                return cell
            }
        }
        dataSource.owner = self
    }
    
    @objc
    func reloadData() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.reloadData()
            }
            return
        }

        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        
        switch User.shared.proTier() {
        case .lifetime:
            if ThanksEntryState.current != .hidden {
                snapshot.appendSections([.membership])
                snapshot.appendItems([.thanks], toSection: .membership)
            }
        case .none:
            snapshot.appendSections([.membership])
            snapshot.appendItems([.promotion(Store.shared.membershipDisplayPrice() ?? "?.??")], toSection: .membership)
        }
        
        snapshot.appendSections([.general])
        snapshot.appendItems([.general(.language)], toSection: .general)
        
        snapshot.appendSections([.action])
        snapshot.appendItems([.action(.maxPinned(MaxPinnedPosts.getValue())), .action(.deletionConfirm(DeleteOperationConfirmation.getValue()))], toSection: .action)
        
        snapshot.appendSections([.cloudKit])
        snapshot.appendItems([.automatic(.cloudKitSync(CloudKitSync.getValue()))], toSection: .cloudKit)

        snapshot.appendSections([.automatic])
        snapshot.appendItems([.automatic(.autoStart(AutoStartLiveActivity.getValue())), .automatic(.autoEnd(AutoEndLiveActivity.getValue()))], toSection: .automatic)
        
        snapshot.appendSections([.advanced])
        snapshot.appendItems([.advanced(.expirationAction(ExpirationAction.getValue())), .advanced(.expirationTime(DefaultExpirationTime.getValue()))], toSection: .advanced)
        
        let styles = DataManager.shared.fetchAllStyles()
        snapshot.appendSections([.style, .styleList])
        snapshot.appendItems([.defaultStyle(DefaultStyle.getValue())], toSection: .style)
        snapshot.appendItems(styles.map{ Item.style($0) }, toSection: .styleList)
        snapshot.appendItems([Item.addStyle], toSection: .styleList)

        snapshot.appendSections([.shortcuts])
        if Language.type() == .zh {
            snapshot.appendItems([.shortcuts(.first), .shortcuts(.second), .shortcuts(.ai), .shortcuts(.pasteboard), .shortcuts(.copy)], toSection: .shortcuts)
        } else {
            snapshot.appendItems([.shortcuts(.first), .shortcuts(.second), .shortcuts(.pasteboard), .shortcuts(.copy)], toSection: .shortcuts)
        }
        
        snapshot.appendSections([.reset])
        if CloudKitSync.current == .enable {
            snapshot.appendItems([.rebuildCloudKitSync], toSection: .reset)
        } else if CloudKitSync.remoteDataMayExist || CloudKitSync.pendingRemoteReset {
            snapshot.appendItems([.clearCloudKitData], toSection: .reset)
        }
        snapshot.appendItems([.reset], toSection: .reset)

        // Busy states (checking/rebuilding/clearing/resetting) are rendered by the
        // cell provider, but these items' identities don't change with the busy
        // flags — without an explicit reconfigure the diff is empty and the
        // in-progress text and disabled state never appear.
        let busyDependentItems = snapshot.itemIdentifiers.filter { item in
            switch item {
            case .automatic(.cloudKitSync), .rebuildCloudKitSync, .clearCloudKitData, .reset:
                return true
            default:
                return false
            }
        }
        snapshot.reconfigureItems(busyDependentItems)
        // Footer titles aren't re-queried when the diff is empty; if the
        // CloudKit footer text changed (lastError appeared or cleared), force
        // the section to reload so the stale text doesn't linger.
        if lastRenderedCloudKitFooter != nil, computedCloudKitSyncFooter() != lastRenderedCloudKitFooter {
            snapshot.reloadSections([.cloudKit])
        }
        dataSource.apply(snapshot, animatingDifferences: false)
        refreshCloudKitFailedOutboxSummary()
    }

    private func refreshCloudKitFailedOutboxSummary() {
        guard !isLoadingCloudKitFailedOutboxSummary else {
            // Coalesce instead of dropping: a refresh requested while one is in
            // flight re-runs once the current load lands, so the footer can't
            // get stuck on a stale summary until the next SettingsUpdate.
            needsAnotherCloudKitFailedOutboxRefresh = true
            return
        }
        isLoadingCloudKitFailedOutboxSummary = true
        // A plain Task {} would inherit this controller's MainActor isolation and
        // run the database read on the main thread.
        Task.detached(priority: .utility) {
            let summary = SettingsViewController.loadCloudKitFailedOutboxSummary()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isLoadingCloudKitFailedOutboxSummary = false
                defer {
                    if self.needsAnotherCloudKitFailedOutboxRefresh {
                        self.needsAnotherCloudKitFailedOutboxRefresh = false
                        self.refreshCloudKitFailedOutboxSummary()
                    }
                }
                guard self.cloudKitFailedOutboxSummary != summary else { return }
                self.cloudKitFailedOutboxSummary = summary
                guard self.dataSource.snapshot().sectionIdentifiers.contains(.cloudKit) else { return }
                var snapshot = self.dataSource.snapshot()
                snapshot.reloadSections([.cloudKit])
                self.dataSource.apply(snapshot, animatingDifferences: false)
            }
        }
    }
}

extension SettingsViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if let item = dataSource.itemIdentifier(for: indexPath) {
            switch item {
            case .promotion:
                showPromotionAlert()
            case .thanks:
                showThanksAlert()
            case .general(let item):
                switch item {
                case .language:
                    jumpToSettings()
                }
            case .automatic(let item):
                switch item {
                case .cloudKitSync:
                    showCloudKitSyncAlert()
                case .autoStart:
                    enterSettings(AutoStartLiveActivity.self)
                case .autoEnd:
                    enterSettings(AutoEndLiveActivity.self)
                }
            case .action(let item):
                switch item {
                case .maxPinned:
                    enterSettings(MaxPinnedPosts.self)
                case .deletionConfirm:
                    enterSettings(DeleteOperationConfirmation.self)
                }
            case .advanced(let item):
                switch item {
                case .expirationAction:
                    enterSettings(ExpirationAction.self)
                case .expirationTime:
                    enterSettings(DefaultExpirationTime.self)
                }
            case .defaultStyle:
                enterSettings(DefaultStyle.self)
            case .style(let style):
                enterStyleDetail(for: style)
            case .addStyle:
                addStyle()
            case .shortcuts(let item):
                handle(shortcutsItem: item)
            case .rebuildCloudKitSync:
                showCloudKitRebuildAlert()
            case .clearCloudKitData:
                showCloudKitClearAlert()
            case .reset:
                showResetAlert()
            }
        }
    }
}

extension SettingsViewController {
    func enterStyleDetail(for style: PostStyle) {
        let styleViewController = StyleViewController(style: style)
        styleViewController.delegate = self
        
        let nav = UINavigationController(rootViewController: styleViewController)
        
        present(nav, animated: ConsideringUser.animated)
    }
    
    func addStyle() {
        let style: PostStyle = PostStyle.makePlaceholder()
        let styleViewController = StyleViewController(style: style)
        styleViewController.delegate = self
        
        let nav = UINavigationController(rootViewController: styleViewController)
        
        present(nav, animated: ConsideringUser.animated)
    }
}

extension SettingsViewController: StyleEditorDelegate {
    func styleEditor(_ editor: StyleViewController, didUpdateStyle style: PostStyle) {
        if let styleId = style.id {
            // Update: the editor form covers every payload field, so copy them
            // all onto the fresh row; identity and sync metadata stay untouched.
            _ = DataManager.shared.updateStyle(id: styleId) { stored in
                stored.name = style.name
                stored.lockBackgroundColor = style.lockBackgroundColor
                stored.lockTextColor = style.lockTextColor
                stored.lockTextSize = style.lockTextSize
                stored.lockTextAlignment = style.lockTextAlignment
                stored.islandTextColor = style.islandTextColor
                stored.islandTextSize = style.islandTextSize
                stored.islandTextAlignment = style.islandTextAlignment
                stored.symbol = style.symbol
                stored.symbolColor = style.symbolColor
                stored.symbolAngle = style.symbolAngle
                stored.imageDisplayMode = style.imageDisplayMode
                stored.controlAlpha = style.controlAlpha
            }
        } else {
            // Create
            _ = DataManager.shared.add(style: style)
        }
    }
}

extension SettingsViewController {
    func jumpToSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else {
            return
        }
        if UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url, options: [:])
        }
    }
    
    func enterSettings<T: SettingsOption>(_ type: T.Type) {
        let settingsOptionViewController = SettingOptionsViewController<T>()
        settingsOptionViewController.hidesBottomBarWhenPushed = true
        
        navigationController?.pushViewController(settingsOptionViewController, animated: ConsideringUser.pushAnimated)
    }
}

extension SettingsViewController {
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
                message: String(localized: "settings.cloudKitSync.enable.alert.message"),
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

    func showResetAlert() {
        let message: String?
        if CloudKitSync.current == .enable {
            message = String(localized: "settings.reset.alert.cloudKit.message")
        } else if CloudKitSync.remoteDataMayExist || CloudKitSync.pendingRemoteReset {
            message = String(localized: "settings.reset.alert.cloudKitDisabled.message")
        } else {
            message = nil
        }
        let alertController = UIAlertController(title: String(localized: "settings.reset.alert.title"), message: message, preferredStyle: .alert)
        let deleteAction = UIAlertAction(title: String(localized: "settings.reset"), style: .destructive) { [weak self] _ in
            alertController.dismiss(animated: ConsideringUser.animated)
            self?.reset()
        }
        let cancelAction = UIAlertAction(title: String(localized: "button.cancel"), style: .cancel)
        alertController.addAction(deleteAction)
        alertController.addAction(cancelAction)
        present(alertController, animated: ConsideringUser.animated)
    }
    
    func reset() {
        guard !isResettingData else { return }
        isResettingData = true
        reloadData()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            DataManager.shared.reset()
            DispatchQueue.main.async {
                self?.isResettingData = false
                self?.reloadData()
            }
        }
    }

    func showCloudKitRebuildAlert() {
        let message = [
            String(localized: "settings.cloudKitSync.rebuild.alert.message"),
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
            message: String(localized: "settings.cloudKitSync.clear.alert.message"),
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
                        ? String(localized: "settings.cloudKitSync.rebuild.partial.message")
                        : String(localized: "settings.cloudKitSync.rebuild.success.message")
                    )
                }
            } catch is CancellationError {
                // Preempted by a queued local-reset rebuild (or an engine
                // restart): the rebuild has been re-queued and will complete on
                // its own. A "rebuild failed / cancelled" alert would be wrong —
                // the pending-reset footer already explains the state.
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
                        message: String(localized: "settings.cloudKitSync.clear.success.message")
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

extension SettingsViewController {
    func showPromotionAlert() {
        let alertController = UIAlertController(title: String(localized: "promotion.alert.title"), message: String(localized: "promotion.alert.message"), preferredStyle: .alert)
        
        let purchaseAction = UIAlertAction(title: String(localized: "membership.purchase"), style: .default) { [weak self] _ in
            self?.lifetimeAction()
        }
        let restoreAction = UIAlertAction(title: String(localized: "membership.restore"), style: .default) { [weak self] _ in
            self?.restorePurchases()
        }
        let cancelAction = UIAlertAction(title: String(localized: "button.cancel"), style: .cancel)
        
        alertController.addAction(purchaseAction)
        alertController.addAction(restoreAction)
        alertController.addAction(cancelAction)
        
        present(alertController, animated: ConsideringUser.animated)
    }
    
    func showThanksAlert() {
        let alertController = UIAlertController(title: String(localized: "thanks.alert.title"), message: String(localized: "thanks.alert.message"), preferredStyle: .alert)
        
        let removeAction = UIAlertAction(title: String(localized: "button.delete"), style: .destructive) { _ in
            try? ThanksEntryState.setCurrent(.hidden)
        }
        let cancelAction = UIAlertAction(title: String(localized: "button.cancel"), style: .cancel)
        
        alertController.addAction(removeAction)
        alertController.addAction(cancelAction)
        
        present(alertController, animated: ConsideringUser.animated)
    }
    
    func lifetimeAction() {
        showOverlayViewController()
        Task {
            do {
                switch try await Store.shared.purchaseLifetimeMembership() {
                case .success, .alreadyOwned:
                    reloadData()
                case .pending, .cancelled:
                    break
                }
            }
            catch {
                showAlert(title: String(localized: "membership.purchases.order.failure", comment: "Order Failure"), message: error.localizedDescription)
            }

            hideOverlayViewController()
        }
    }

    func restorePurchases() {
        Task {
            showOverlayViewController()
            try? await Store.shared.sync()
            hideOverlayViewController()
        }
    }
}

extension SettingsViewController {
    func handle(shortcutsItem: Item.ShortcutsItem) {
        guard let shortcutsURL = URL(string: shortcutsItem.url) else {
            return
        }
        UIApplication.shared.open(shortcutsURL, options: [:], completionHandler: nil)
    }
}
