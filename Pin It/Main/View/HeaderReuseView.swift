//
//  HeaderReuseView.swift
//  Pin It
//
//  Created by Ci Zi on 2025/10/24.
//

import UIKit
import SnapKit

class HeaderReuseView: UICollectionReusableView {
    var titleLabel: UILabel = {
        let label = UILabel()
        if #available(iOS 26.0, *) {
            label.font = UIFont.preferredFont(forTextStyle: .headline)
        } else {
            label.font = UIFont.preferredFont(forTextStyle: .footnote)
        }
        label.textAlignment = .natural
        label.numberOfLines = 1
        label.textColor = .secondaryLabel
        
        return label
    }()
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        
        addSubview(titleLabel)
        titleLabel.snp.makeConstraints { make in
            make.top.equalTo(self).inset(8)
            make.bottom.equalTo(self).inset(8)
            make.leading.trailing.equalTo(self).inset(16)
        }
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
