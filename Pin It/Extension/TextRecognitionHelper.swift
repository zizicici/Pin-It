//
//  TextRecognitionHelper.swift
//  Pin It
//
//  Created by Ci Zi on 2025/10/30.
//

import UIKit
import Vision

class TextRecognitionHelper {
    
    /// 识别图片中最大的数字 (同步版本)
    /// - Parameter image: 输入的UIImage
    /// - Returns: 包含最大数字、位置和所有识别文字的元组
    static func findLargestNumber(in image: UIImage) throws -> (largestNumber: String?,
                                                               largestNumberRect: CGRect?,
                                                               allNumbers: [RecognizedText]?) {
        
        guard let cgImage = image.cgImage else {
            throw TextRecognitionError.invalidImage
        }
        
        // 创建文字识别请求
        let request = VNRecognizeTextRequest()
        
        // 配置识别参数
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        request.minimumTextHeight = 30.0
        
        var recognitionLanguages: [String] = ["en-US"]
        let currentCode = Locale.current.language.languageCode?.identifier ?? "en-US"
        if !recognitionLanguages.contains(where: { $0 == currentCode }) {
            recognitionLanguages.append(currentCode)
        }
        request.recognitionLanguages = recognitionLanguages
        
        // 执行识别请求
        let requests = [request]
        let imageRequestHandler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        
        do {
            try imageRequestHandler.perform(requests)
            
            guard let observations = request.results else {
                return (nil, nil, nil)
            }
            
            let result = processRecognitionResults(observations, imageSize: image.size)
            return result
            
        } catch {
            throw error
        }
    }
    
    /// 处理识别结果 - 改进版本：使用字符宽度估算字号
    private static func processRecognitionResults(_ observations: [VNRecognizedTextObservation], imageSize: CGSize) -> (String?, CGRect?, [RecognizedText]?) {
        
        var allNumbers: [RecognizedText] = []
        var largestNumber: String?
        var largestNumberRect: CGRect?
        var largestFontSize: CGFloat = 0
        
        for observation in observations {
            guard let topCandidate = observation.topCandidates(1).first else { continue }
            
            let recognizedText = topCandidate.string
            
            // 获取文本中所有数字的精确位置
            let numbersWithRects = extractNumbersWithRects(
                from: recognizedText,
                observation: observation,
                imageSize: imageSize
            )
            
            for (number, numberRect) in numbersWithRects {
                // 使用字符平均宽度来估算字号（更准确）
                let characterCount = CGFloat(number.count)
                let totalWidth = numberRect.width
                let averageCharWidth = characterCount > 0 ? totalWidth / characterCount : 0
                
                // 字符宽度与字号的比例关系（经验值，可根据实际情况调整）
                // 通常字符宽度约为字号的 0.6-0.8 倍，这里取 0.7 作为估算系数
                let estimatedFontSize = averageCharWidth / 0.7
                
                let numberItem = RecognizedText(
                    text: number,
                    boundingBox: numberRect,
                    confidence: topCandidate.confidence,
                    estimatedFontSize: estimatedFontSize
                )
                
                allNumbers.append(numberItem)
                
                print("发现数字: \(number), 字符宽度估算字号: \(estimatedFontSize), 位置: \(numberRect)")
                
                // 比较字号大小
                if estimatedFontSize > largestFontSize {
                    largestFontSize = estimatedFontSize
                    largestNumber = number
                    largestNumberRect = numberRect
                }
            }
        }
        
        // 按字号大小排序所有识别到的数字
        allNumbers.sort { $0.estimatedFontSize > $1.estimatedFontSize }
        
        return (largestNumber, largestNumberRect, allNumbers)
    }
    
