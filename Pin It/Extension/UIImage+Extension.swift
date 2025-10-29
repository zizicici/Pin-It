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
        let newWidth = originalWidth * scaleFactor
        let newHeight = originalHeight * scaleFactor
        let newSize = CGSize(width: newWidth, height: newHeight)
        
        // 创建图形上下文并绘制缩放后的图片
        UIGraphicsBeginImageContextWithOptions(newSize, false, self.scale)
        self.draw(in: CGRect(origin: .zero, size: newSize))
        let resizedImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        
        return resizedImage ?? self
    }
}
