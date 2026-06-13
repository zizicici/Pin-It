//
//  ProBadge.swift
//  Pin It
//
//  A small inline "PRO" badge for marking Pro-gated rows in a table.
//
//  MoreKit's own `MoreCustomBadgeCell` renders a `MoreBadgeStyle` inline in a
//  cell title, but that cell is internal to the package. So we reuse the public
//  `MoreBadgeStyle` and mirror that cell's inline-attachment rendering here.
//

import UIKit
import MoreKit

enum ProBadge {
    static let style = MoreBadgeStyle(
        text: "PRO",
        textColor: .white,
        backgroundColor: .systemRed,
        font: .systemFont(ofSize: 10, weight: .bold),
        cornerRadius: 4,
        contentInsets: UIEdgeInsets(top: 2, left: 5, bottom: 2, right: 5)
    )

    /// `title` followed by an inline PRO badge, sized relative to `font`.
    static func attributedTitle(
        _ title: String,
        font: UIFont,
        color: UIColor,
        traitCollection: UITraitCollection
    ) -> NSAttributedString {
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        let result = NSMutableAttributedString(string: title, attributes: titleAttributes)
        result.append(NSAttributedString(string: " ", attributes: titleAttributes))

        let attachment = NSTextAttachment()
        let image = badgeImage(traitCollection: traitCollection)
        let yOffset = round((font.capHeight - image.size.height) / 2)
        attachment.image = image
        attachment.bounds = CGRect(origin: CGPoint(x: 0, y: yOffset), size: image.size)
        result.append(NSAttributedString(attachment: attachment))
        return result
    }

    private static func badgeImage(traitCollection: UITraitCollection) -> UIImage {
        let metrics = UIFontMetrics(forTextStyle: .caption2)
        let font = metrics.scaledFont(for: style.font, compatibleWith: traitCollection)
        let insets = UIEdgeInsets(
            top: metrics.scaledValue(for: style.contentInsets.top, compatibleWith: traitCollection),
            left: metrics.scaledValue(for: style.contentInsets.left, compatibleWith: traitCollection),
            bottom: metrics.scaledValue(for: style.contentInsets.bottom, compatibleWith: traitCollection),
            right: metrics.scaledValue(for: style.contentInsets.right, compatibleWith: traitCollection)
        )
        let cornerRadius = metrics.scaledValue(for: style.cornerRadius, compatibleWith: traitCollection)

        let text = style.text as NSString
        let textAttributes: [NSAttributedString.Key: Any] = [.font: font]
        let textSize = text.size(withAttributes: textAttributes)
        let size = CGSize(
            width: ceil(textSize.width + insets.left + insets.right),
            height: ceil(textSize.height + insets.top + insets.bottom)
        )

        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : UIScreen.main.scale

        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let backgroundColor = style.backgroundColor.resolvedColor(with: traitCollection)
        let textColor = style.textColor.resolvedColor(with: traitCollection)

        return renderer.image { _ in
            let rect = CGRect(origin: .zero, size: size)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: min(cornerRadius, size.height / 2))
            backgroundColor.setFill()
            path.fill()

            let textRect = CGRect(
                x: insets.left,
                y: insets.top,
                width: ceil(textSize.width),
                height: ceil(textSize.height)
            )
            text.draw(in: textRect, withAttributes: [.font: font, .foregroundColor: textColor])
        }
    }
}
