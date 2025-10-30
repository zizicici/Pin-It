//
//  AddPostIntent.swift
//  Pin It
//
//  Created by Ci Zi on 2025/10/25.
//

import AppIntents
import UIKit

struct AddTextRecordIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "intent.post.add.by.text.title"
    
    static var description: IntentDescription = IntentDescription("intent.post.add.by.text.description", categoryName: "intent.post.add.category")
    
    @Parameter(title: "intent.text")
    var content: String
    
    static var parameterSummary: some ParameterSummary {
        Summary("intent.post.add.by.text.summary\(\.$content)")
    }
    
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let result = DataManager.shared.createPost(content: content)
        return .result(value: result)
    }
}

struct AddImageRecordIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "intent.post.add.by.image.title"
    
    static var description: IntentDescription = IntentDescription("intent.post.add.by.image.description", categoryName: "intent.post.add.category")
    
    @Parameter(title: "intent.image", supportedContentTypes: [.image])
    var content: IntentFile
    
    static var parameterSummary: some ParameterSummary {
        Summary("intent.post.add.by.image.summary\(\.$content)")
    }
    
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        print(content.data)
        if let image = UIImage(data: content.data) {
            let images = ImageSplitter.splitScreenshotVertically(image).reversed()
            if let original = ImageCacheManager.shared.storeImage(image, type: .original) {
                let processeds: [String] = images.compactMap({ image in
                    let resizedImage = image.resizeImageIfNeeded(maxWidth: 320 * 3, maxHeight: 160 * 3)
                    return ImageCacheManager.shared.storeImage(resizedImage, type: .processed)
                })
                for processed in processeds {
                    _ = DataManager.shared.createPost(original: original, processed: processed, rect: .zero, orientation: 0)
                }
                return .result(value: true)
            } else {
                return .result(value: false)
            }
        } else {
            return .result(value: false)
        }
    }
}
