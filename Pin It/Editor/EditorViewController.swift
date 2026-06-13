//
//  EditorViewController.swift
//  Pin It
//
//  Created by Ci Zi on 2025/10/19.
//

import UIKit
import SnapKit
import JXPhotoBrowser
import CropViewController
import ZCCalendar
import MoreKit

class EditorViewController: UIViewController {
    struct ImageInfo {
        var rect: CGRect
        var orientation: Int
        var image: UIImage
    }

    private var detail: Post.Detail!
    
    private var tableView: UITableView!
    private var dataSource: DataSource!
    
    private var textInfo: PostText? {
        return detail.texts.first
    }
    
    private var imageInfo: ImageInfo?
    
    private var day: GregorianDay {
        return ZCCalendar.manager.today + 5
    }
    
    private var expirationToggle: Bool = false {
        didSet {
            if expirationToggle == false {
                expirationTime = nil
            } else {
                if expirationTime == nil {
                    if let postDefaultExpirationTime = Post.getDefaultExpirationTime() {
                        expirationTime = postDefaultExpirationTime
                    } else {
                        expirationTime = Int64(Date().combine(with: day).timeIntervalSince1970) / 60 * 60 * 1000
                    }
                }
            }
            reloadData()
        }
    }
    
    private var expirationTime: Int64? {
        get {
            return detail.post.expirationTime
        }
        set {
            if detail.post.expirationTime != newValue {
                detail.post.expirationTime = newValue
                updateSaveButtonStatus()
            }
        }
    }
    
    private var actionLink: String {
        get {
            return detail.post.actionLink
        }
        set {
            if detail.post.actionLink != newValue {
                detail.post.actionLink = newValue
                reloadData()
            }
        }
    }
    
    private var originalStyleId: Int64?
    private var originalExpirationTime: Int64?
    private var originalActionLink: String = ""
    private var didSelectStyle = false
    private var imageDidChange = false
    private var textDidChange = false
    private var editorClosure: ((Post.Detail, Bool, Bool, Bool, Bool) -> ())?
    
    enum Section: Int, Hashable {
        case text
        case image
        case advanced
        
        var header: String? {
            switch self {
            case .text:
                return String(localized: "editor.text")
            case .image:
                return String(localized: "editor.image")
            case .advanced:
                return String(localized: "editor.advanced")
            }
        }
        
        var footer: String? {
            switch self {
            case .text, .image, .advanced:
                return nil
            }
        }
    }
    
    enum Item: Hashable {
        case text(String?)
        case image(UIImage)
        case imageAction(ImageAction)
        case style(PostStyle?)
        case actionLink(String)
        case expirationToggle(Bool)
        case expiration(Int64?)
    }
    
    enum ImageAction: Hashable {
        case fullScreen
        case crop
        
        var title: String {
            switch self {
            case .fullScreen:
                String(localized: "image.action.fullScreen")
            case .crop:
                String(localized: "image.action.crop")
            }
        }
        
        var image: UIImage? {
            switch self {
            case .fullScreen:
                return UIImage(systemName: "arrow.up.backward.and.arrow.down.forward.square")
            case .crop:
                return UIImage(systemName: "crop")
            }
        }
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
    
    private var text: String? {
        get {
            return textInfo?.content
        }
        set {
            if var postText = textInfo {
                postText.content = newValue ?? ""
                detail.texts[0] = postText
            }
            updateSaveButtonStatus()
        }
    }
    
    weak var commentCell: TextViewCell?
    
    private var style: PostStyle? {
        didSet {
            reloadData()
        }
    }
    
    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    convenience init(postDetail: Post.Detail, editorClosure: @escaping (Post.Detail, Bool, Bool, Bool, Bool) -> ()) {
        self.init()
        self.detail = postDetail
        self.originalStyleId = postDetail.style?.id
        self.originalExpirationTime = postDetail.post.expirationTime
        self.originalActionLink = postDetail.post.actionLink
        self.style = detail.style
        self.editorClosure = editorClosure
        
        expirationToggle = (expirationTime != nil)
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
        
        if let image = detail.images.first {
            imageInfo = ImageInfo(rect: image.rect, orientation: Int(image.orientation), image: image.getProcessedImage() ?? UIImage())
        }
        
        configureHierarchy()
        configureDataSource()
        reloadData()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        _ = commentCell?.becomeFirstResponder()
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
    }
    
