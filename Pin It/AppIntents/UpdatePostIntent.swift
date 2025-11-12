//
//  UpdatePostIntent.swift
//  Pin It
//
//  Created by Ci Zi on 2025/11/11.
//

import AppIntents
import UIKit

struct UpdatePostTextIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "intent.post.update.text.title"
    
    static var description: IntentDescription = IntentDescription("intent.post.update.text.title", categoryName: "intent.post.update.category")
    
    static var parameterSummary: some ParameterSummary {
        Summary("intent.post.update.text.summary\(\.$post)\(\.$content)")
    }
    
    @Parameter(title: "intent.post.type")
    var post: PostEntity
    
    @Parameter(title: "intent.text")
    var content: String
    
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        guard let post = DataManager.shared.fetchPostDetail(for: [Int64(post.id)]).first?.post, let postId = post.id else {
            return .result(value: false)
        }
        
        let result = DataManager.shared.updateText(content: content, to: post)
        await SyncCompletionManager.shared.waitForCompletion(postId: postId, timeout: 5.0)
        
        return .result(value: result)
    }
}

@available(iOS 18.0, *)
struct UpdatePostImageIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "intent.post.update.image.title"
    
    static var description: IntentDescription = IntentDescription("intent.post.update.image.title", categoryName: "intent.post.update.category")
    
    @Parameter(title: "intent.post.type")
    var post: PostEntity
    
    @Parameter(title: "intent.displayMode.type", default: DisplayMode.prominentNumber)
    var displayMode: DisplayMode
    
    @Parameter(title: "intent.image", supportedContentTypes: [.image])
    var content: IntentFile
    
    @Parameter(title: "intent.cropEdges", default: true)
    var cropEdges: Bool
    
    static var parameterSummary: some ParameterSummary {
        Switch(\.$displayMode) {
            Case(.prominentNumber) {
                Summary("intent.post.update.image.summary\(\.$post)\(\.$content)") {
                    \.$displayMode
                }
            }
            Case(.full) {
                Summary("intent.post.update.image.summary\(\.$post)\(\.$content)") {
                    \.$displayMode
                }
            }
            DefaultCase {
                Summary("intent.post.update.image.summary\(\.$post)\(\.$content)") {
                    \.$displayMode
                    \.$cropEdges
                }
            }
        }
    }
    
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        guard let post = DataManager.shared.fetchPostDetail(for: [Int64(post.id)]).first?.post, let postId = post.id else {
            return .result(value: false)
        }
        
        if let image = UIImage(data: content.data) {
            var newImage: UIImage? = nil
            var imageRect: CGRect = CGRect(origin: .zero, size: image.size)
            switch displayMode {
            case .full:
                newImage = image
            case .prominentNumber:
                if let largestNumberInfo = try? TextRecognitionHelper.findLargestNumber(in: image), let rect = largestNumberInfo.largestNumberRect {
                    imageRect = expandRect(rect, by: .init(width: rect.width / 3, height: rect.height / 3), within: CGRect(origin: .zero, size: image.size))
                    newImage = ImageCropper.cropImage(image, to: imageRect)
                } else {
                    newImage = image
                }
            case .top:
                if let result = ImageCropper.cropImage(image, to: .top, cropEdges: cropEdges) {
                    newImage = result.0
                    imageRect = result.1
                }
            case .middle:
                if let result = ImageCropper.cropImage(image, to: .middle, cropEdges: cropEdges) {
                    newImage = result.0
                    imageRect = result.1
                }
            case .bottom:
                if let result = ImageCropper.cropImage(image, to: .bottom, cropEdges: cropEdges) {
                    newImage = result.0
                    imageRect = result.1
                }
            }
            if let newImage = newImage?.resizeImageIfNeeded(maxWidth: 320 * 3, maxHeight: 160 * 3), let processed = ImageCacheManager.shared.storeImage(newImage, type: .processed), let original = ImageCacheManager.shared.storeImage(image, type: .original) {
                _ = DataManager.shared.updateImage(original: original, processed: processed, rect: imageRect, orientation: 0, to: post)
                await SyncCompletionManager.shared.waitForCompletion(postId: postId, timeout: 5.0)
                
                return .result(value: true)
            } else {
                return .result(value: false)
            }
        } else {
            return .result(value: false)
        }
    }
    
    func expandRect(_ rect: CGRect, by edges: CGSize, within bounds: CGRect) -> CGRect {
        var expandedRect = rect
        
        let maxLeftExpansion = rect.minX - bounds.minX
        let maxRightExpansion = bounds.maxX - rect.maxX
        let maxTopExpansion = rect.minY - bounds.minY
        let maxBottomExpansion = bounds.maxY - rect.maxY
        
        let actualLeftExpansion = min(edges.width, maxLeftExpansion)
        let actualRightExpansion = min(edges.width, maxRightExpansion)
        let actualTopExpansion = min(edges.height, maxTopExpansion)
        let actualBottomExpansion = min(edges.height, maxBottomExpansion)
        
        expandedRect.origin.x -= actualLeftExpansion
        expandedRect.origin.y -= actualTopExpansion
        expandedRect.size.width += actualLeftExpansion + actualRightExpansion
        expandedRect.size.height += actualTopExpansion + actualBottomExpansion
        
        return expandedRect
    }
}

struct UpdatePinStateIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "intent.post.update.pinState.title"
    
    static var description: IntentDescription = IntentDescription("intent.post.update.pinState.title", categoryName: "intent.post.update.category")
    
    static var parameterSummary: some ParameterSummary {
        Summary("intent.post.update.pinState.summary\(\.$post)\(\.$isPinned)")
    }
    
    @Parameter(title: "intent.post.type")
    var post: PostEntity
    
    @Parameter(title: "intent.post.isPinnedValue")
    var isPinned: Bool
    
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        guard let detail = DataManager.shared.fetchPostDetail(for: [Int64(post.id)]).first else {
            return .result(value: false)
        }
        
        let result = DataManager.shared.update(post: detail.post, isPinned: isPinned)
        await SyncCompletionManager.shared.waitForCompletion(postId: Int64(post.id), timeout: 5.0)
        
        return .result(value: result)
    }
}
