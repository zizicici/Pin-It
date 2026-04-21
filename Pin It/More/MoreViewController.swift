//
//  MoreViewController.swift
//  Pin It
//
//  Created by Ci Zi on 2025/10/17.
//

import UIKit
import MoreKit

extension MoreViewController {
    static func makePinIt() -> MoreViewController {
        let config = MoreViewControllerConfiguration(
            title: String(localized: "controller.more.title"),
            tabBarImage: UIImage(systemName: "ellipsis"),
            promotionCellClass: PinItPromotionCell.self,
            promotionConfig: PinItPromotion.promotionConfig,
            gratefulConfig: PinItPromotion.gratefulConfig,
            email: "pin@zi.ci",
            appStoreId: "6753946385",
            privacyPolicyURL: "https://zizicici.medium.com/privacy-policy-for-pin-it-app-c7215143c58c",
            specificationsConfig: SpecificationsConfiguration(
                summaryItems: [
                    .init(type: .name, value: SpecificationsViewController.getAppName() ?? ""),
                    .init(type: .version, value: SpecificationsViewController.getAppVersion() ?? ""),
                    .init(type: .manufacturer, value: "@App君"),
                    .init(type: .publisher, value: "ZIZICICI LIMITED"),
                    .init(type: .dateOfProduction, value: "2026/04/21"),
                    .init(type: .license, value: "粤ICP备2025448771号-4A"),
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
            appShowcase: AppShowcaseConfiguration(
                apps: [.lemon, .moontake, .coconut, .festivals, .pigeon, .one, .offDay, .tagDay, .campfire, .watermelon, .doufu],
                displayCount: 3
            )
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