    func configureHierarchy() {
        tableView = UIDraggableTableView(frame: .zero, style: .insetGrouped)
        tableView.backgroundColor = AppColor.background
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: NSStringFromClass(UITableViewCell.self))
        tableView.register(TextViewCell.self, forCellReuseIdentifier: NSStringFromClass(TextViewCell.self))
        tableView.register(PostImageCell.self, forCellReuseIdentifier: NSStringFromClass(PostImageCell.self))
        tableView.register(DateCell.self, forCellReuseIdentifier: NSStringFromClass(DateCell.self))
        tableView.register(OptionCell<PostStyle>.self, forCellReuseIdentifier: NSStringFromClass(OptionCell<PostStyle>.self))
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
                        self?.textDidChange = true
                        self?.text = text
                    }
                    self.commentCell = cell
                }
                return cell
            case .image(let postImage):
                let cell = tableView.dequeueReusableCell(withIdentifier: NSStringFromClass(PostImageCell.self), for: indexPath)
                if let cell = cell as? PostImageCell {
                    cell.update(image: postImage)
                }
                return cell
            case .imageAction(let action):
                let cell = tableView.dequeueReusableCell(withIdentifier: NSStringFromClass(UITableViewCell.self), for: indexPath)
                cell.accessoryType = .none
                cell.accessoryView = nil
                
                var content = UIListContentConfiguration.valueCell()
                content.text = action.title
                content.textProperties.color = AppColor.text
                content.image = action.image
                content.imageProperties.tintColor = .systemRed
                cell.contentConfiguration = content
                return cell
            case .style(let style):
                let cell = tableView.dequeueReusableCell(withIdentifier: NSStringFromClass(OptionCell<PostStyle>.self), for: indexPath)
                if let cell = cell as? OptionCell<PostStyle> {
                    cell.update(with: style)
                    let noneAction = UIAction(title: PostStyle.noneTitle, state: style == nil ? .on : .off) { [weak self] _ in
                        self?.selectStyle(nil)
                    }
                    let actions = DataManager.shared.fetchAllStyles().map { target in
                        let action = UIAction(title: target.title, subtitle: target.subtitle, state: style == target ? .on : .off) { [weak self] _ in
                            self?.selectStyle(target)
                        }
                        return action
                    }
                    let divider = UIMenu(title: "", options: . displayInline, children: actions)
                    
                    let menu = UIMenu(children: [noneAction, divider])
                    cell.valueButton.menu = menu
                }
                return cell
            case .actionLink(let link):
                let cell = tableView.dequeueReusableCell(withIdentifier: NSStringFromClass(UITableViewCell.self), for: indexPath)
                cell.accessoryType = .disclosureIndicator
                cell.accessoryView = nil
                
                var content = UIListContentConfiguration.valueCell()
                content.text = String(localized: "actionLink.title")
                content.textProperties.color = AppColor.text
                if link.isEmpty {
                    content.secondaryText = String(localized: "actionLink.none")
                } else {
                    content.secondaryText = link
                }
                cell.contentConfiguration = content
                return cell
            case .expirationToggle(let enable):
                let cell = tableView.dequeueReusableCell(withIdentifier: NSStringFromClass(UITableViewCell.self), for: indexPath)
                
                let itemSwitch = UISwitch()
                itemSwitch.isOn = enable
                itemSwitch.addTarget(self, action: #selector(self.toggle(_:)), for: .touchUpInside)
                itemSwitch.onTintColor = .systemRed
                cell.accessoryView = itemSwitch
                
                var content = cell.defaultContentConfiguration()
                content.text = String(localized: "editor.expiration.toggle")
                content.textProperties.color = AppColor.text
                cell.contentConfiguration = content
                return cell
            case .expiration(let startTime):
                let cell = tableView.dequeueReusableCell(withIdentifier: NSStringFromClass(DateCell.self), for: indexPath)
                if let cell = cell as? DateCell {
                    if startTime == nil {
                        cell.update(with: DateCellItem(title: "", millisecondsSince1970: nil, day: ZCCalendar.manager.today + 5))
                    } else {
                        cell.update(with: DateCellItem(title: "", millisecondsSince1970: startTime, day: nil))
                    }
                    cell.selectDateAction = { [weak self] milliseconds in
                        guard let self = self else { return }
                        self.expirationTime = milliseconds
                        self.updateSaveButtonStatus()
                    }
                }
                return cell
            }
        }
    }
    
    func reloadData() {
        updateSaveButtonStatus()
        
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        
        switch detail.detailType {
        case .text:
            snapshot.appendSections([.text])
            snapshot.appendItems([.text(text)], toSection: .text)
        case .image:
            if let imageInfo = imageInfo {
                snapshot.appendSections([.image])
                snapshot.appendItems([.image(imageInfo.image), .imageAction(.fullScreen), .imageAction(.crop)], toSection: .image)
            }
        }
        
        snapshot.appendSections([.advanced])
        snapshot.appendItems([.style(style)], toSection: .advanced)
        snapshot.appendItems([.actionLink(actionLink)], toSection: .advanced)
        snapshot.appendItems([.expirationToggle(expirationToggle)], toSection: .advanced)
        if expirationToggle {
            snapshot.appendItems([.expiration(expirationTime)], toSection: .advanced)
        }
        
        dataSource.apply(snapshot, animatingDifferences: false)
    }
    
    @objc
    func save() {
        dismiss(animated: ConsideringUser.animated) { [weak self] in
            guard let self = self else { return }
            self.saveToDetail()
            let styleDidChange = self.didSelectStyle || self.originalStyleId != self.detail.style?.id
            // Net diff, not touched-flags: toggling expiration on and back off
            // (or retyping the same link) must not write the stale snapshot
            // back over a concurrent remote edit of these fields.
            let postFieldsDidChange = self.originalExpirationTime != self.detail.post.expirationTime
                || self.originalActionLink != self.detail.post.actionLink
            self.editorClosure?(self.detail, styleDidChange, self.imageDidChange, self.textDidChange, postFieldsDidChange)
        }
    }

    private func saveToDetail() {
        imageDidChange = false
        saveImageInfoToDetail()
        detail.style = style
    }
    
    private func saveImageInfoToDetail() {
        guard let imageInfo = imageInfo else { return }
        guard var postImage = detail.images.first else { return }
        let cropRect = imageInfo.rect
        let orientation = Int64(imageInfo.orientation)
        let minX = Int64(cropRect.minX)
        let minY = Int64(cropRect.minY)
        let maxX = Int64(cropRect.maxX)
        let maxY = Int64(cropRect.maxY)
        guard postImage.orientation != orientation
            || postImage.minX != minX
            || postImage.minY != minY
            || postImage.maxX != maxX
            || postImage.maxY != maxY else {
            return
        }
        let resizedImage = imageInfo.image.resizeImageIfNeeded(maxWidth: 320 * 3, maxHeight: 160 * 3)
        // Store the replacement before touching the old file: deleting
        // first would leave the row pointing at a missing file if the DB
        // update fails. The caller deletes the actual replaced file only
        // after the row update commits; a failed edit keeps the replacement
        // available for save-as-new conflict recovery.
        if let processed = ImageCacheManager.shared.storeImage(resizedImage, type: .processed) {
            postImage.processed = processed
            postImage.orientation = orientation
            postImage.minX = minX
            postImage.minY = minY
            postImage.maxX = maxX
            postImage.maxY = maxY

            detail.images[0] = postImage
            imageDidChange = true
        }
    }

    private func selectStyle(_ style: PostStyle?) {
        didSelectStyle = true
        self.style = style
    }
    
    @objc
    func dismissViewController() {
        dismiss(animated: ConsideringUser.animated)
    }
    
    func updateSaveButtonStatus() {
        navigationItem.rightBarButtonItem?.isEnabled = allowSave()
    }
    
    func allowSave() -> Bool {
        switch detail.detailType {
        case .text:
            return text?.isValidRecordComment() ?? false
        case .image:
            return true
        }
    }
    
    @objc
    func toggle(_ expirationSwitch: UISwitch) {
        expirationToggle = expirationSwitch.isOn
    }
    
    func editActionLink() {
        let alertController = UIAlertController(title: String(localized: "actionLink.alert.title"), message: String(localized: "actionLink.alert.message"), preferredStyle: .alert)
        alertController.addTextField { [weak self] textField in
            guard let self = self else { return }
            textField.placeholder = String(localized: "actionLink.none")
            textField.text = self.actionLink
            textField.addTarget(alertController, action: #selector(alertController.textDidChangeInActionLink), for: .editingChanged)
        }
        let cancelAction = UIAlertAction(title: String(localized: "button.cancel"), style: .cancel) { _ in
            //
        }
        let okAction = UIAlertAction(title: String(localized: "button.confirm"), style: .default) { [weak self] _ in
            self?.actionLink = alertController.textFields?.first?.text ?? ""
        }

        alertController.addAction(cancelAction)
        alertController.addAction(okAction)
        present(alertController, animated: ConsideringUser.animated, completion: nil)
    }
}


