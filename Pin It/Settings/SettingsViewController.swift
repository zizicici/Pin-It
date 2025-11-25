//
//  SettingsViewController.swift
//  Pin It
//
//  Created by Ci Zi on 2025/11/1.
//

import UIKit
import SnapKit
import SafariServices
import AppInfo
import StoreKit

class SettingsViewController: UIViewController {
    static let supportEmail = "pin@zi.ci"

    private var tableView: UITableView!
    private var dataSource: DataSource!
    
    enum Section: Hashable {
        case membership
        case general
        case automatic
        case action
        case advanced
        case style
        case shortcuts
        case reset
        
        var header: String? {
            switch self {
            case .membership:
                return nil
            case .general:
                return String(localized: "more.section.general")
            case .automatic:
                return nil
            case .action:
                return nil
            case .advanced:
                return nil
            case .style:
                return String(localized: "more.section.style")
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
        case automatic(AutomaticItem)
        case action(ActionItem)
        case advanced(AdvancedItem)
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
        print("MoreViewController is deinited")
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
        tableView.register(AppCell.self, forCellReuseIdentifier: NSStringFromClass(AppCell.self))
        tableView.register(PromotionCell.self, forCellReuseIdentifier: NSStringFromClass(PromotionCell.self))
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
                let cell = tableView.dequeueReusableCell(withIdentifier: NSStringFromClass(PromotionCell.self), for: indexPath)
                if let cell = cell as? PromotionCell {
                    cell.update(price: price)
                    cell.purchaseClosure = { [weak self] in
                        self?.lifetimeAction()
                    }
                    cell.restoreClosure = { [weak self] in
                        self?.restorePurchases()
                    }
                }
                return cell
            case .thanks:
                let cell = tableView.dequeueReusableCell(withIdentifier: NSStringFromClass(GratefulCell.self), for: indexPath)
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
                content.secondaryText = item.value
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
            case .reset:
                let cell = tableView.dequeueReusableCell(withIdentifier: "reuseIdentifier", for: indexPath)
                cell.accessoryType = .none
                var content = UIListContentConfiguration.subtitleCell()
                content.text = identifier.title
                content.textProperties.color = .systemRed
                content.textProperties.alignment = .center
                cell.contentConfiguration = content
                return cell
            }
        }
    }
    
    @objc
    func reloadData() {
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
        
        snapshot.appendSections([.automatic])
        snapshot.appendItems([.automatic(.autoStart(AutoStartLiveActivity.getValue())), .automatic(.autoEnd(AutoEndLiveActivity.getValue()))], toSection: .automatic)
        
        snapshot.appendSections([.advanced])
        snapshot.appendItems([.advanced(.expirationAction(ExpirationAction.getValue())), .advanced(.expirationTime(DefaultExpirationTime.getValue()))], toSection: .advanced)
        
        let styles = DataManager.shared.fetchAllStyles()
        snapshot.appendSections([.style])
        snapshot.appendItems(styles.map{ Item.style($0) }, toSection: .style)
        snapshot.appendItems([Item.addStyle], toSection: .style)

        snapshot.appendSections([.shortcuts])
        if Language.type() == .zh {
            snapshot.appendItems([.shortcuts(.first), .shortcuts(.second), .shortcuts(.ai), .shortcuts(.pasteboard), .shortcuts(.copy)], toSection: .shortcuts)
        } else {
            snapshot.appendItems([.shortcuts(.first), .shortcuts(.second), .shortcuts(.pasteboard), .shortcuts(.copy)], toSection: .shortcuts)
        }
        
        snapshot.appendSections([.reset])
        snapshot.appendItems([.reset], toSection: .reset)

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
        let style: PostStyle = PostStyle.placeholder
        let styleViewController = StyleViewController(style: style)
        styleViewController.delegate = self
        
        let nav = UINavigationController(rootViewController: styleViewController)
        
        present(nav, animated: ConsideringUser.animated)
    }
}

extension SettingsViewController: StyleEditorDelegate {
    func styleEditor(_ editor: StyleViewController, didUpdateStyle style: PostStyle) {
        if style.id == nil {
            // Create
            _ = DataManager.shared.add(style: style)
        } else {
            // Update
            _ = DataManager.shared.update(style: style)
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
    func showResetAlert() {
        let alertController = UIAlertController(title: String(localized: "settings.reset.alert.title"), message: nil, preferredStyle: .alert)
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
        DataManager.shared.reset()
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
                if let _ = try await Store.shared.purchaseLifetimeMembership() {
                    reloadData()
                }
            }
            catch {
                showAlert(title: String(localized: "membership.purchases.order.failure", comment: "Order Failure"), message: error.localizedDescription)
            }
            
            hideOverlayViewController()
        }
    }
    
    func manageAction() {
        if Store.shared.needRetry {
            Store.shared.retryRequestProducts()
        } else {
            switch User.shared.proTier() {
            case .lifetime:
                restorePurchases()
            case .none:
                restorePurchases()
            }
        }
    }
    
    func restorePurchases() {
        Task {
            showOverlayViewController()
            await Store.shared.sync()
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
