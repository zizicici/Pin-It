//
//  OnboardingManager.swift
//  Pin It
//
//  Created by Ci Zi on 2025/11/3.
//

import Foundation
import GRDB
import MoreKit

struct OnboardingLocalRecord: Codable, FetchableRecord, MutablePersistableRecord, TableRecord, Identifiable {
    static let databaseTableName = "local_onboarding_record"

    var id: Int64?
    var recordType: String
    var syncId: String

    enum Columns {
        static let recordType = Column(CodingKeys.recordType)
        static let syncId = Column(CodingKeys.syncId)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case recordType = "record_type"
        case syncId = "sync_id"
    }
}

extension OnboardingLocalRecord {
    init(recordType: CloudKitRecordType, syncId: String) {
        self.recordType = recordType.rawValue
        self.syncId = syncId
    }

    static func mark(recordType: CloudKitRecordType, syncId: String, in db: Database) throws {
        var record = OnboardingLocalRecord(recordType: recordType, syncId: syncId)
        let recordName = CloudKitRecordName.make(recordType, syncId: syncId)
        try record.save(db)
        try CloudKitOutboxEntry.clear(recordName: recordName, in: db)
        try CloudKitRecordMetadata.deleteOne(db, key: recordName)
        try CloudKitLocalTombstone.deleteOne(db, key: recordName)
    }

    static func unmark(recordType: CloudKitRecordType, syncId: String, in db: Database) throws {
        _ = try OnboardingLocalRecord
            .filter(Columns.recordType == recordType.rawValue && Columns.syncId == syncId)
            .deleteAll(db)
    }

    static func unmark(recordType: CloudKitRecordType, syncIds: [String], in db: Database) throws {
        guard !syncIds.isEmpty else { return }
        _ = try OnboardingLocalRecord
            .filter(Columns.recordType == recordType.rawValue && syncIds.contains(Columns.syncId))
            .deleteAll(db)
    }

    static func isMarked(recordType: CloudKitRecordType, syncId: String, in db: Database) throws -> Bool {
        try OnboardingLocalRecord
            .filter(Columns.recordType == recordType.rawValue && Columns.syncId == syncId)
            .fetchCount(db) > 0
    }

}

enum OnboardingSeedState: Int, CaseIterable, Codable {
    case pending = 0
    case seeded
    case dismissed
}

extension OnboardingSeedState: UserDefaultSettable {
    static func getKey() -> String {
        UserDefaults.Settings.OnboardingSeedState.rawValue
    }

    static var defaultOption: Self {
        .pending
    }

    func getName() -> String {
        "\(rawValue)"
    }

    static func getTitle() -> String {
        ""
    }
}

class OnboardingManager: NSObject {
    static let shared = OnboardingManager()
    
    override init() {
        super.init()
    }
    
    public func setupOnboardingDataIfNeeded() {
        var didChangeDatabase = false
        var didChangeStyles = false
        do {
            try AppDatabase.shared.dbWriter?.write { db in
                if canMarkExistingOnboardingRecords {
                    try markExistingOnboardingRecords(in: db)
                }
                try cleanupDanglingOnboardingMarkers(in: db)

                guard OnboardingSeedState.current == .pending else { return }
                let explicitSeed = explicitOnboardingSeedRequested()
                let needsStyles = try PostStyle.fetchCount(db) == 0
                && (explicitSeed || (try sqliteSequence(for: PostStyle.databaseTableName, in: db) ?? 0) == 0)
                let needsPosts = try Post.fetchCount(db) == 0
                && (explicitSeed || (try sqliteSequence(for: Post.databaseTableName, in: db) ?? 0) == 0)
                var defaultStyleId: Int64?

                if needsStyles {
                    var firstStyle = PostStyle(
                        name: String(localized: "onboarding.style.1"),
                        lockTextSize: .automatic,
                        lockTextAlignment: .center,
                        islandTextSize: .automatic,
                        islandTextAlignment: .center,
                        symbol: "pin.fill",
                        symbolAngle: -4500,
                        imageDisplayMode: .aspectFit,
                        controlAlpha: 100
                    )
                    try firstStyle.save(db)
                    try OnboardingLocalRecord.mark(recordType: .style, syncId: firstStyle.syncId, in: db)
                    defaultStyleId = firstStyle.id

                    var secondStyle = PostStyle(
                        name: String(localized: "onboarding.style.2"),
                        lockTextSize: .automatic,
                        lockTextAlignment: .center,
                        islandTextSize: .automatic,
                        islandTextAlignment: .center,
                        symbol: "pin.fill",
                        symbolAngle: -4500,
                        imageDisplayMode: .aspectFill,
                        controlAlpha: 0
                    )
                    try secondStyle.save(db)
                    try OnboardingLocalRecord.mark(recordType: .style, syncId: secondStyle.syncId, in: db)
                    didChangeDatabase = true
                    didChangeStyles = true
                }

                if needsPosts {
                    try seedOnboardingPost(
                        content: String(localized: "onboarding.message.1"),
                        isPinned: true,
                        order: 0,
                        in: db
                    )
                    try seedOnboardingPost(
                        content: String(localized: "onboarding.message.2"),
                        isPinned: false,
                        order: 0,
                        in: db
                    )
                    didChangeDatabase = true
                }

                let seededDefaultStyleId = defaultStyleId
                // afterNextTransaction runs on the GRDB writer queue, never main.
                db.afterNextTransaction { _ in
                    if let defaultStyleId = seededDefaultStyleId {
                        try? DefaultStyle.setCurrent(DefaultStyle(rawValue: Int(defaultStyleId)), promotesLocalOnboarding: false)
                    }
                    OnboardingSeedState.setValue(.seeded)
                }
            }
        } catch {
            print(error)
            return
        }

        if didChangeDatabase {
            postOnMain(.DatabaseUpdated)
        }
        if didChangeStyles {
            postOnMain(.DatabaseStyleUpdated)
        }
    }

