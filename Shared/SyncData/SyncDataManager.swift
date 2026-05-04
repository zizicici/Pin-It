//
//  SyncDataManager.swift
//  Pin It
//
//  Created by Ci Zi on 2025/10/25.
//

import Foundation
import MoreKit

extension Notification.Name {
    static let SyncDataUpdated = Notification.Name(rawValue: "com.zizicici.common.syncData.updated")
}

struct SyncPost: Codable, Equatable {
    enum Content: Codable, Equatable {
        case empty
        case text(String)
        case image(String)
    }
    
    var id: Int64
    var content: Content
    var expirationTime: Int64?
    var styleId: Int64
    var defaultStyleId: Int64
    var actionLink: String
    
    func isExpired() -> Bool {
        if let expirationTime = expirationTime {
            return Int(Date().timeIntervalSince1970 * 1000) > expirationTime
        } else {
            return false
        }
    }
}

struct SyncPostStorage: Codable {
    var posts: [SyncPost]
    var styles: [PostStyle]
}

struct SyncAction: Codable {
    enum ActionType: Int, Codable {
        case unpin = 0
    }
    
    var id: Int64
    var actionType: ActionType
}

struct SyncActionStorage: Codable {
    var actions: [SyncAction]
}

// 版本化容器结构体
private struct VersionedContainer<T: Codable>: Codable {
    let version: SyncDataManager.DataVersion
    let data: T
    let modelType: String
}

struct SyncDataManager {
    enum DataVersion: String, Codable {
        case v1 = "1.0.0"
        case v2 = "2.0.0"
    }
    
    private static let appGroupUserDefaults = UserDefaults(suiteName: appGroupId)
    
    // 定义存储键名
    private enum StorageKeys {
        static func dataKey<T>(for type: T.Type) -> String {
            return "data_\(String(describing: type))"
        }
        
        static func versionKey<T>(for type: T.Type) -> String {
            return "version_\(String(describing: type))"
        }
    }
    
    // MARK: - 数据迁移
    private static func migrateIfNeeded<T>(to currentVersion: DataVersion, for type: T.Type) {
        guard let savedVersion = getCurrentVersion(for: type),
              savedVersion != currentVersion else {
            return
        }
        
        print("检测到模型 \(String(describing: type)) 版本变化: \(savedVersion) -> \(currentVersion)")
        
        do {
            try clearData(for: type)
            try saveCurrentVersion(currentVersion, for: type)
            print("模型 \(String(describing: type)) 数据迁移完成")
        } catch {
            print("模型 \(String(describing: type)) 迁移失败: \(error)")
        }
    }
    
