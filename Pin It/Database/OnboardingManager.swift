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
        
        if checkPostTableNeedsOnboarding() {
            _ = DataManager.shared.createPost(content: String(localized: "onboarding.message.1"))
            _ = DataManager.shared.createPost(content: String(localized: "onboarding.message.2"), isPinned: false)
        }
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
}
