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
    
    private var editorClosure: ((Post.Detail) -> ())?
    
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
    
    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    convenience init(postDetail: Post.Detail, editorClosure: @escaping (Post.Detail) -> ()) {
        self.init()
        self.detail = postDetail
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
                var content = UIListContentConfiguration.valueCell()
                content.text = action.title
                content.image = action.image
                content.imageProperties.tintColor = .systemRed
                cell.contentConfiguration = content
                return cell
            case .expirationToggle(let enable):
                let cell = tableView.dequeueReusableCell(withIdentifier: NSStringFromClass(UITableViewCell.self), for: indexPath)
                let itemSwitch = UISwitch()
                itemSwitch.isOn = enable
                itemSwitch.addTarget(self, action: #selector(self.toggle(_:)), for: .touchUpInside)
                itemSwitch.onTintColor = .systemRed
                var content = cell.defaultContentConfiguration()
                content.text = String(localized: "editor.expiration.toggle")
                content.textProperties.color = .label
                cell.accessoryView = itemSwitch
                cell.contentConfiguration = content
                return cell
            case .expiration(let startTime):
                let cell = tableView.dequeueReusableCell(withIdentifier: NSStringFromClass(DateCell.self), for: indexPath)
                if let cell = cell as? DateCell {
                    if startTime == nil {
                        cell.update(with: DateCellItem(title: "", nanoSecondsFrom1970: nil, day: ZCCalendar.manager.today + 5))
                    } else {
                        cell.update(with: DateCellItem(title: "", nanoSecondsFrom1970: startTime, day: nil))
                    }
                    cell.selectDateAction = { [weak self] nanoSeconds in
                        guard let self = self else { return }
                        self.expirationTime = nanoSeconds
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
            self.editorClosure?(self.detail)
        }
    }
    
    private func saveToDetail() {
        guard let imageInfo = imageInfo else { return }
        let image = imageInfo.image
        let cropRect = imageInfo.rect
        
        let resizedImage = image.resizeImageIfNeeded(maxWidth: 320 * 3, maxHeight: 160 * 3)
        
        if var postImage = detail.images.first {
            _ = ImageCacheManager.shared.deleteImage(fileName: postImage.processed, type: .processed)
            if let processed = ImageCacheManager.shared.storeImage(resizedImage, type: .processed) {
                postImage.processed = processed
                postImage.orientation = Int64(imageInfo.orientation)
                postImage.minX = Int64(cropRect.minX)
                postImage.minY = Int64(cropRect.minY)
                postImage.maxX = Int64(cropRect.maxX)
                postImage.maxY = Int64(cropRect.maxY)
                
                detail.images[0] = postImage
            }
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
        case .expirationToggle, .expiration:
            break
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

class UIDraggableTableView: UITableView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        if view.isKind(of: UIButton.self) {
            return true
        } else {
            return super.touchesShouldCancel(in: view)
        }
    }
}
