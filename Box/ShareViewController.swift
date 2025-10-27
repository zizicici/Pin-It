//
//  ShareViewController.swift
//  Box
//
//  Created by Ci Zi on 2025/10/13.
//

import UIKit
import UniformTypeIdentifiers
import os.log

class BoxViewController: UIViewController {
    var context: NSExtensionContext?
    private var isViewAppeared = false
    private var isFileProcessingComplete = false
    private var shouldCompleteRequest = false {
        didSet {
            tryCompleteRequest()
        }
    }

    override func beginRequest(with context: NSExtensionContext) {
        logger.log(#function)
        self.context = context
        
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else {
            return
        }
        
        // 1. 创建并管理 inbox 目录
        let inboxURL = containerURL.appendingPathComponent("inbox")
        
        // 确保 inbox 目录存在
        do {
            try FileManager.default.createDirectory(at: inboxURL, withIntermediateDirectories: true)
        } catch {
            logger.log("Failed to create inbox directory: \(error)")
            return
        }
        
        // 清理 inbox 目录中的现有文件
        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: inboxURL,
                includingPropertiesForKeys: nil,
                options: .skipsHiddenFiles
            )
            for file in files {
                try FileManager.default.removeItem(at: file)
            }
            logger.log("Cleaned up \(files.count) files from inbox")
        } catch {
            logger.log("Failed to clean up inbox: \(error)")
            // 继续执行，不返回
        }
        
        var index = 0
        let dispatchGroup = DispatchGroup()
        
        for item in context.inputItems {
            if let extensionItem = item as? NSExtensionItem {
                // 处理附件
                for provider in extensionItem.attachments ?? [] {
                    index += 1
                    let closureIndex = index
                    
                    // 检查是否是文本类型
                    if provider.hasItemConformingToTypeIdentifier("public.plain-text") {
                        dispatchGroup.enter()
                        provider.loadItem(forTypeIdentifier: "public.plain-text") { item, error in
                            defer { dispatchGroup.leave() }
                            
                            if let text = item as? String {
                                logger.log("\(text)")
                                let fileName = "\(String(format: "%03d", closureIndex))_text"
                                let fileURL = inboxURL.appendingPathComponent(fileName)
                                
                                do {
                                    try text.write(to: fileURL, atomically: true, encoding: .utf8)
                                    logger.log("Saved text attachment to \(fileName)")
                                } catch {
                                    logger.log("Failed to save text attachment: \(error)")
                                }
                            }
                        }
                    } else if provider.hasItemConformingToTypeIdentifier("public.image") {
                        dispatchGroup.enter()
                        _ = provider.loadDataRepresentation(for: .image) { data, error in
                            defer { dispatchGroup.leave() }
                            
                            if let data = data {
                                let fileName = "\(String(format: "%03d", closureIndex))_image"
                                let fileURL = inboxURL.appendingPathComponent(fileName)
                                
                                do {
                                    try data.write(to: fileURL)
                                    logger.log("Saved image to \(fileName)")
                                } catch {
                                    logger.log("Failed to save image: \(error)")
                                }
                            }
                        }
                    } else {
                        // 不支持的附件类型，直接继续
                        continue
                    }
                }
            }
        }
        
        // 所有异步操作完成后执行
        dispatchGroup.notify(queue: .main) {
            logger.log("Processed \(index) files")
            self.isFileProcessingComplete = true
            self.shouldCompleteRequest = true
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        logger.log(#function)
        isViewAppeared = true
        shouldCompleteRequest = true
    }

    private func tryCompleteRequest() {
        // 只有当视图已出现且文件处理完成时才执行完成操作
        guard isViewAppeared && isFileProcessingComplete && shouldCompleteRequest else {
            return
        }
        
        // 防止重复调用
        shouldCompleteRequest = false
        
        logger.log("Completing request and opening app")
        context?.completeRequest(returningItems: nil) { [weak self] _ in
            self?.openURL(URL(string: "openbox:"))
        }
    }

    func openURL(_ url: URL?) {
        guard let url else { return }
        logger.log(#function)
        var responder: UIResponder? = self
        while responder != nil {
            if let application = responder as? UIApplication {
                application.open(url, options: [:], completionHandler: nil)
                return
            }
            responder = responder?.next
        }
    }
}
