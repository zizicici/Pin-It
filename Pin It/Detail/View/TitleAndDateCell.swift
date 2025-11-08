//
//  TitleAndDateCell.swift
//  Pin It
//
//  Created by Ci Zi on 2025/11/8.
//

import UIKit
import SnapKit

class TitleAndDateCell: ImageInfoBaseCell {
    var moonTitle: String?

    var titleLabel: UILabel = {
        let label = UILabel()
        label.font = UIFont.preferredFont(forTextStyle: .title2)
        label.textAlignment = .center
        label.textColor = AppColor.text
        
        return label
    }()
    
    var dateLabel: UILabel = {
        let label = UILabel()
        label.font = UIFont.preferredFont(forTextStyle: .body)
        label.textAlignment = .center
        label.textColor = AppColor.text.withAlphaComponent(0.75)
        
        return label
    }()
    
    private func setupViewsIfNeeded() {
        guard titleLabel.superview == nil else {
            return
        }
        
        contentView.addSubview(titleLabel)
        titleLabel.setContentHuggingPriority(.required, for: .vertical)
        titleLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        
        titleLabel.snp.makeConstraints { make in
            make.top.leading.trailing.equalTo(contentView)
        }
        
        contentView.addSubview(dateLabel)
        dateLabel.setContentHuggingPriority(.required, for: .vertical)
        dateLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        
        dateLabel.snp.makeConstraints { make in
            make.leading.trailing.bottom.equalTo(contentView)
            make.top.equalTo(titleLabel.snp.bottom).offset(10)
        }
    }
    
    override func updateConfiguration(using state: UICellConfigurationState) {
        super.updateConfiguration(using: state)
        setupViewsIfNeeded()
        
        if let imageInfo = state.imageInfo {
            titleLabel.text = moonTitle
            dateLabel.text = Date().formatted(date: .abbreviated, time: .standard)
        }
    }
}
