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
    
    @Parameter(title: "actionLink.title")
    var actionLink: String?
    
    @Parameter(title: "intent.expirationTime")
    var expirationTime: Date?
    
    @Parameter(title: "intent.style.type")
    var style: StyleEntity?
    
    static var parameterSummary: some ParameterSummary {
        Summary("intent.post.add.by.text.summary\(\.$content)") {
            \.$style
            \.$actionLink
            \.$expirationTime
        }
    }
    
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    
    var styleId: Int64? {
        guard let styleId = style?.id else {
            return nil
        }
        return Int64(styleId)
    }
    
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        if let post = DataManager.shared.createPost(content: content, actionLink: actionLink ?? "", expirationTime: expirationTime?.millisecondsSince1970 ?? Post.getDefaultExpirationTime(), styleId: styleId) {
            await SyncCompletionManager.shared.waitForCompletion(postId: post.id!, timeout: 5.0)
            
            if LiveActivityManager.shared.status != .running {
                await LiveActivityManager.shared.restartIfNeeded()
            }
            
            return .result(value: true)
        } else {
            return .result(value: false)
        }
    }
}

public enum DisplayMode: String, AppEnum {
    case full
    case prominentNumber
    case top
    case middle
    case bottom
    
    public static var typeDisplayRepresentation: TypeDisplayRepresentation = "intent.displayMode.type"
    
    public static var caseDisplayRepresentations: [Self : DisplayRepresentation] = [
        .full: "intent.displayMode.case.full",
        .prominentNumber: "intent.displayMode.case.prominentNumber",
        .top: "intent.displayMode.case.top",
        .middle: "intent.displayMode.case.middle",
        .bottom: "intent.displayMode.case.bottom"
    ]
}

@available(iOS 18.0, *)
struct AddImageRecordIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "intent.post.add.by.image.title"
    
    static var description: IntentDescription = IntentDescription("intent.post.add.by.image.description", categoryName: "intent.post.add.category")
    
    @Parameter(title: "intent.displayMode.type", default: DisplayMode.prominentNumber)
    var displayMode: DisplayMode
    
    @Parameter(title: "intent.image", supportedContentTypes: [.image])
    var content: IntentFile
    
    @Parameter(title: "intent.cropEdges", default: true)
    var cropEdges: Bool
    
    @Parameter(title: "actionLink.title")
    var actionLink: String?
    
    @Parameter(title: "intent.expirationTime")
    var expirationTime: Date?
    
    @Parameter(title: "intent.style.type")
    var style: StyleEntity?
    
    var styleId: Int64? {
        guard let styleId = style?.id else {
            return nil
        }
        return Int64(styleId)
    }
    
    static var parameterSummary: some ParameterSummary {
        Switch(\.$displayMode) {
            Case(.prominentNumber) {
                Summary("intent.post.add.by.image.summary\(\.$content)") {
                    \.$displayMode
                    \.$style
                    \.$actionLink
                    \.$expirationTime
                }
            }
            Case(.full) {
                Summary("intent.post.add.by.image.summary\(\.$content)") {
                    \.$displayMode
                    \.$style
                    \.$actionLink
                    \.$expirationTime
                }
            }
            DefaultCase {
                Summary("intent.post.add.by.image.summary\(\.$content)") {
                    \.$displayMode
                    \.$cropEdges
                    \.$style
                    \.$actionLink
                    \.$expirationTime
                }
            }
        }
    }
    
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
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
            if let newImage = newImage?.resizeImageIfNeeded(maxWidth: 320 * 3, maxHeight: 160 * 3),
               let processed = ImageCacheManager.shared.storeImage(newImage, type: .processed),
               let original = ImageCacheManager.shared.storeImage(image, type: .original),
               let post = DataManager.shared.createPost(original: original, processed: processed, rect: imageRect, orientation: 0, actionLink: actionLink ?? "", expirationTime: expirationTime?.millisecondsSince1970 ?? Post.getDefaultExpirationTime(), styleId: styleId) {
                await SyncCompletionManager.shared.waitForCompletion(postId: post.id!, timeout: 5.0)
                
                if LiveActivityManager.shared.status != .running {
                    await LiveActivityManager.shared.restartIfNeeded()
                }
                
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
