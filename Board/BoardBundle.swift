//
//  BoardBundle.swift
//  Board
//
//  Created by Ci Zi on 2025/10/13.
//

import WidgetKit
import SwiftUI
import MoreKit

@main
struct BoardBundle: WidgetBundle {
    init() {
        MoreKit.configure(
            productID: "com.zizicici.pin.pro",
            appGroupID: appGroupId,
            membershipKey: "com.zizicici.pin.Store.LifetimeMembership"
        )
    }

    var body: some Widget {
        StartButtonWidget()
        BoardLiveActivity()
    }
}