    func requestOnboardingSeed() {
        // Reached from the CloudKit sync thread; keep the notification on main.
        OnboardingSeedState.setValue(.pending)
    }
}

private extension OnboardingManager {
    func explicitOnboardingSeedRequested() -> Bool {
        let defaults = UserDefaults(suiteName: appGroupId) ?? .standard
        return defaults.object(forKey: UserDefaults.Settings.OnboardingSeedState.rawValue) != nil
        && OnboardingSeedState.current == .pending
    }

    func sqliteSequence(for tableName: String, in db: Database) throws -> Int64? {
        let row = try Table("sqlite_sequence")
            .select(Column("seq"))
            .filter(Column("name") == tableName)
            .fetchOne(db)
        return row?["seq"]
    }

    func seedOnboardingPost(content: String, isPinned: Bool, order: Int64, in db: Database) throws {
        var post = Post(
            expirationTime: nil,
            actionLink: "",
            isPinned: isPinned,
            order: order
        )
        try post.save(db)
        try OnboardingLocalRecord.mark(recordType: .post, syncId: post.syncId, in: db)
        guard let postId = post.id else { return }

        var text = PostText(postId: postId, content: content, order: 0)
        try text.save(db)
        try OnboardingLocalRecord.mark(recordType: .text, syncId: text.syncId, in: db)
    }
}

extension OnboardingManager {
    func markExistingOnboardingRecordsIfNeeded() {
        do {
            try AppDatabase.shared.dbWriter?.write { db in
                if canMarkExistingOnboardingRecords {
                    try markExistingOnboardingRecords(in: db)
                }
                try cleanupDanglingOnboardingMarkers(in: db)
            }
        } catch {
            print(error)
        }
    }

    func promotePostGraphToUserContent(postId: Int64, in db: Database) throws {
        if let post = try Post.fetchOne(db, id: postId) {
            try promoteRecord(recordType: .post, syncId: post.syncId, modificationTime: post.modificationTime, in: db)
        }

        let texts = try PostText
            .filter(Column(PostText.CodingKeys.postId) == postId)
            .fetchAll(db)
        for text in texts {
            try promoteRecord(recordType: .text, syncId: text.syncId, modificationTime: text.modificationTime, in: db)
        }

        let images = try PostImage
            .filter(Column(PostImage.CodingKeys.postId) == postId)
            .fetchAll(db)
        for image in images {
            try promoteRecord(recordType: .image, syncId: image.syncId, modificationTime: image.modificationTime, in: db)
        }

        let decorations = try PostDecoration
            .filter(Column(PostDecoration.CodingKeys.postId) == postId)
            .fetchAll(db)
        for decoration in decorations {
            try promoteRecord(recordType: .decoration, syncId: decoration.syncId, modificationTime: decoration.modificationTime, in: db)
        }
    }