extension EditorViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        switch item {
        case .text(_):
            break
        case .image(_):
            enterImageDetail(for: detail)
        case .imageAction(let action):
            switch action {
            case .crop:
                cropImage()
            case .fullScreen:
                enterImageDetail(for: detail)
            }
        case .actionLink:
            editActionLink()
        case .expirationToggle, .expiration:
            break
        case .style(let style):
            self.style = style
        }
    }
}

extension EditorViewController {
    func enterImageDetail(for detail: Post.Detail) {
        guard let image = detail.images.first else { return }
        guard let originalImage = ImageCacheManager.shared.retrieveImage(fileName: image.original, type: .original) else {
            return
        }
        
        let displayImage = ImageCropper.cropImage(originalImage, to: image.rect)
        
        let browser = JXPhotoBrowser()
        browser.numberOfItems = {
            return 2
        }
        browser.reloadCellAtIndex = { context in
            let browserCell = context.cell as? JXPhotoBrowserImageCell
            if context.index == 0 {
                browserCell?.imageView.image = displayImage
            } else {
                browserCell?.imageView.image = originalImage
            }
        }
        browser.pageIndex = 0
        browser.show(method: .present(fromVC: self, embed: nil))
    }
    
    func cropImage() {
        guard let image = detail.images.first, let originalImage = image.getOriginalImage() else { return }
        let cropController = CropViewController(croppingStyle: .default, image: originalImage)
        cropController.delegate = self
        cropController.title = String(localized: "editor.image.crop")
        cropController.imageCropFrame = image.rect
        cropController.modalPresentationStyle = .popover
        
        let nav = UINavigationController(rootViewController: cropController)
        
        present(nav, animated: ConsideringUser.animated, completion: nil)
    }
}

extension EditorViewController: CropViewControllerDelegate {
    func cropViewController(_ cropViewController: CropViewController, didCropToImage image: UIImage, withRect cropRect: CGRect, angle: Int) {
        defer {
            cropViewController.dismiss(animated: ConsideringUser.animated)
        }
        
        imageInfo = ImageInfo(rect: cropRect, orientation: angle, image: image)
        reloadData()
    }
    
    func cropViewController(_ cropViewController: CropViewController, didFinishCancelled cancelled: Bool) {
        cropViewController.dismiss(animated: ConsideringUser.animated)
    }
}

extension String {
    func isValidRecordComment() -> Bool{
        return count > 0
    }
}

extension UIAlertController {
    @objc
    func textDidChangeInActionLink() {
        if let content = textFields?[0].text, let action = actions.last {
            action.isEnabled = (content.count >= 0)
        }
    }
}
