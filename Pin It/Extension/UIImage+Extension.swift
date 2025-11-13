//
//  UIImage+Extension.swift
//  Pin It
//
//  Created by Ci Zi on 2025/10/29.
//

import UIKit

extension UIImage {
    func resizeImageIfNeeded(maxWidth: CGFloat, maxHeight: CGFloat) -> UIImage {
        let originalSize = self.size
        let originalWidth = originalSize.width
        let originalHeight = originalSize.height
        
        // 如果图片尺寸已经小于等于最大限制，直接返回原图
        if originalWidth <= maxWidth && originalHeight <= maxHeight {
            return self
        }
        
        // 计算缩放比例
        let widthRatio = maxWidth / originalWidth
        let heightRatio = maxHeight / originalHeight
        let scaleFactor = min(widthRatio, heightRatio)
        
        // 计算新的尺寸
        let newWidth: Int = Int(floor(originalWidth * scaleFactor))
        let newHeight: Int = Int(floor(originalHeight * scaleFactor))
        let newSize = CGSize(width: newWidth, height: newHeight)
        
        // 创建图形上下文并绘制缩放后的图片
        UIGraphicsBeginImageContextWithOptions(newSize, false, self.scale)
        self.draw(in: CGRect(origin: .zero, size: newSize))
        let resizedImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        
        return resizedImage ?? self
    }
}

extension UIImage {
    /// 使用变换矩阵旋转图片
    /// - Parameter degrees: 旋转角度
    /// - Returns: 旋转后的图片
    func rotatedByDegrees(_ degrees: Int) -> UIImage? {
        guard let cgImage = self.cgImage else { return nil }
        
        guard degrees != 0 else { return self }
        
        let degrees = degrees % 360
        let radians = CGFloat(degrees) * .pi / 180.0
        
        var transform = CGAffineTransform.identity
        
        switch degrees {
        case 90:
            transform = transform.translatedBy(x: 0, y: -self.size.height)
        case 180:
            transform = transform.translatedBy(x: -self.size.width, y: -self.size.height)
        case 270:
            transform = transform.translatedBy(x: -self.size.width, y: 0)
        default:
            return nil
        }
        
        transform = transform.rotated(by: radians)
        
        let rotatedSize: CGSize
        if degrees == 90 || degrees == 270 {
            rotatedSize = CGSize(width: self.size.height, height: self.size.width)
        } else {
            rotatedSize = self.size
        }
        
        UIGraphicsBeginImageContextWithOptions(rotatedSize, false, self.scale)
        guard let context = UIGraphicsGetCurrentContext() else { return nil }
        
        context.translateBy(x: rotatedSize.width / 2, y: rotatedSize.height / 2)
        context.concatenate(transform)
        context.translateBy(x: -self.size.width / 2, y: -self.size.height / 2)
        
        let rect = CGRect(origin: .zero, size: self.size)
        context.draw(cgImage, in: rect)
        
        let rotatedImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        
        return rotatedImage
    }
}
