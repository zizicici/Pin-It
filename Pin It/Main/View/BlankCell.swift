//
//  BlankCell.swift
//  Pin It
//
//  Created by Ci Zi on 2025/10/26.
//

import Foundation
import UIKit
import SnapKit

class BlankCell: UICollectionViewCell {
    let blankLabel: UILabel = {
        let label = UILabel()
        label.font = UIFont.preferredFont(forTextStyle: .body)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.text = String(localized: "pin.blank")
        
        return label
    }()
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        
        contentView.addSubview(blankLabel)
        blankLabel.snp.makeConstraints { make in
            make.leading.trailing.equalTo(contentView)
            make.top.height.equalTo(contentView).inset(12.0)
        }
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