    /// 从文本中提取数字及其精确位置
    private static func extractNumbersWithRects(from text: String, observation: VNRecognizedTextObservation, imageSize: CGSize) -> [(String, CGRect)] {
        var results: [(String, CGRect)] = []
        
        // 使用正则表达式匹配数字（包括整数和小数）
        let pattern = #"-?\d+(\.\d+)?"#
        
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return results
        }
        
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: range)
        
        for match in matches {
            guard let matchRange = Range(match.range, in: text) else { continue }
            
            let number = String(text[matchRange])
            
            // 获取数字在文本中的精确位置
            if let numberRect = getExactBoundingBoxForRange(
                match.range,
                in: text,
                observation: observation,
                imageSize: imageSize
            ) {
                results.append((number, numberRect))
            }
        }
        
        return results
    }

    /// 获取文本中特定范围的精确边界框
    private static func getExactBoundingBoxForRange(_ range: NSRange, in text: String, observation: VNRecognizedTextObservation, imageSize: CGSize) -> CGRect? {
        
        // 获取整个文本的边界框
        let fullBoundingBox = observation.boundingBox
        let fullText = text as NSString
        
        // 计算字符宽度比例（近似）
        let prefixText = fullText.substring(to: range.location)
        let numberText = fullText.substring(with: range)
        
        // 估算字符宽度（基于字符数量）
        let totalLength = fullText.length
        let prefixLength = prefixText.count
        let numberLength = numberText.count
        
        guard totalLength > 0 else { return nil }
        
        // 计算数字在文本中的相对位置和宽度
        let prefixRatio = CGFloat(prefixLength) / CGFloat(totalLength)
        let numberRatio = CGFloat(numberLength) / CGFloat(totalLength)
        
        // 计算数字的精确边界框
        let numberBoundingBox = CGRect(
            x: fullBoundingBox.origin.x + prefixRatio * fullBoundingBox.width,
            y: fullBoundingBox.origin.y,
            width: numberRatio * fullBoundingBox.width,
            height: fullBoundingBox.height
        )
        
        // 转换坐标系
        return convertBoundingBox(numberBoundingBox, imageSize: imageSize)
    }
    
    /// 更精确的字符级别位置识别（使用 Vision 的字符级识别）
    private static func getCharacterLevelBoundingBox(for range: NSRange, in observation: VNRecognizedTextObservation, imageSize: CGSize) -> CGRect? {
        
        // 尝试获取字符级别的边界框
        guard #available(iOS 13.0, *) else {
            // 回退到基于字符比例的估算方法
            return nil
        }
        
        // 使用字符级识别获取更精确的位置
        let candidate = observation.topCandidates(1).first
        
        // Vision 框架在 iOS 13+ 支持字符级边界框
        do {
            // 将 NSRange 转换为 Range<String.Index>
            let fullText = candidate?.string ?? ""
            guard let stringRange = Range(range, in: fullText) else {
                return nil
            }
            
            // 尝试获取指定范围的边界框
            let boundingBox = try candidate?.boundingBox(for: stringRange)?.boundingBox
            
            if let preciseBoundingBox = boundingBox {
                return convertBoundingBox(preciseBoundingBox, imageSize: imageSize)
            }
        } catch {
            print("字符级边界框获取失败: \(error)")
        }
        
        // 如果字符级识别失败，回退到基于比例的估算
        return nil
    }
    
    /// 转换边界框坐标系
    private static func convertBoundingBox(_ boundingBox: CGRect, imageSize: CGSize) -> CGRect {
        let origin = CGPoint(
            x: boundingBox.origin.x * imageSize.width,
            y: (1 - boundingBox.origin.y - boundingBox.height) * imageSize.height
        )
        let size = CGSize(
            width: boundingBox.width * imageSize.width,
            height: boundingBox.height * imageSize.height
        )
        
        return CGRect(origin: origin, size: size)
    }
    
    /// 批量识别多张图片中最大的数字 (同步版本)
    static func findLargestNumbers(in images: [UIImage]) -> [ImageRecognitionResult] {
        var results: [ImageRecognitionResult] = []
        
        for (index, image) in images.enumerated() {
            do {
                let result = try findLargestNumber(in: image)
                let recognitionResult = ImageRecognitionResult(
                    imageIndex: index,
                    largestNumber: result.largestNumber,
                    largestNumberRect: result.largestNumberRect,
                    allNumbers: result.allNumbers,
                    error: nil
                )
                results.append(recognitionResult)
            } catch {
                let recognitionResult = ImageRecognitionResult(
                    imageIndex: index,
                    largestNumber: nil,
                    largestNumberRect: nil,
                    allNumbers: nil,
                    error: error
                )
                results.append(recognitionResult)
            }
        }
        
        return results
    }
}

/// 识别到的文字信息结构体
struct RecognizedText {
    let text: String
    let boundingBox: CGRect
    let confidence: Float
    let estimatedFontSize: CGFloat
}

/// 图片识别结果结构体
struct ImageRecognitionResult {
    let imageIndex: Int
    let largestNumber: String?
    let largestNumberRect: CGRect?
    let allNumbers: [RecognizedText]?
    let error: Error?
}

/// 自定义错误类型
enum TextRecognitionError: Error {
    case invalidImage
    case recognitionFailed
    case noTextFound
}
