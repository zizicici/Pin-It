//
//  MoreViewController.swift
//  Pin It
//
//  Created by Ci Zi on 2025/10/17.
//

import UIKit
import MoreKit
import AppInfo

extension MoreViewController {
    static func makePinIt() -> MoreViewController {
        let config = MoreViewControllerConfiguration(
            title: String(localized: "controller.more.title"),
            tabBarImage: UIImage(systemName: "ellipsis"),
            promotionCellClass: PinItPromotionCell.self,
            promotionConfig: PinItPromotion.promotionConfig,
            gratefulConfig: PinItPromotion.gratefulConfig,
            contactItems: [
                ContactItemConfiguration(id: "email", title: String(localized: "more.item.contact.email"), value: "pin@zi.ci", image: UIImage(systemName: "envelope.circle"), handler: .email("pin@zi.ci")),
                ContactItemConfiguration(id: "xiaohongshu", title: String(localized: "more.item.contact.xiaohongshu"), value: "@App君", image: UIImage(systemName: "book.closed.circle"), handler: .url("https://www.xiaohongshu.com/user/profile/63f05fc5000000001001e524")),
            ],
            appStoreId: "6753946385",
            eulaURL: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/",
            privacyPolicyURL: "https://zizicici.medium.com/privacy-policy-for-pin-it-app-c7215143c58c",
            specificationsConfig: SpecificationsConfiguration(
                summaryItems: [
                    .init(type: .name, value: SpecificationsViewController.getAppName() ?? ""),
                    .init(type: .version, value: SpecificationsViewController.getAppVersion() ?? ""),
                    .init(type: .manufacturer, value: "@App君"),
                    .init(type: .publisher, value: "ZIZICICI LIMITED"),
                    .init(type: .dateOfProduction, value: "2026/01/27"),
                    .init(type: .license, value: "\u{7ca4}ICP\u{5907}2025448771\u{53f7}-4A"),
                ],
                thirdPartyLibraries: [
                    .init(name: "SnapKit", version: "5.7.1", urlString: "https://github.com/SnapKit/SnapKit"),
                    .init(name: "GRDB", version: "7.6.1", urlString: "https://github.com/groue/GRDB.swift"),
                    .init(name: "TOCropViewController", version: "3.1.1", urlString: "https://github.com/TimOliver/TOCropViewController"),
                    .init(name: "Kingfisher", version: "8.6.2", urlString: "https://github.com/onevcat/Kingfisher"),
                    .init(name: "JXPhotoBrowser", version: "3.1.6", urlString: "https://github.com/JiongXing/PhotoBrowser"),
                    .init(name: "SymbolPicker", version: "1.6.2", urlString: "https://github.com/xnth97/SymbolPicker"),
                ]
            ),
            otherApps: [.coconut, .moontake, .lemon, .offDay, .tagDay, .one, .pigeon],
            otherAppsDisplayCount: 3
        )
        return MoreViewController(configuration: config, dataSource: PinItMoreDataSource())
    }
}

class PinItMoreDataSource: MoreViewControllerDataSource {

    func sections(for controller: MoreViewController) -> [MoreSectionType] {
        [.appjun, .contact, .about]
    }

    func moreViewController(_ controller: MoreViewController, didSelectCustomItem item: MoreCustomItem) {
        // No custom sections
    }
}
