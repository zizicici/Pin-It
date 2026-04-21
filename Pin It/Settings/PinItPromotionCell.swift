//
//  PinItPromotionCell.swift
//  Pin It
//
//  Created by Ci Zi on 2025/7/6.
//

import UIKit
import SnapKit
import MoreKit

class PinItPromotionCell: UITableViewCell, PromotionCellConfigurable {
    var purchaseClosure: (() -> ())?
    var restoreClosure: (() -> ())?

    private var priceText: String = "?.??"

    private let gradientView = GradientView()

    private var topLabel: UILabel = {
        let label = UILabel()
        label.font = UIFont.preferredFont(forTextStyle: .headline)
        label.textAlignment = .natural
        label.textColor = .white
        label.numberOfLines = 1
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.5
        return label
    }()

    private let featureStackView: UIStackView = {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 8
        stack.alignment = .leading
        return stack
    }()

    private var purchaseButton: UIButton!
    private var restoreButton: UIButton!

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)

        setupPurchaseButton()
        setupRestoreButton()

        contentView.addSubview(gradientView)
        gradientView.snp.makeConstraints { make in
            make.edges.equalTo(contentView)
        }

        contentView.addSubview(purchaseButton)
        contentView.addSubview(restoreButton)
        contentView.addSubview(topLabel)
        contentView.addSubview(featureStackView)

        switch Language.type() {
        case .zh, .ja, .ko:
            setupCJKLayout()
        default:
            setupDefaultLayout()
        }

        let view = UIView()
        selectedBackgroundView = view
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - CJK Layout (button right, text left)

    private func setupCJKLayout() {
        purchaseButton.snp.makeConstraints { make in
            make.top.equalTo(contentView).inset(20.0)
            make.trailing.equalTo(contentView).inset(20.0)
            make.height.greaterThanOrEqualTo(40.0)
        }

        restoreButton.snp.makeConstraints { make in
            make.bottom.equalTo(contentView).inset(20)
            make.trailing.lessThanOrEqualTo(contentView).inset(18)
            make.centerX.equalTo(purchaseButton).priority(.medium)
            make.top.greaterThanOrEqualTo(purchaseButton.snp.bottom).offset(10)
        }
        restoreButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        topLabel.snp.makeConstraints { make in
            make.top.equalTo(contentView).inset(20)
            make.leading.equalTo(contentView).inset(20)
            make.trailing.equalTo(purchaseButton.snp.leading).offset(-10)
        }
        topLabel.setContentHuggingPriority(.defaultLow, for: .vertical)

        featureStackView.snp.makeConstraints { make in
            make.top.equalTo(topLabel.snp.bottom).offset(12)
            make.leading.equalTo(contentView).inset(22)
            make.trailing.equalTo(restoreButton.snp.leading).offset(-4)
            make.bottom.equalTo(contentView).inset(20)
        }
    }

    // MARK: - Default Layout (text stacked, pin icon, buttons at bottom)

    private func setupDefaultLayout() {
        let imageView = UIImageView(image: UIImage(systemName: "pin.fill"))
        imageView.tintColor = .white.withAlphaComponent(0.5)
        if Language.type() == .ar {
            imageView.transform = .init(rotationAngle: .pi / -4.0)
        } else {
            imageView.transform = .init(rotationAngle: .pi / 4.0)
        }
        contentView.addSubview(imageView)
        imageView.snp.makeConstraints { make in
            make.top.equalTo(contentView).inset(24)
            make.trailing.equalTo(contentView).inset(20)
            make.height.width.equalTo(40.0)
        }

        topLabel.snp.makeConstraints { make in
            make.top.equalTo(contentView).inset(20)
            make.leading.equalTo(contentView).inset(24)
            make.trailing.equalTo(contentView).inset(24)
        }
        topLabel.setContentHuggingPriority(.defaultLow, for: .vertical)

        featureStackView.snp.makeConstraints { make in
            make.top.equalTo(topLabel.snp.bottom).offset(12)
            make.leading.equalTo(contentView).inset(24)
            make.trailing.equalTo(contentView).inset(24)
        }

        purchaseButton.snp.makeConstraints { make in
            make.top.equalTo(featureStackView.snp.bottom).offset(10.0)
            make.trailing.equalTo(contentView).inset(20.0)
            make.height.greaterThanOrEqualTo(40.0)
            make.bottom.equalTo(contentView).inset(20)
        }

        restoreButton.snp.makeConstraints { make in
            make.centerY.equalTo(purchaseButton)
            make.leading.equalTo(contentView).inset(20)
        }
    }

    // MARK: - Button Setup

    private func setupPurchaseButton() {
        var configuration = UIButton.Configuration.tinted()
        configuration.image = UIImage(systemName: "arrowshape.up.circle")
        configuration.title = String(localized: "membership.purchase")
        configuration.titleAlignment = .center
        configuration.imagePadding = 6.0
        configuration.cornerStyle = .large
        configuration.titlePadding = 4.0
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer({ incoming in
            var outgoing = incoming
            outgoing.font = UIFont.systemFont(ofSize: 16, weight: .bold)
            return outgoing
        })
        configuration.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer({ incoming in
            var outgoing = incoming
            outgoing.font = UIFont.preferredFont(forTextStyle: .footnote)
            return outgoing
        })

        purchaseButton = UIButton(configuration: configuration)
        purchaseButton.tintColor = .white
        purchaseButton.setContentHuggingPriority(.required, for: .horizontal)
        purchaseButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        purchaseButton.addTarget(self, action: #selector(purchaseAction), for: .touchUpInside)

        purchaseButton.configurationUpdateHandler = { [weak self] button in
            var config = button.configuration
            config?.subtitle = self?.priceText
            button.configuration = config
        }
    }

    private func setupRestoreButton() {
        var configuration = UIButton.Configuration.plain()
        configuration.title = String(localized: "membership.restore")
        configuration.titleAlignment = .center
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer({ incoming in
            var outgoing = incoming
            outgoing.font = UIFont.preferredFont(forTextStyle: .caption1)
            outgoing.underlineStyle = [.single]
            outgoing.underlineColor = .white.withAlphaComponent(0.8)
            return outgoing
        })
        configuration.contentInsets = .init(top: 0, leading: 4, bottom: 0, trailing: 4)

        restoreButton = UIButton(configuration: configuration)
        restoreButton.tintColor = .white.withAlphaComponent(0.8)
        restoreButton.addTarget(self, action: #selector(restoreAction), for: .touchUpInside)
    }

    // MARK: - Actions

    @objc
    func restoreAction() {
        restoreClosure?()
    }

    @objc
    func purchaseAction() {
        purchaseClosure?()
    }

    // MARK: - PromotionCellConfigurable

    func update(configuration config: PromotionCellConfiguration) {
        gradientView.gradientColors = config.gradientColors

        // Title
        let text = config.title
        let attributedString = NSMutableAttributedString(string: text)
        attributedString.addAttribute(.foregroundColor, value: config.titleColor, range: NSRange(location: 0, length: text.count))
        if let highlight = config.titleHighlight, let range = text.range(of: highlight) {
            let nsRange = NSRange(range, in: text)
            attributedString.addAttribute(.foregroundColor, value: config.titleHighlightColor, range: nsRange)
        }
        topLabel.attributedText = attributedString

        // Features
        featureStackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for feature in config.features {
            let label = UILabel()
            label.font = UIFont.preferredFont(forTextStyle: .footnote)
            label.textAlignment = .natural
            label.textColor = config.featureColor
            label.numberOfLines = 0
            label.text = feature
            label.setContentHuggingPriority(.required, for: .vertical)
            featureStackView.addArrangedSubview(label)
        }
    }

    func update(price: String) {
        priceText = price
        purchaseButton.setNeedsUpdateConfiguration()
    }
}