    // MARK: - 写入数据
    static func write<T: Codable>(_ data: T, version: DataVersion = .v2) throws {
        guard let userDefaults = appGroupUserDefaults else {
            throw NSError(domain: "SyncDataError", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法访问 App Group UserDefaults"])
        }
        
        // 创建版本化容器
        let container = VersionedContainer(version: version, data: data, modelType: String(describing: T.self))
        
        do {
            let encoder = JSONEncoder()
            let jsonData = try encoder.encode(container)
            
            let dataKey = StorageKeys.dataKey(for: T.self)
            let versionKey = StorageKeys.versionKey(for: T.self)
            
            // 存储数据和版本
            userDefaults.set(jsonData, forKey: dataKey)
            userDefaults.set(version.rawValue, forKey: versionKey)
            
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .SyncDataUpdated, object: nil)
            }
        } catch {
            throw NSError(domain: "SyncDataError", code: -3, userInfo: [
                NSLocalizedDescriptionKey: "数据编码失败: \(error.localizedDescription)"
            ])
        }
    }
    
    // MARK: - 读取数据
    static func read<T: Codable>(_ type: T.Type, currentVersion: DataVersion = .v2) throws -> T? {
        // 检查版本并执行必要的迁移
        migrateIfNeeded(to: currentVersion, for: type)
        
        guard let userDefaults = appGroupUserDefaults else {
            throw NSError(domain: "SyncDataError", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法访问 App Group UserDefaults"])
        }
        
        let dataKey = StorageKeys.dataKey(for: type)
        
        guard let jsonData = userDefaults.data(forKey: dataKey) else {
            return nil
        }
        
        do {
            let decoder = JSONDecoder()
            let container = try decoder.decode(VersionedContainer<T>.self, from: jsonData)
            
            // 验证模型类型是否匹配
            guard container.modelType == String(describing: type) else {
                throw NSError(domain: "SyncDataError", code: -4, userInfo: [NSLocalizedDescriptionKey: "模型类型不匹配"])
            }
            
            return container.data
        } catch {
            // 如果解码失败，清除损坏的数据
            try? clearData(for: type)
            throw NSError(domain: "SyncDataError", code: -5, userInfo: [
                NSLocalizedDescriptionKey: "数据解码失败: \(error.localizedDescription)"
            ])
        }
    }
    
    // MARK: - 版本管理
    private static func getCurrentVersion<T>(for type: T.Type) -> DataVersion? {
        guard let userDefaults = appGroupUserDefaults,
              let versionString = userDefaults.string(forKey: StorageKeys.versionKey(for: type)) else {
            return nil
        }
        return DataVersion(rawValue: versionString)
    }
    
    private static func saveCurrentVersion<T>(_ version: DataVersion, for type: T.Type) throws {
        guard let userDefaults = appGroupUserDefaults else {
            throw NSError(domain: "SyncDataError", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法访问 App Group UserDefaults"])
        }
        
        userDefaults.set(version.rawValue, forKey: StorageKeys.versionKey(for: type))
        userDefaults.synchronize()
    }
    
    // MARK: - 数据管理
    static func clearData<T>(for type: T.Type) throws {
        guard let userDefaults = appGroupUserDefaults else {
            throw NSError(domain: "SyncDataError", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法访问 App Group UserDefaults"])
        }
        
        userDefaults.removeObject(forKey: StorageKeys.dataKey(for: type))
        userDefaults.removeObject(forKey: StorageKeys.versionKey(for: type))
        userDefaults.synchronize()
    }
    
    // 清除所有 SyncDataManager 管理的数据
    static func clearAllData() throws {
        guard let userDefaults = appGroupUserDefaults else {
            throw NSError(domain: "SyncDataError", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法访问 App Group UserDefaults"])
        }
        
        let allKeys = userDefaults.dictionaryRepresentation().keys
        let managedKeys = allKeys.filter { $0.hasPrefix("data_") || $0.hasPrefix("version_") }
        
        for key in managedKeys {
            userDefaults.removeObject(forKey: key)
        }
        userDefaults.synchronize()
    }
    
    // 获取所有存储的模型信息（用于调试）
    static func getAllStoredModels() -> [String: DataVersion?] {
        guard let userDefaults = appGroupUserDefaults else { return [:] }
        
        var models: [String: DataVersion?] = [:]
        let allKeys = userDefaults.dictionaryRepresentation().keys
        
        for key in allKeys where key.hasPrefix("version_") {
            let modelType = key.replacingOccurrences(of: "version_", with: "")
            if let versionString = userDefaults.string(forKey: key) {
                models[modelType] = DataVersion(rawValue: versionString)
            } else {
                models[modelType] = nil
            }
        }
        
        return models
    }
    
    // 调试方法：打印所有存储的数据
    static func debugPrintAllData() {
        guard let userDefaults = appGroupUserDefaults else {
            print("无法访问 App Group UserDefaults")
            return
        }
        
        let models = getAllStoredModels()
        print("=== SyncDataManager 存储数据 ===")
        
        for (modelType, version) in models {
            print("模型: \(modelType), 版本: \(version?.rawValue ?? "无")")
            
            let dataKey = "data_\(modelType)"
            if let data = userDefaults.data(forKey: dataKey) {
                print("数据大小: \(data.count) 字节")
                if let jsonString = String(data: data, encoding: .utf8) {
                    print("数据内容: \(jsonString.prefix(200))...") // 只打印前200个字符
                }
            } else {
                print("无数据")
            }
            print("---")
        }
    }
}

extension SyncDataManager {
    // 便捷方法用于存储和读取特定类型的数据
    static func savePosts(_ posts: SyncPostStorage) throws {
        try write(posts)
    }
    
    static func loadPosts() throws -> SyncPostStorage? {
        return try read(SyncPostStorage.self)
    }
    
    static func saveActions(_ actions: SyncActionStorage) throws {
        try write(actions)
    }
    
    static func loadActions() throws -> SyncActionStorage? {
        return try read(SyncActionStorage.self)
    }
}

extension SyncDataManager {
    static func post(by id: Int64) -> SyncPost? {
        return try? loadPosts()?.posts.first(where: { $0.id == id })
    }
    
    static func style(by postId: Int64?) -> PostStyle? {
        guard let storage = try? loadPosts() else { return nil }
        
        let styleId = storage.posts.first(where: { $0.id == postId })?.styleId ?? Int64(UserDefaults(suiteName: appGroupId)?.getInt(forKey: UserDefaults.Settings.DefaultStyle.rawValue) ?? -1)
        
        return storage.styles.first(where: { $0.id == styleId })
    }
}
