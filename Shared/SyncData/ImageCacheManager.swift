//
//  ImageCacheManager.swift
//  Pin It
//
//  Created by Ci Zi on 2025/10/29.
//

import Foundation
import UIKit

// 缓存类型枚举
enum CacheImageType {
    case original   // 原图
    case processed  // 处理过的图片
}

// 图片缓存管理器
class ImageCacheManager {
    
    // 单例实例
    static let shared = ImageCacheManager()
    
    // 文件夹名称
    private let cacheFolderName = "image_cache"
    private let originalFolderName = "original"
    private let processedFolderName = "processed"
    
    // 文件管理器
    private let fileManager = FileManager.default
    
    // 当前文件序号
    private var currentFileIndex: UInt32 = 0
    private let indexLock = NSLock() // 用于线程安全
    
    // 容器 URL
    private var containerURL: URL? {
        return fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupId)
    }
    
    private init() {
        setupCacheDirectories()
        loadCurrentFileIndex()
    }
    
    // 设置缓存目录
    private func setupCacheDirectories() {
        guard let containerURL = containerURL else {
            print("Error: Unable to get container URL")
            return
        }
        
        let cacheURL = containerURL.appendingPathComponent(cacheFolderName)
        let originURL = cacheURL.appendingPathComponent(originalFolderName)
        let processedURL = cacheURL.appendingPathComponent(processedFolderName)
        
        // 创建目录
        createDirectoryIfNeeded(at: cacheURL)
        createDirectoryIfNeeded(at: originURL)
        createDirectoryIfNeeded(at: processedURL)
    }
    
    // 创建目录（如果不存在）
    private func createDirectoryIfNeeded(at url: URL) {
        guard !fileManager.fileExists(atPath: url.path) else { return }
        
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
            print("Created directory: \(url.path)")
        } catch {
            print("Error creating directory at \(url.path): \(error)")
        }
    }
    
    // 加载当前文件序号
    private func loadCurrentFileIndex() {
        guard let containerURL = containerURL else { return }
        
        let indexFileURL = containerURL.appendingPathComponent(cacheFolderName).appendingPathComponent("current_index")
        
        if let indexData = try? Data(contentsOf: indexFileURL),
           let indexString = String(data: indexData, encoding: .utf8),
           let index = UInt32(indexString) {
            currentFileIndex = index
        } else {
            currentFileIndex = 0
        }
    }
    
    // 保存当前文件序号
    private func saveCurrentFileIndex() {
        guard let containerURL = containerURL else { return }
        
        let indexFileURL = containerURL.appendingPathComponent(cacheFolderName).appendingPathComponent("current_index")
        let indexString = String(currentFileIndex)
        
        do {
            try indexString.data(using: .utf8)?.write(to: indexFileURL)
        } catch {
            print("Error saving current index: \(error)")
        }
    }
    
    // 获取下一个文件名
    private func getNextFileName() -> String {
        indexLock.lock()
        defer {
            saveCurrentFileIndex()
            indexLock.unlock()
        }
        
        let fileName = String(format: "%08d", currentFileIndex)
        currentFileIndex += 1
        return fileName
    }
    
    // 获取文件夹 URL
    private func getFolderURL(for type: CacheImageType) -> URL? {
        guard let containerURL = containerURL else { return nil }
        
        let cacheURL = containerURL.appendingPathComponent(cacheFolderName)
        
        switch type {
        case .original:
            return cacheURL.appendingPathComponent(originalFolderName)
        case .processed:
            return cacheURL.appendingPathComponent(processedFolderName)
        }
    }
    
    // 存储图片
    func storeImage(_ image: UIImage, type: CacheImageType) -> String? {
        guard let folderURL = getFolderURL(for: type) else {
            print("Error: Unable to get folder URL for type \(type)")
            return nil
        }
        
        let fileName = getNextFileName()
        let fileURL = folderURL.appendingPathComponent(fileName)
        
        // 将 UIImage 转换为 Data
        guard let imageData = image.heicData() else {
            print("Error: Unable to convert UIImage to HEIC data")
            return nil
        }
        
        do {
            try imageData.write(to: fileURL)
            print("Successfully stored image at: \(fileURL.path)")
            return fileName
        } catch {
            print("Error storing image: \(error)")
            return nil
        }
    }
    
    // 根据文件名和类型读取图片
    func retrieveImage(fileName: String, type: CacheImageType) -> UIImage? {
        guard let folderURL = getFolderURL(for: type) else { return nil }
        
        let fileURL = folderURL.appendingPathComponent(fileName)
        
        guard fileManager.fileExists(atPath: fileURL.path) else {
            print("File does not exist at: \(fileURL.path)")
            return nil
        }
        
        do {
            let imageData = try Data(contentsOf: fileURL)
            return UIImage(data: imageData)
        } catch {
            print("Error retrieving image: \(error)")
            return nil
        }
    }
    
    // 根据文件名和类型删除图片
    func deleteImage(fileName: String, type: CacheImageType) -> Bool {
        guard let folderURL = getFolderURL(for: type) else { return false }
        
        let fileURL = folderURL.appendingPathComponent(fileName)
        
        guard fileManager.fileExists(atPath: fileURL.path) else {
            print("File does not exist at: \(fileURL.path)")
            return false
        }
        
        do {
            try fileManager.removeItem(at: fileURL)
            return true
        } catch {
            print("Error deleting image: \(error)")
            return false
        }
    }
    
    // 获取缓存信息
    func getCacheInfo() -> (originCount: Int, processedCount: Int, totalSize: Int64) {
        guard let originalURL = getFolderURL(for: .original),
              let processedURL = getFolderURL(for: .processed) else {
            return (0, 0, 0)
        }
        
        let originCount = getFileCount(in: originalURL)
        let processedCount = getFileCount(in: processedURL)
        let totalSize = getFolderSize(originalURL) + getFolderSize(processedURL)
        
        return (originCount, processedCount, totalSize)
    }
    
    // 获取文件夹中的文件数量
    private func getFileCount(in directory: URL) -> Int {
        do {
            let contents = try fileManager.contentsOfDirectory(atPath: directory.path)
            return contents.count
        } catch {
            return 0
        }
    }
    
    // 获取文件夹大小
    private func getFolderSize(_ directory: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        
        var totalSize: Int64 = 0
        for case let fileURL as URL in enumerator {
            do {
                let resourceValues = try fileURL.resourceValues(forKeys: [.fileSizeKey])
                totalSize += Int64(resourceValues.fileSize ?? 0)
            } catch {
                continue
            }
        }
        return totalSize
    }
    
    // 清空所有缓存
    func clearAllCache() {
        guard let containerURL = containerURL else { return }
        
        let cacheURL = containerURL.appendingPathComponent(cacheFolderName)
        
        do {
            if fileManager.fileExists(atPath: cacheURL.path) {
                try fileManager.removeItem(at: cacheURL)
                setupCacheDirectories()
                currentFileIndex = 0
                saveCurrentFileIndex()
                print("All cache cleared")
            }
        } catch {
            print("Error clearing cache: \(error)")
        }
    }
}
