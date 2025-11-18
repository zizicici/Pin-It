//
//  PostImageCell.swift
//  Pin It
//
//  Created by Ci Zi on 2025/11/18.
//

import Foundation
import SnapKit
import UIKit

class PostImageCell: UITableViewCell {
    private var postView: PostView = PostView()
    
    private var postImageView: UIImageView = {
        let imageView = UIImageView()
        imageView.isUserInteractionEnabled = false
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .clear
        
        return imageView
    }()
    
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        
        contentView.addSubview(postImageView)
        postImageView.snp.makeConstraints { make in
            make.edges.equalTo(contentView)
            make.height.equalTo(120.0)
        }
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public func update(image: UIImage) {
        postImageView.image = image
    }
}
