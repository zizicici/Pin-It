//
//  TextDetailViewController.swift
//  Pin It
//
//  Created by Ci Zi on 2025/11/8.
//

import Foundation
import UIKit
import SnapKit
import MoreKit

class TextDetailViewController: UIViewController {
    var textInfo: PostText!
    
    var textView: UITextView = {
        let textView = UITextView()
        
        textView.font = UIFont.preferredFont(forTextStyle: .title1)
        textView.textAlignment = .natural
        textView.backgroundColor = AppColor.background
        textView.textColor = AppColor.text
        textView.isEditable = false
        
        return textView
    }()
    
    var editClosure: ((PostText) -> ())?
    
    private var editButton: UIBarButtonItem?
    private var closeButton: UIBarButtonItem?
    
    convenience init(textInfo: PostText!) {
        self.init(nibName: nil, bundle: nil)
        self.textInfo = textInfo
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        view.backgroundColor = AppColor.background
        
        let editButton = UIBarButtonItem(title: String(localized: "pin.edit"), style: .plain, target: self, action: #selector(editAction))
        editButton.tintColor = .systemRed
        navigationItem.rightBarButtonItem = editButton
        self.editButton = editButton
        
        let closeButton = UIBarButtonItem(title: String(localized: "button.close"), style: .plain, target: self, action: #selector(closeAction))
        closeButton.tintColor = .systemRed
        navigationItem.leftBarButtonItem = closeButton
        self.closeButton = closeButton
        
        view.addSubview(textView)
        textView.snp.makeConstraints { make in
            make.edges.equalTo(view)
        }
        
        textView.textContainerInset = .init(top: 20, left: 20, bottom: 20, right: 20)
        
        let text = textInfo.content
        
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 0
        paragraphStyle.paragraphSpacing = 0
        paragraphStyle.lineHeightMultiple = 1.2

        let attributedString = NSMutableAttributedString(string: text)
        attributedString.addAttribute(
            .paragraphStyle,
            value: paragraphStyle,
            range: NSRange(location: 0, length: attributedString.length)
        )
        attributedString.addAttribute(
            .font,
            value: UIFont.preferredFont(forTextStyle: .title1),
            range: NSRange(location: 0, length: attributedString.length)
        )
        attributedString.addAttribute(
            .foregroundColor,
            value: UIColor.text,
            range: NSRange(location: 0, length: attributedString.length)
        )
        
        textView.attributedText = attributedString
    }
    
    @objc
    func editAction() {
        dismiss(animated: ConsideringUser.animated)
        
        editClosure?(textInfo)
    }
    
    @objc
    func closeAction() {
        dismiss(animated: ConsideringUser.animated)
    }
}
