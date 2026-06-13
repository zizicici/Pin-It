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
    private var isResettingData = false
    
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
            case autoStart(AutoStartLiveActivity)
            case autoEnd(AutoEndLiveActivity)

            var value: String {
                switch self {
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
        case cloudKitSettings(CloudKitSync)
        case automatic(AutomaticItem)
        case action(ActionItem)
        case advanced(AdvancedItem)
        case defaultStyle(DefaultStyle)
        case style(PostStyle)
        case addStyle
        case shortcuts(ShortcutsItem)
        case reset
        
        var title: String {
            switch self {
            case .promotion, .thanks:
                return ""
            case .general(let item):
                return item.title
            case .cloudKitSettings:
                return CloudKitSync.getTitle()
            case .automatic(let item):
                switch item {
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
            case .reset:
                return String(localized: "settings.reset")
            }
        }
    }
    
    class DataSource: UITableViewDiffableDataSource<Section, Item> {
        override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
            let sectionKind = sectionIdentifier(for: section)
            return sectionKind?.header
        }
        
        override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
            let sectionKind = sectionIdentifier(for: section)
            return sectionKind?.footer
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
                // The busy branches (rebuild/clear/reset) disable interaction;
                // the shared reuse pool must reset it, or recycled cells stay
                // permanently dead on unrelated rows.
                cell.isUserInteractionEnabled = true
                cell.accessoryType = .disclosureIndicator
                var content = UIListContentConfiguration.valueCell()
                content.text = identifier.title
                content.textProperties.color = .label
                content.secondaryText = item.value
                cell.contentConfiguration = content
                return cell
            case .cloudKitSettings(let cloudKitSync):
                let cell = tableView.dequeueReusableCell(withIdentifier: "reuseIdentifier", for: indexPath)
                // The busy branches (rebuild/clear/reset) disable interaction;
                // the shared reuse pool must reset it, or recycled cells stay
                // permanently dead on unrelated rows.
                cell.isUserInteractionEnabled = true
                cell.accessoryType = .disclosureIndicator
                var content = UIListContentConfiguration.valueCell()
                content.text = identifier.title
                content.textProperties.color = .label
                content.secondaryText = cloudKitSync.getName()
                cell.contentConfiguration = content
                return cell
            case .automatic(let item):
                let cell = tableView.dequeueReusableCell(withIdentifier: "reuseIdentifier", for: indexPath)
                // The busy branches (rebuild/clear/reset) disable interaction;
                // the shared reuse pool must reset it, or recycled cells stay
                // permanently dead on unrelated rows.
                cell.isUserInteractionEnabled = true
                cell.accessoryType = .disclosureIndicator
                var content = UIListContentConfiguration.valueCell()
                content.text = identifier.title
                content.textProperties.color = .label
                content.secondaryText = item.value
                cell.contentConfiguration = content
                return cell
            case .action(let item):
                let cell = tableView.dequeueReusableCell(withIdentifier: "reuseIdentifier", for: indexPath)
                // The busy branches (rebuild/clear/reset) disable interaction;
                // the shared reuse pool must reset it, or recycled cells stay
                // permanently dead on unrelated rows.
                cell.isUserInteractionEnabled = true
                cell.accessoryType = .disclosureIndicator
                var content = UIListContentConfiguration.valueCell()
                content.text = identifier.title
                content.textProperties.color = .label
                content.secondaryText = item.value
                cell.contentConfiguration = content
                return cell
            case .advanced(let item):
                let cell = tableView.dequeueReusableCell(withIdentifier: "reuseIdentifier", for: indexPath)
                // The busy branches (rebuild/clear/reset) disable interaction;
                // the shared reuse pool must reset it, or recycled cells stay
                // permanently dead on unrelated rows.
                cell.isUserInteractionEnabled = true
                cell.accessoryType = .disclosureIndicator
                var content = UIListContentConfiguration.valueCell()
                content.text = identifier.title
                content.textProperties.color = .label
                content.secondaryText = item.value
                cell.contentConfiguration = content
                return cell
            case .defaultStyle(let style):
                let cell = tableView.dequeueReusableCell(withIdentifier: "reuseIdentifier", for: indexPath)
                // The busy branches (rebuild/clear/reset) disable interaction;
                // the shared reuse pool must reset it, or recycled cells stay
                // permanently dead on unrelated rows.
                cell.isUserInteractionEnabled = true
                cell.accessoryType = .disclosureIndicator
                var content = UIListContentConfiguration.valueCell()
                content.text = identifier.title
                content.textProperties.color = .label
                content.secondaryText = style.getName()
                cell.contentConfiguration = content
                return cell
            case .style:
                let cell = tableView.dequeueReusableCell(withIdentifier: "reuseIdentifier", for: indexPath)
                // The busy branches (rebuild/clear/reset) disable interaction;
                // the shared reuse pool must reset it, or recycled cells stay
                // permanently dead on unrelated rows.
                cell.isUserInteractionEnabled = true
                cell.accessoryType = .disclosureIndicator
                var content = UIListContentConfiguration.valueCell()
                content.text = identifier.title
                content.textProperties.color = .label
                content.secondaryText = nil
                cell.contentConfiguration = content
                return cell
            case .addStyle:
                let cell = tableView.dequeueReusableCell(withIdentifier: "reuseIdentifier", for: indexPath)
                // The busy branches (rebuild/clear/reset) disable interaction;
                // the shared reuse pool must reset it, or recycled cells stay
                // permanently dead on unrelated rows.
                cell.isUserInteractionEnabled = true
                cell.accessoryType = .none
                var content = UIListContentConfiguration.subtitleCell()
                content.text = identifier.title
                content.textProperties.color = .systemRed
                content.textProperties.alignment = .center
                cell.contentConfiguration = content
                return cell
            case .shortcuts(let item):
                let cell = tableView.dequeueReusableCell(withIdentifier: "reuseIdentifier", for: indexPath)
                // The busy branches (rebuild/clear/reset) disable interaction;
                // the shared reuse pool must reset it, or recycled cells stay
                // permanently dead on unrelated rows.
                cell.isUserInteractionEnabled = true
                cell.accessoryType = .disclosureIndicator
                var content = UIListContentConfiguration.subtitleCell()
                content.text = identifier.title
                content.textProperties.color = .label
                content.secondaryText = item.subtitle
                content.image = item.image
                cell.contentConfiguration = content
                return cell
            case .reset:
                let cell = tableView.dequeueReusableCell(withIdentifier: "reuseIdentifier", for: indexPath)
                // The busy branches (rebuild/clear/reset) disable interaction;
                // the shared reuse pool must reset it, or recycled cells stay
                // permanently dead on unrelated rows.
                cell.isUserInteractionEnabled = true
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
        snapshot.appendItems([.cloudKitSettings(CloudKitSync.getValue())], toSection: .cloudKit)

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
        snapshot.appendItems([.reset], toSection: .reset)

        // Busy states (checking/rebuilding/clearing/resetting) are rendered by the
        // cell provider, but these items' identities don't change with the busy
        // flags — without an explicit reconfigure the diff is empty and the
        // in-progress text and disabled state never appear.
        let busyDependentItems = snapshot.itemIdentifiers.filter { item in
            switch item {
            case .cloudKitSettings, .reset:
                return true
            default:
                return false
            }
        }
        snapshot.reconfigureItems(busyDependentItems)
        dataSource.apply(snapshot, animatingDifferences: false)
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
            case .cloudKitSettings:
                enterCloudKitSettings()
            case .automatic(let item):
                switch item {
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
            let updated = DataManager.shared.updateStyle(id: styleId) { stored in
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
            if !updated, DataManager.shared.fetchStyle(by: styleId) == nil {
                // The delegate fires BEFORE the editor dismisses itself;
                // presenting while the editor modal is still up would be
                // silently refused by UIKit. Dismiss first, then present.
                if presentedViewController != nil {
                    dismiss(animated: ConsideringUser.animated) { [weak self] in
                        self?.presentStyleEditConflictAlert(for: style)
                    }
                } else {
                    presentStyleEditConflictAlert(for: style)
                }
            }
        } else {
            // Create
            _ = DataManager.shared.add(style: style)
        }
    }

    /// The style was deleted on another device while the editor was open
    /// (deletion-wins): the save above silently hit a missing row and the
    /// whole edit session would vanish without a word. Every edited field is
    /// still in memory — offer to re-create it as a NEW style.
    private func presentStyleEditConflictAlert(for style: PostStyle) {
        let alertController = UIAlertController(
            title: String(localized: "pin.editConflict.alert.title"),
            message: String(localized: "pin.editConflict.alert.message"),
            preferredStyle: .alert
        )
        alertController.addAction(UIAlertAction(title: String(localized: "pin.editConflict.alert.saveAsNew"), style: .default) { _ in
            var newStyle = style
            newStyle.id = nil
            newStyle.syncId = UUID().uuidString
            newStyle.creationTime = nil
            newStyle.modificationTime = nil
            _ = DataManager.shared.add(style: newStyle)
        })
        alertController.addAction(UIAlertAction(title: String(localized: "pin.editConflict.alert.discard"), style: .cancel))
        present(alertController, animated: ConsideringUser.animated)
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

    func enterCloudKitSettings() {
        navigationController?.pushViewController(CloudKitSettingsViewController(), animated: ConsideringUser.pushAnimated)
    }
}

extension SettingsViewController {
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
