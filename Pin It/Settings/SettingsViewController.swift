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
        
        var header: String? {
            switch self {
            case .membership:
                return nil
            case .general:
                return String(localized: "more.section.general")
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
        
        case promotion(String)
        case thanks
        case settings(GeneralItem)
        
        var title: String {
            switch self {
            case .promotion, .thanks:
                return ""
            case .settings(let item):
                return item.title
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
            case .settings(let item):
                let cell = tableView.dequeueReusableCell(withIdentifier: "reuseIdentifier", for: indexPath)
                cell.accessoryType = .disclosureIndicator
                var content = UIListContentConfiguration.valueCell()
                content.text = identifier.title
                content.textProperties.color = .label
                content.secondaryText = item.value
                cell.contentConfiguration = content
                return cell
            }
        }
    }
    
    @objc
    func reloadData() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        
        snapshot.appendSections([.membership])
        switch User.shared.proTier() {
        case .lifetime:
            snapshot.appendItems([.thanks], toSection: .membership)
        case .none:
            snapshot.appendItems([.promotion(Store.shared.membershipDisplayPrice() ?? "?.??")], toSection: .membership)
        }
        
        snapshot.appendSections([.general])
        snapshot.appendItems([.settings(.language)], toSection: .general)

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
                break
            case .settings(let item):
                switch item {
                case .language:
                    jumpToSettings()
                }
            }
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
