//
//  OnboardingManager.swift
//  Pin It
//
//  Created by Ci Zi on 2025/11/3.
//

import Foundation
import GRDB

class OnboardingManager: NSObject {
    static let shared = OnboardingManager()
    
    override init() {
        super.init()
        
        setupOnboardingDataIfNeeded()
    }
    
    private func checkPostTableNeedsOnboarding() -> Bool {
        var result = false
        do {
            try AppDatabase.shared.reader?.read { db in
                if let sequenceCount = try Int.fetchOne(
                    db,
                    sql: "SELECT seq FROM sqlite_sequence WHERE name = ?",
                    arguments: [Post.databaseTableName]
                ), sequenceCount > 0 {
                    result = false
                } else {
                    result = true
                }
            }
        }
        catch {
            print(error)
        }
        return result
    }
    
    private func checkStyleTableNeedsOnboarding() -> Bool {
        var result = false
        do {
            try AppDatabase.shared.reader?.read { db in
                if let sequenceCount = try Int.fetchOne(
                    db,
                    sql: "SELECT seq FROM sqlite_sequence WHERE name = ?",
                    arguments: [PostStyle.databaseTableName]
                ), sequenceCount > 0 {
                    result = false
                } else {
                    result = true
                }
            }
        }
        catch {
            print(error)
        }
        return result
    }
    
    public func setupOnboardingDataIfNeeded() {
        if checkPostTableNeedsOnboarding() {
            _ = DataManager.shared.createPost(content: String(localized: "onboarding.message.1"), expirationTime: nil)
            _ = DataManager.shared.createPost(content: String(localized: "onboarding.message.2"), isPinned: false, expirationTime: nil)
        }
        if checkStyleTableNeedsOnboarding() {
            _ = DataManager.shared.add(style: PostStyle(name: String(localized: "onboarding.style.1"), lockTextSize: .automatic, lockTextAlignment: .center, islandTextSize: .automatic, islandTextAlignment: .center, symbol: "pin.fill", symbolAngle: -4500, imageDisplayMode: .aspectFit, controlAlpha: 100))
            _ = DataManager.shared.add(style: PostStyle(name: String(localized: "onboarding.style.2"), lockTextSize: .automatic, lockTextAlignment: .center, islandTextSize: .automatic, islandTextAlignment: .center, symbol: "pin.fill", symbolAngle: -4500, imageDisplayMode: .aspectFit, controlAlpha: 0))
        }
    }
}