    func promoteStyleToUserContent(styleId: Int64, in db: Database) throws {
        guard let style = try PostStyle.fetchOne(db, id: styleId) else { return }
        try promoteRecord(recordType: .style, syncId: style.syncId, modificationTime: style.modificationTime, in: db)
    }

    @discardableResult
    func removeLocalOnlyOnboardingData(in db: Database) throws -> (didChangeDatabase: Bool, didChangeStyles: Bool) {
        var didChangeDatabase = false
        var didChangeStyles = false

        let markedRecords = try OnboardingLocalRecord.fetchAll(db)
        let markedPostSyncIds = Set(markedRecords.filter { $0.recordType == CloudKitRecordType.post.rawValue }.map(\.syncId))
        let markedStyleSyncIds = Set(markedRecords.filter { $0.recordType == CloudKitRecordType.style.rawValue }.map(\.syncId))

        for syncId in markedPostSyncIds {
            guard let post = try Post
                .filter(Column(Post.CodingKeys.syncId) == syncId)
                .fetchOne(db),
                  let postId = post.id else {
                try OnboardingLocalRecord.unmark(recordType: .post, syncId: syncId, in: db)
                continue
            }

            let texts = try PostText
                .filter(Column(PostText.CodingKeys.postId) == postId)
                .fetchAll(db)
            let images = try PostImage
                .filter(Column(PostImage.CodingKeys.postId) == postId)
                .fetchAll(db)
            let decorations = try PostDecoration
                .filter(Column(PostDecoration.CodingKeys.postId) == postId)
                .fetchAll(db)

            let allChildrenAreLocalOnly = try texts.allSatisfy { text in
                try OnboardingLocalRecord.isMarked(recordType: .text, syncId: text.syncId, in: db)
            } && images.allSatisfy { image in
                try OnboardingLocalRecord.isMarked(recordType: .image, syncId: image.syncId, in: db)
            } && decorations.allSatisfy { decoration in
                try OnboardingLocalRecord.isMarked(recordType: .decoration, syncId: decoration.syncId, in: db)
            }
            guard allChildrenAreLocalOnly else { continue }

            try PostText.deleteAll(db, ids: texts.compactMap(\.id))
            try PostImage.deleteAll(db, ids: images.compactMap(\.id))
            try PostDecoration.deleteAll(db, ids: decorations.compactMap(\.id))
            try Post.deleteAll(db, ids: [postId])

            try OnboardingLocalRecord.unmark(recordType: .post, syncId: post.syncId, in: db)
            try OnboardingLocalRecord.unmark(recordType: .text, syncIds: texts.map(\.syncId), in: db)
            try OnboardingLocalRecord.unmark(recordType: .image, syncIds: images.map(\.syncId), in: db)
            try OnboardingLocalRecord.unmark(recordType: .decoration, syncIds: decorations.map(\.syncId), in: db)
            didChangeDatabase = true
        }

        for syncId in markedStyleSyncIds {
            guard let style = try PostStyle
                .filter(Column(PostStyle.CodingKeys.syncId) == syncId)
                .fetchOne(db),
                  let styleId = style.id else {
                try OnboardingLocalRecord.unmark(recordType: .style, syncId: syncId, in: db)
                continue
            }

            let decorationCount = try PostDecoration
                .filter(Column(PostDecoration.CodingKeys.styleId) == styleId)
                .fetchCount(db)
            guard decorationCount == 0 else { continue }

            // syncId order — deterministic across devices; see delete(style:).
            let fallbackStyle = try PostStyle
                .filter(PostStyle.Columns.id != styleId)
                .order(Column(PostStyle.CodingKeys.syncId).asc)
                .fetchOne(db)
            try PostStyle.deleteAll(db, ids: [styleId])
            let replacementTime = try db.transactionDate.millisecondsSince1970
            if try DefaultStyle.replaceDeletedStyleIfNeeded(
                deletedStyle: style,
                fallbackStyle: fallbackStyle,
                modificationTime: replacementTime,
                in: db
            ), CloudKitSync.current == .enable || CloudKitSync.pendingRemoteReset {
                // The replace advanced the setting's LWW stamp; without a
                // matching push the fresh local stamp would silently outrank
                // (and forever block) a peer's older explicit default-style
                // record that arrives later. Keep stamp and wire in step.
                try CloudKitOutboxEntry.enqueueSetting(modificationTime: replacementTime, in: db)
            }
            try OnboardingLocalRecord.unmark(recordType: .style, syncId: style.syncId, in: db)
            didChangeDatabase = true
            didChangeStyles = true
        }

        try cleanupDanglingOnboardingMarkers(in: db)
        return (didChangeDatabase, didChangeStyles)
    }
}

