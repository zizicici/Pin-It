//
//  PostCell.swift
//  Pin It
//
//  Created by Ci Zi on 2025/10/23.
//

import UIKit
import SnapKit

fileprivate extension UIConfigurationStateCustomKey {
    static let postItem = UIConfigurationStateCustomKey("com.zizicici.pin.post.cell.item")
}

private extension UICellConfigurationState {
    var postItem: Post.Detail? {
        set { self[.postItem] = newValue }
        get { return self[.postItem] as? Post.Detail }
    }
}

protocol PostCellDelegate: NSObjectProtocol {
    func getMoreButtonMenu(for post: Post.Detail) -> UIMenu
    func update(post: Post, isPinned: Bool)
}

class PostBaseCell: UICollectionViewCell {
    private var postItem: Post.Detail? = nil
    
    weak var delegate: PostCellDelegate? = nil
    
    func update(with newPost: Post.Detail) {
        guard postItem != newPost else { return }
        postItem = newPost
        setNeedsUpdateConfiguration()
    }
    
    override var configurationState: UICellConfigurationState {
        var state = super.configurationState
        state.postItem = self.postItem
        return state
    }
}

class PostCell: PostBaseCell {
    private var pinButton: UIButton = {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "pin")
        let button = UIButton(configuration: configuration)
        button.tintColor = .systemRed

        return button
    }()
    
    private var moreButton: UIButton = {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "ellipsis")
        let button = UIButton(configuration: configuration)
        button.tintColor = AppColor.text.withAlphaComponent(0.8)
        button.showsMenuAsPrimaryAction = true

        return button
    }()
    
    private var postView: PostView = PostView()
    
    private func setupViewsIfNeeded() {
        guard postView.superview == nil else { return }
        
        contentView.addSubview(postView)
        postView.snp.makeConstraints { make in
            make.leading.equalTo(contentView).inset(12.0)
            make.top.bottom.equalTo(contentView)
            make.trailing.equalTo(contentView).inset(54.0)
        }
        
        contentView.addSubview(pinButton)
        pinButton.snp.makeConstraints { make in
            make.top.equalTo(contentView).inset(6.0)
            make.trailing.equalTo(contentView)
            make.width.height.equalTo(44.0)
        }
        
        contentView.addSubview(moreButton)
        moreButton.snp.makeConstraints { make in
            make.bottom.equalTo(contentView).inset(6.0)
            make.trailing.equalTo(contentView)
            make.width.height.equalTo(44.0)
            make.top.equalTo(pinButton.snp.bottom).offset(4.0)
        }
        
        pinButton.addTarget(self, action: #selector(pinAction), for: .touchUpInside)
    }
    
    override func updateConfiguration(using state: UICellConfigurationState) {
        super.updateConfiguration(using: state)
        
        setupViewsIfNeeded()
        
        if let postItem = state.postItem {
            postView.update(with: postItem)
            
            pinButton.configurationUpdateHandler = { button in
                if postItem.post.isPinned {
                    button.tintColor = .systemRed
                    button.isSelected = true
                } else {
                    button.tintColor = AppColor.text.withAlphaComponent(0.8)
                    button.isSelected = false
                }
            }
            pinButton.setNeedsUpdateConfiguration()
            
            moreButton.menu = delegate?.getMoreButtonMenu(for: postItem)
        }
    }
    
    @objc
    private func pinAction() {
        if let postItem = configurationState.postItem {
            delegate?.update(post: postItem.post, isPinned: !postItem.post.isPinned)
        }
    }
}

class PostView: UIView {
    private var imageView: UIImageView = {
        let imageView = UIImageView()
        imageView.isUserInteractionEnabled = false
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .clear
        
        return imageView
    }()
    
    private var textView: UITextView = {
        let textView = UITextView()
        textView.font = UIFont.preferredFont(forTextStyle: .body)
        textView.isEditable = false
        textView.isSelectable = false
        textView.backgroundColor = .clear
        
        return textView
    }()
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        
        backgroundColor = AppColor.paper
        
        if #available(iOS 26.0, *) {
            cornerConfiguration = .corners(radius: 24.0)
        } else {
            layer.cornerRadius = 16.0
        }
        
        layer.masksToBounds = true
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public func update(with postItem: Post.Detail) {
        guard postItem.texts.count + postItem.images.count > 0 else {
            removeSubviews()
            return
        }
        
        if let text = postItem.texts.first {
            addTextViewIfNeeded()

            textView.text = text.content
        }
        
        if let image = postItem.images.first {
            addImageViewIfNeeded()
            
            if let path = ImageCacheManager.shared.getPath(name: image.cropped, type: .processed) {
                imageView.image = UIImage(contentsOfFile: path)
            } else {
                imageView.image = nil
            }
        }
    }
    
    private func removeSubviews() {
        subviews.forEach{ $0.removeFromSuperview() }
    }
    
    private func addTextViewIfNeeded() {
        imageView.removeFromSuperview()
        
        if textView.superview == nil {
            addSubview(textView)
            textView.snp.makeConstraints { make in
                make.leading.trailing.equalTo(self).inset(10.0)
                make.top.bottom.equalTo(self).inset(4.0)
            }
        }
    }
    
    private func addImageViewIfNeeded() {
        textView.removeFromSuperview()
        
        if imageView.superview == nil {
            addSubview(imageView)
            imageView.snp.makeConstraints { make in
                make.edges.equalTo(self)
            }
        }
    }
}
