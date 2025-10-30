//
//  ImageSplitter.swift
//  Pin It
//
//  Created by Ci Zi on 2025/10/30.
//

import Foundation
import UIKit

struct ImageSplitter {
    /// 将图片去掉边缘后垂直均分成三份
    /// - Parameters:
    ///   - image: 原始图片
    ///   - edgeInset: 要去掉的边缘大小（可选，默认自动检测）
    /// - Returns: 分割后的三张图片数组 [上, 中, 下]
    static func splitScreenshotVertically(_ image: UIImage, edgeInset: UIEdgeInsets? = nil) -> [UIImage] {
        guard let cgImage = image.cgImage else { return [] }
        
        let originalSize = image.size
        let scale = image.scale
        
        // 计算实际要去掉的边缘
        let insets = edgeInset ?? calculateAutoInsets(for: image)
        
        // 计算裁剪后的区域（去掉边缘）
        let croppedRect = CGRect(
            x: insets.left * scale,
            y: insets.top * scale,
            width: (originalSize.width - insets.left - insets.right) * scale,
            height: (originalSize.height - insets.top - insets.bottom) * scale
        )
        
        // 裁剪图片（去掉边缘）
        guard let croppedCGImage = cgImage.cropping(to: croppedRect) else { return [] }
        let croppedImage = UIImage(cgImage: croppedCGImage, scale: scale, orientation: image.imageOrientation)
        
        // 将裁剪后的图片垂直均分成三份
        return splitIntoThreeVerticalParts(croppedImage)
    }
    
    /// 自动检测并计算需要去掉的边缘
    /// - Parameter image: 原始图片
    /// - Returns: 边缘大小
    private static func calculateAutoInsets(for image: UIImage) -> UIEdgeInsets {
        let size = image.size
        
        // 根据常见的手机屏幕比例自动计算边缘
        let screenRatio = size.width / size.height
        
        switch screenRatio {
        case 0.46...0.47: // iPhone 14 Pro Max 等带灵动岛的设备
            return UIEdgeInsets(top: size.height * 0.08, left: size.width * 0.03, bottom: size.height * 0.08, right: size.width * 0.03)
        case 0.51...0.53: // 传统 iPhone 屏幕
            return UIEdgeInsets(top: size.height * 0.06, left: size.width * 0.02, bottom: size.height * 0.10, right: size.width * 0.02)
        default:
            // 默认去掉边缘（顶部多去一些因为可能有状态栏和刘海）
            return UIEdgeInsets(
                top: size.height * 0.08,    // 顶部多去掉一些（状态栏、刘海等）
                left: size.width * 0.03,
                bottom: size.height * 0.05, // 底部少去掉一些
                right: size.width * 0.03
            )
        }
    }
    
    /// 将图片垂直均分成三份
    /// - Parameter image: 要分割的图片
    /// - Returns: 三张分割后的图片 [上, 中, 下]
    private static func splitIntoThreeVerticalParts(_ image: UIImage) -> [UIImage] {
        guard let cgImage = image.cgImage else { return [] }
        
        let scale = image.scale
        let size = image.size
        let partHeight = size.height / 3
        
        var parts: [UIImage] = []
        
        for i in 0..<1 {
//        for i in 0..<3 {
            let partRect = CGRect(
                x: 0,
                y: CGFloat(i) * partHeight * scale,
                width: size.width * scale,
                height: partHeight * scale
            )
            
            if let partCGImage = cgImage.cropping(to: partRect) {
                let partImage = UIImage(
                    cgImage: partCGImage,
                    scale: scale,
                    orientation: image.imageOrientation
                )
                parts.append(partImage)
            }
        }
        
        return parts
    }
}
