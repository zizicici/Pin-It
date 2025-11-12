//
//  SyncDataManager.swift
//  Pin It
//
//  Created by Ci Zi on 2025/10/25.
//

import Foundation

extension Notification.Name {
    static let SyncDataUpdated = Notification.Name(rawValue: "com.zizicici.common.syncData.updated")
}

struct SyncPost: Codable, Equatable {
    var id: Int64
    var text: String?
    var image: String?
}

struct SyncPostStorage: Codable {
    var posts: [SyncPost]
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

struct SyncDataManager {
    enum DataVersion: String, Codable {
        case v1 = "1.0"
        case v2 = "2.0"
        // 添加新版本
    }
    
    // 每个模型类型独立管理版本
    private struct VersionedContainer<T: Codable>: Codable {
        let version: DataVersion
        let data: T
        let modelType: String  // 记录模型类型，用于验证
    }
    
    // 获取版本文件路径
    private static func versionFileURL<T>(for type: T.Type) -> URL? {
        let fileName = "version_\(String(describing: type)).json"
        return FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupId
        )?.appendingPathComponent(fileName)
    }
    
    // 获取数据文件路径
    private static func dataFileURL<T>(for type: T.Type) -> URL? {
        let fileName = "data_\(String(describing: type)).json"
        return FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupId
        )?.appendingPathComponent(fileName)
    }
    
    // 获取特定模型类型的当前版本
    private static func getCurrentVersion<T>(for type: T.Type) -> DataVersion? {
        guard let versionFileURL = versionFileURL(for: type) else { return nil }
        
        do {
            let data = try Data(contentsOf: versionFileURL)
            return try JSONDecoder().decode(DataVersion.self, from: data)
        } catch {
            return nil
        }
    }
    
    // 保存特定模型类型的版本
    private static func saveCurrentVersion<T>(_ version: DataVersion, for type: T.Type) throws {
        guard let versionFileURL = versionFileURL(for: type) else { return }
        
        let data = try JSONEncoder().encode(version)
        try data.write(to: versionFileURL)
    }
    
    // 为特定模型类型执行数据迁移
    private static func migrateIfNeeded<T: Decodable>(to currentVersion: DataVersion, for type: T.Type) {
        guard let savedVersion = getCurrentVersion(for: type),
              savedVersion != currentVersion else {
            return
        }
        
        print("检测到模型 \(String(describing: type)) 版本变化: \(savedVersion) -> \(currentVersion)")
        
        // 执行迁移逻辑或清除旧数据
        do {
            try clearData(for: type)
            try saveCurrentVersion(currentVersion, for: type)
            print("模型 \(String(describing: type)) 数据迁移完成")
        } catch {
            print("模型 \(String(describing: type)) 迁移失败: \(error)")
        }
    }
    
    // MARK: - 写入数据
    static func write<T: Codable>(_ data: T, version: DataVersion = .v1) throws {
        guard let dataFileURL = dataFileURL(for: T.self) else {
            throw NSError(domain: "SyncDataError", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法访问共享目录"])
        }
        
        let container = VersionedContainer(version: version, data: data, modelType: String(describing: T.self))
        let encoder = JSONEncoder()
        let jsonData = try encoder.encode(container)
        
        let coordinator = NSFileCoordinator()
        var writeError: Error?
        
        coordinator.coordinate(writingItemAt: dataFileURL, options: .forReplacing, error: nil) { (url) in
            do {
                try jsonData.write(to: url, options: .atomic)
                // 同时保存版本信息到独立的版本文件
                try saveCurrentVersion(version, for: T.self)
            } catch {
                writeError = error
            }
        }
        
        if let error = writeError {
            throw error
        } else {
            NotificationCenter.default.post(name: .SyncDataUpdated, object: nil)
        }
    }
    
    // MARK: - 读取数据
    static func read<T: Codable>(_ type: T.Type, currentVersion: DataVersion = .v1) throws -> T? {
        // 检查版本并执行必要的迁移
        migrateIfNeeded(to: currentVersion, for: type)
        
        guard let dataFileURL = dataFileURL(for: type) else {
            throw NSError(domain: "SyncDataError", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法访问共享目录"])
        }
        
        guard FileManager.default.fileExists(atPath: dataFileURL.path) else {
            return nil
        }
        
        let coordinator = NSFileCoordinator()
        var readError: Error?
        var result: T?
        
        coordinator.coordinate(readingItemAt: dataFileURL, options: .withoutChanges, error: nil) { (url) in
            do {
                let data = try Data(contentsOf: url)
                let container = try JSONDecoder().decode(VersionedContainer<T>.self, from: data)
                
                // 验证模型类型是否匹配
                guard container.modelType == String(describing: type) else {
                    throw NSError(domain: "SyncDataError", code: -3, userInfo: [NSLocalizedDescriptionKey: "模型类型不匹配"])
                }
                
                result = container.data
            } catch {
                // 如果解码失败，清除损坏的数据
                readError = error
            }
        }
        
        if let error = readError {
            try? clearData(for: type)
            throw error
        }
        
        return result
    }
    
    // MARK: - 数据管理
    static func clearData<T>(for type: T.Type) throws {
        guard let dataFileURL = dataFileURL(for: type),
              let versionFileURL = versionFileURL(for: type) else { return }
        
        let coordinator = NSFileCoordinator()
        var deleteError: Error?
        
        coordinator.coordinate(writingItemAt: dataFileURL, options: .forDeleting, error: nil) { (url) in
            do {
                // 删除数据文件
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
                
                // 删除版本文件
                if FileManager.default.fileExists(atPath: versionFileURL.path) {
                    try FileManager.default.removeItem(at: versionFileURL)
                }
            } catch {
                deleteError = error
            }
        }
        
        if let error = deleteError {
            throw error
        }
    }
    
    // 获取所有存储的模型信息（用于调试）
    static func getAllStoredModels() -> [String: DataVersion?] {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupId
        ) else { return [:] }
        
        var models: [String: DataVersion?] = [:]
        
        do {
            let files = try FileManager.default.contentsOfDirectory(at: containerURL, includingPropertiesForKeys: nil)
            let versionFiles = files.filter { $0.lastPathComponent.hasPrefix("version_") }
            
            for versionFile in versionFiles {
                let modelType = versionFile.lastPathComponent
                    .replacingOccurrences(of: "version_", with: "")
                    .replacingOccurrences(of: ".json", with: "")
                
                let version = getCurrentVersionFromFile(versionFile)
                models[modelType] = version
            }
        } catch {
            print("获取存储模型信息失败: \(error)")
        }
        
        return models
    }
    
    private static func getCurrentVersionFromFile(_ fileURL: URL) -> DataVersion? {
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode(DataVersion.self, from: data)
        } catch {
            return nil
        }
    }
}