private extension OnboardingManager {
    var canMarkExistingOnboardingRecords: Bool {
        OnboardingSeedState.current != .dismissed
    }

    func postOnMain(_ name: Notification.Name) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: name, object: nil)
        }
    }

    func promoteRecord(recordType: CloudKitRecordType, syncId: String, modificationTime: Int64?, in db: Database) throws {
        guard try OnboardingLocalRecord.isMarked(recordType: recordType, syncId: syncId, in: db) else { return }
        // afterNextTransaction runs on the GRDB writer queue, never main.
        db.afterNextTransaction { _ in
            OnboardingSeedState.setValue(.dismissed)
        }
        try OnboardingLocalRecord.unmark(recordType: recordType, syncId: syncId, in: db)
        guard tracksLocalCloudKitChanges() else { return }
        try CloudKitOutboxEntry.enqueueSave(recordType: recordType, syncId: syncId, modificationTime: modificationTime, in: db)
    }

    func tracksLocalCloudKitChanges() -> Bool {
        CloudKitSync.current == .enable || CloudKitSync.pendingRemoteReset
    }

    func markStyleAsOnboarding(_ style: PostStyle) {
        do {
            try AppDatabase.shared.dbWriter?.write { db in
                try OnboardingLocalRecord.mark(recordType: .style, syncId: style.syncId, in: db)
            }
        } catch {
            print(error)
        }
    }

    func markPostGraphAsOnboarding(postId: Int64) {
        do {
            try AppDatabase.shared.dbWriter?.write { db in
                try markPostGraphAsOnboarding(postId: postId, in: db)
            }
        } catch {
            print(error)
        }
    }

    func markPostGraphAsOnboarding(postId: Int64, in db: Database) throws {
        if let post = try Post.fetchOne(db, id: postId) {
            try OnboardingLocalRecord.mark(recordType: .post, syncId: post.syncId, in: db)
        }
        let texts = try PostText
            .filter(Column(PostText.CodingKeys.postId) == postId)
            .fetchAll(db)
        for text in texts {
            try OnboardingLocalRecord.mark(recordType: .text, syncId: text.syncId, in: db)
        }
        let images = try PostImage
            .filter(Column(PostImage.CodingKeys.postId) == postId)
            .fetchAll(db)
        for image in images {
            try OnboardingLocalRecord.mark(recordType: .image, syncId: image.syncId, in: db)
        }
        let decorations = try PostDecoration
            .filter(Column(PostDecoration.CodingKeys.postId) == postId)
            .fetchAll(db)
        for decoration in decorations {
            try OnboardingLocalRecord.mark(recordType: .decoration, syncId: decoration.syncId, in: db)
        }
    }

    func markExistingOnboardingRecords(in db: Database) throws {
        if try existingPostsAreExactlyOnboardingSeed(in: db) {
            for post in try Post.fetchAll(db) {
                if let postId = post.id {
                    try markPostGraphAsOnboarding(postId: postId, in: db)
                }
            }
        }

        if try existingStylesAreExactlyOnboardingSeed(in: db) {
            for style in try PostStyle.fetchAll(db) {
                try OnboardingLocalRecord.mark(recordType: .style, syncId: style.syncId, in: db)
            }
        }
    }

    func existingPostsAreExactlyOnboardingSeed(in db: Database) throws -> Bool {
        let posts = try Post.order(Column(Post.CodingKeys.id).asc).fetchAll(db)
        guard posts.count == 2,
              posts.compactMap(\.id) == [1, 2],
              posts.map(\.isPinned) == [true, false],
              posts.allSatisfy({ $0.actionLink.isEmpty && $0.expirationTime == nil }) else {
            return false
        }

        let messageValues = localizedValues(for: ["onboarding.message.1", "onboarding.message.2"])
        for (index, post) in posts.enumerated() {
            guard let postId = post.id else { return false }
            let texts = try PostText
                .filter(Column(PostText.CodingKeys.postId) == postId)
                .fetchAll(db)
            let imageCount = try PostImage
                .filter(Column(PostImage.CodingKeys.postId) == postId)
                .fetchCount(db)
            let decorationCount = try PostDecoration
                .filter(Column(PostDecoration.CodingKeys.postId) == postId)
                .fetchCount(db)
            guard texts.count == 1,
                  messageValues.indices.contains(index),
                  messageValues[index].contains(texts[0].content),
                  imageCount == 0,
                  decorationCount == 0 else {
                return false
            }
        }
        return true
    }

    func existingStylesAreExactlyOnboardingSeed(in db: Database) throws -> Bool {
        let styles = try PostStyle.order(Column(PostStyle.CodingKeys.id).asc).fetchAll(db)
        guard styles.count == 2,
              styles.compactMap(\.id) == [1, 2] else {
            return false
        }

        let styleNames = localizedValues(for: ["onboarding.style.1", "onboarding.style.2"])
        guard styleNames.count == 2 else { return false }
        let firstStyleNames = styleNames[0]
        let secondStyleNames = styleNames[1]
        guard firstStyleNames.contains(styles[0].name),
              secondStyleNames.contains(styles[1].name),
              isFirstOnboardingStyle(styles[0]),
              isSecondOnboardingStyle(styles[1]) else {
            return false
        }

        for style in styles {
            guard let styleId = style.id else { return false }
            let decorationCount = try PostDecoration
                .filter(Column(PostDecoration.CodingKeys.styleId) == styleId)
                .fetchCount(db)
            guard decorationCount == 0 else { return false }
        }
        return true
    }

    func cleanupDanglingOnboardingMarkers(in db: Database) throws {
        let records = try OnboardingLocalRecord.fetchAll(db)
        for record in records {
            guard let recordType = CloudKitRecordType(rawValue: record.recordType) else {
                if let id = record.id {
                    try OnboardingLocalRecord.deleteAll(db, ids: [id])
                }
                continue
            }
            guard try recordExists(recordType: recordType, syncId: record.syncId, in: db) else {
                try OnboardingLocalRecord.unmark(recordType: recordType, syncId: record.syncId, in: db)
                continue
            }
        }
    }

    func recordExists(recordType: CloudKitRecordType, syncId: String, in db: Database) throws -> Bool {
        switch recordType {
        case .post:
            return try Post.filter(Column(Post.CodingKeys.syncId) == syncId).fetchCount(db) > 0
        case .text:
            return try PostText.filter(Column(PostText.CodingKeys.syncId) == syncId).fetchCount(db) > 0
        case .image:
            return try PostImage.filter(Column(PostImage.CodingKeys.syncId) == syncId).fetchCount(db) > 0
        case .style:
            return try PostStyle.filter(Column(PostStyle.CodingKeys.syncId) == syncId).fetchCount(db) > 0
        case .decoration:
            return try PostDecoration.filter(Column(PostDecoration.CodingKeys.syncId) == syncId).fetchCount(db) > 0
        case .setting:
            return false
        }
    }

    func localizedValues(for keys: [String]) -> [Set<String>] {
        keys.map { key in
            var values: Set<String> = []
            let currentValue = String(localized: String.LocalizationValue(key))
            if currentValue != key {
                values.insert(currentValue)
            }

            for localization in Bundle.main.localizations {
                guard let path = Bundle.main.path(forResource: localization, ofType: "lproj"),
                      let bundle = Bundle(path: path) else {
                    continue
                }
                let value = bundle.localizedString(forKey: key, value: nil, table: nil)
                if value != key {
                    values.insert(value)
                }
            }
            return values
        }
    }

    func isFirstOnboardingStyle(_ style: PostStyle) -> Bool {
        isOnboardingStyleBase(style)
        && style.imageDisplayMode == .aspectFit
        && style.controlAlpha == 100
    }

    func isSecondOnboardingStyle(_ style: PostStyle) -> Bool {
        isOnboardingStyleBase(style)
        && style.imageDisplayMode == .aspectFill
        && style.controlAlpha == 0
    }

    func isOnboardingStyleBase(_ style: PostStyle) -> Bool {
        style.lockBackgroundColor == nil
        && style.lockTextColor == nil
        && style.islandTextColor == nil
        && style.symbolColor == nil
        && style.lockTextSize == .automatic
        && style.lockTextAlignment == .center
        && style.islandTextSize == .automatic
        && style.islandTextAlignment == .center
        && style.symbol == "pin.fill"
        && style.symbolAngle == -4500
    }
}
