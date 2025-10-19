//
//  EditorViewController.swift
//  Pin It
//
//  Created by Salley Garden on 2025/10/19.
//

import UIKit
import SnapKit

class EditorViewController: UIViewController {
    private var postText: PostText!
    
    private var tableView: UITableView!
    private var dataSource: DataSource!
    
    private var editorClosure: ((PostText) -> ())?
    
    enum Section: Int, Hashable {
        case text
        
        var header: String? {
            switch self {
            case .text:
                return String(localized: "editor.text")
            }
        }
        
        var footer: String? {
            switch self {
            case .text:
                return nil
            }
        }
    }
    
    enum Item: Hashable {
        case text(String?)
    }
    
    class DataSource: UITableViewDiffableDataSource<Section, Item> {
        override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
            let sectionKind = sectionIdentifier(for: section)
            return sectionKind?.header
        }
        
        override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
            let sectionKind = sectionIdentifier(for: section)
            return sectionKind?.footer
        }
    }
    
    private var content: String {
        get {
            return postText.content
        }
        set {
            if postText.content != newValue {
                postText.content = newValue
                updateSaveButtonStatus()
            }
        }
    }
    
    weak var commentCell: TextViewCell?
    
    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    convenience init(postText: PostText, editorClosure: @escaping (PostText) -> ()) {
        self.init()
        self.postText = postText
        self.editorClosure = editorClosure
    }
    
    deinit {
        print("EditorViewController is deinited")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        view.backgroundColor = AppColor.background
        
        let saveItem = UIBarButtonItem(title: String(localized: "button.save"), style: .done, target: self, action: #selector(save))
        saveItem.tintColor = .systemRed
        saveItem.isEnabled = false
        navigationItem.rightBarButtonItem = saveItem
        
        let cancelItem = UIBarButtonItem(title: String(localized: "button.cancel"), style: .plain, target: self, action: #selector(dismissViewController))
        cancelItem.tintColor = .systemRed
        navigationItem.leftBarButtonItem = cancelItem
        
        configureHierarchy()
        configureDataSource()
        reloadData()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        _ = commentCell?.becomeFirstResponder()
    }
    
    func configureHierarchy() {
        tableView = UIDraggableTableView(frame: .zero, style: .insetGrouped)
        tableView.backgroundColor = AppColor.background
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: NSStringFromClass(UITableViewCell.self))
        tableView.register(TextViewCell.self, forCellReuseIdentifier: NSStringFromClass(TextViewCell.self))
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 50.0
        tableView.delegate = self
        view.addSubview(tableView)
        tableView.snp.makeConstraints { make in
            make.edges.equalTo(view)
        }
        tableView.contentInset = UIEdgeInsets(top: -20.0, left: 0, bottom: 0, right: 0)
        tableView.keyboardDismissMode = .onDrag
    }
    
    func configureDataSource() {
        dataSource = DataSource(tableView: tableView) { [weak self] (tableView, indexPath, item) -> UITableViewCell? in
            guard let self = self else { return nil }
            guard let identifier = self.dataSource.itemIdentifier(for: indexPath) else { return nil }
            switch identifier {
            case .text(let content):
                let cell = tableView.dequeueReusableCell(withIdentifier: NSStringFromClass(TextViewCell.self), for: indexPath)
                if let cell = cell as? TextViewCell {
                    cell.tintColor = .systemRed
                    cell.update(text: content, placeholder: String(localized: "editor.text.placeholder"))
                    cell.textDidChanged = { [weak self] text in
                        self?.content = text
                    }
                    self.commentCell = cell
                }
                return cell
            }
        }
    }
    
    func reloadData() {
        updateSaveButtonStatus()
        
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.text])
        snapshot.appendItems([.text(content)], toSection: .text)
        
        dataSource.apply(snapshot, animatingDifferences: false)
    }
    
    @objc
    func save() {
        dismiss(animated: ConsideringUser.animated) { [weak self] in
            guard let self = self else { return }
            self.editorClosure?(self.postText)
        }
    }
    
    @objc
    func dismissViewController() {
        dismiss(animated: ConsideringUser.animated)
    }
    
    func updateSaveButtonStatus() {
        navigationItem.rightBarButtonItem?.isEnabled = allowSave()
    }
    
    func allowSave() -> Bool {
        return content.isValidRecordComment()
    }
}


extension EditorViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
    }
}

extension String {
    func isValidRecordComment() -> Bool{
        return count > 0
    }
}

class UIDraggableTableView: UITableView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        if view.isKind(of: UIButton.self) {
            return true
        } else {
            return super.touchesShouldCancel(in: view)
        }
    }
}
