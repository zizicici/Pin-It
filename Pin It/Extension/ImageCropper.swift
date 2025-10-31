//
//  ImageCropper.swift
//  Pin It
//
//  Created by Ci Zi on 2025/10/30.
//

import UIKit

enum CropPosition {
    case top
    case middle
    case bottom
}

class ImageCropper {
    
    /// 直接根据指定的矩形区域裁切图片
    /// - Parameters:
    ///   - image: 原始图片
    ///   - rect: 裁切区域（相对于图片坐标系）
    /// - Returns: 裁切后的图片
    static func cropImage(_ image: UIImage, to rect: CGRect) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        
        let scale = image.scale
        let scaledRect = CGRect(
            x: rect.origin.x * scale,
            y: rect.origin.y * scale,
            width: rect.width * scale,
            height: rect.height * scale
        )
        
        guard let croppedCGImage = cgImage.cropping(to: scaledRect) else { return nil }
        return UIImage(cgImage: croppedCGImage, scale: scale, orientation: image.imageOrientation)
    }
    
    /// 根据指定位置裁切图片的三分之一部分
    /// - Parameters:
    ///   - image: 原始图片
    ///   - position: 裁切位置（顶部、中间、底部）
    ///   - cropEdges: 是否裁切边缘
    /// - Returns: 裁切后的图片
    static func cropImage(_ image: UIImage, to position: CropPosition, cropEdges: Bool) -> UIImage? {
        let imageSize = image.size
        
        // 计算裁切区域（一次性计算，避免多次裁切）
        let cropRect: CGRect = {
            if cropEdges {
                // 裁切边缘：上下左右各裁切5%
                let edgeInsetX = imageSize.width * 0.05
                let edgeInsetY = imageSize.height * 0.05
                let insetRect = CGRect(
                    x: edgeInsetX,
                    y: edgeInsetY,
                    width: imageSize.width - edgeInsetX * 2,
                    height: imageSize.height - edgeInsetY * 2
                )
                
                // 在裁切边缘后的区域内计算三分之一部分
                let thirdHeight = insetRect.height / 3
                switch position {
                case .top:
                    return CGRect(
                        x: insetRect.origin.x,
                        y: insetRect.origin.y,
                        width: insetRect.width,
                        height: thirdHeight
                    )
                case .middle:
                    return CGRect(
                        x: insetRect.origin.x,
                        y: insetRect.origin.y + thirdHeight,
                        width: insetRect.width,
                        height: thirdHeight
                    )
                case .bottom:
                    return CGRect(
                        x: insetRect.origin.x,
                        y: insetRect.origin.y + thirdHeight * 2,
                        width: insetRect.width,
                        height: thirdHeight
                    )
                }
            } else {
                // 不裁切边缘，直接在原图上计算三分之一部分
                let thirdHeight = imageSize.height / 3
                switch position {
                case .top:
                    return CGRect(x: 0, y: 0, width: imageSize.width, height: thirdHeight)
                case .middle:
                    return CGRect(x: 0, y: thirdHeight, width: imageSize.width, height: thirdHeight)
                case .bottom:
                    return CGRect(x: 0, y: thirdHeight * 2, width: imageSize.width, height: thirdHeight)
                }
            }
        }()
        
        return cropImage(image, to: cropRect)
    }
}
