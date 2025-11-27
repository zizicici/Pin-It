//
//  MainViewController.swift
//  Pin It
//
//  Created by Ci Zi on 2025/10/13.
//

import UIKit
import SnapKit
import PhotosUI
import CropViewController
import TipKit
import JXPhotoBrowser

class MainViewController: UIViewController {
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    
    private var currentImage: UIImage?
    private var currentPostImage: PostImage?
    
    static let sectionHeaderElementKind = "sectionHeaderElementKind"
    
    var addPostTip = AddPostTip()
    
    enum Section: Hashable, Sendable {
        case pinned
        case others
        
        var title: String {
            switch self {
            case .pinned:
                return String(localized: "pin.pinned.title")
            case .others:
                return String(localized: "pin.others.title")
            }
        }
    }
    
    enum Item: Hashable {
        case blank(Section)
        case post(Post.Detail)
        
        var post: Post? {
            switch self {
            case .blank:
                return nil
            case .post(let detail):
                return detail.post
            }
        }
    }
    
    private var stateButton: UIBarButtonItem?
    private var addButton: UIBarButtonItem?
    private var minusButton: UIBarButtonItem?
    
    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        
        tabBarItem = UITabBarItem(title: String(localized: "controller.pin.title"), image: UIImage(systemName: "pin.fill"), tag: 1)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        view.backgroundColor = AppColor.background
        
        let stateButton = UIBarButtonItem(image: UIImage(systemName: "play.fill"), style: .plain, target: self, action: #selector(stateAction))
        stateButton.tintColor = .systemRed
        if #available(iOS 26.0, *) {
            navigationItem.leadingItemGroups = [UIBarButtonItemGroup.fixedGroup(items: [.fixedSpace(12), stateButton, .fixedSpace(12)])]
        } else {
            navigationItem.leftBarButtonItem = stateButton
        }
        self.stateButton = stateButton
        
        let addButton = UIBarButtonItem(image: UIImage(systemName: "plus"))
        addButton.tintColor = .systemRed
        self.addButton = addButton
        updateAddMenu()
        
        let minusButton = UIBarButtonItem(image: UIImage(systemName: "minus"))
        minusButton.tintColor = .systemRed
        self.minusButton = minusButton
        updateMinusMenu()
        
        if #available(iOS 26.0, *) {
            minusButton.sharesBackground = false
            addButton.sharesBackground = false
            navigationItem.trailingItemGroups = [UIBarButtonItemGroup.fixedGroup(items: [minusButton]), UIBarButtonItemGroup.fixedGroup(items: [addButton])]
        } else {
            navigationItem.rightBarButtonItems = [addButton, minusButton]
        }
        
        configureHierarchy()
        configureDataSource()
        reloadData()
        updateState()
        
        NotificationCenter.default.addObserver(self, selector: #selector(updateAddMenu), name: UIPasteboard.changedNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateAddMenu), name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateMinusMenu), name: .SettingsUpdate, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reloadData), name: .DatabaseUpdated, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateState), name: .LiveActivityStatusChanged, object: nil)
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        guard let addButton = addButton else { return }
        
        Task { @MainActor in
            for await shouldDisplay in addPostTip.shouldDisplayUpdates {
                if shouldDisplay {
                    let controller = TipUIPopoverViewController(addPostTip, sourceItem: addButton)
                    controller.view.tintColor = .systemRed
                    present(controller, animated: ConsideringUser.animated)
                } else if presentedViewController is TipUIPopoverViewController {
                    dismiss(animated: ConsideringUser.animated)
                }
            }
        }
    }
    
    @objc
    func updateAddMenu() {
        self.addButton?.menu = addMenu()
    }
    
    func addMenu() -> UIMenu {
        var elements: [UIMenuElement] = []
        
        let textAction = UIAction(title: String(localized: "editor.text"), image: UIImage(systemName: "text.alignleft")) { [weak self] _ in
            self?.addAction(text: "")
        }
        let imageAction = UIAction(title: String(localized: "editor.image"), image: UIImage(systemName: "photo")) { _ in
            self.pickImage()
        }
        
        elements.append(textAction)
        elements.append(imageAction)

        if UIPasteboard.general.hasImages || UIPasteboard.general.hasStrings {
            let pasteboardAction = UIAction(title: String(localized: "editor.pasteboard"), image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in
                if UIPasteboard.general.hasStrings {
                    if let text = UIPasteboard.general.string {
                        self?.showEditor(with: text)
                    } else {
                        self?.showPasteboardAlert()
                    }
                } else if UIPasteboard.general.hasImages {
                    if let image = UIPasteboard.general.image {
                        self?.showEditor(with: image)
                    } else {
                        self?.showPasteboardAlert()
                    }
                }
            }
            
            let currentPageDivider = UIMenu(title: "", options: .displayInline, children: [pasteboardAction])
            
            elements.append(currentPageDivider)
        }
        
        return UIMenu(children: elements)
    }
    
    func addAction(text: String) {
        let editorViewController = EditorViewController(postDetail: Post.Detail(post: Post.placeholder(), images: [], texts: [PostText(postId: -1, content: text, order: 0)])) { detail in
            if let postText = detail.texts.first {
                let post = DataManager.shared.createPost(content: postText.content, expirationTime: detail.post.expirationTime, styleId: nil)
                if let style = detail.style, let styleId = style.id, let postId = post?.id {
                    let decoration = PostDecoration(styleId: styleId, postId: postId)
                    _ = DataManager.shared.add(decoration: decoration)
                }
            }
        }
        
        navigationController?.present(UINavigationController(rootViewController: editorViewController), animated: ConsideringUser.animated)
    }
    
    @objc
    func updateMinusMenu() {
        self.minusButton?.menu = minusMenu()
    }
    
    func minusMenu() -> UIMenu {
        var elements: [UIMenuElement] = []
        
        let children: [UIAction] = DeleteOperationConfirmation.allCases.map { setting in
            return .init(title: setting.getName(), state: DeleteOperationConfirmation.current == setting ? .on : .off) { _ in
                try? DeleteOperationConfirmation.setCurrent(setting)
            }
        }
        
        let currentPageDivider = UIMenu(title: DeleteOperationConfirmation.getTitle(), subtitle: DeleteOperationConfirmation.current.getName(), image: UIImage(systemName: "minus.circle"), children: children)
        
        elements.append(currentPageDivider)
        
        let deleteUnpinsAction = UIAction(title: String(localized: "pin.delete.unpins"), image: UIImage(systemName: "rectangle.stack.badge.minus"), attributes: .destructive) { [weak self] _ in
            self?.showDeleteAllUnpinsAlert()
        }
        let deletePageDivider = UIMenu(title: "", options: .displayInline, children: [deleteUnpinsAction])
        
        elements.append(deletePageDivider)
        
        return UIMenu(children: elements)
    }
    
    @objc
    func updateState() {
        if #available(iOS 26.0, *) {
            navigationItem.title = String(localized: "controller.pin.title")
            navigationItem.subtitle = LiveActivityManager.shared.status.title
        } else {
            navigationItem.title = LiveActivityManager.shared.status.title
        }
        
        var imageName = "play.fill"
        switch LiveActivityManager.shared.status {
        case .initial:
            break
        case .running:
            imageName = "stop"
        case .idle:
            break
        }
        stateButton?.image = UIImage(systemName: imageName)
    }
    
    @objc
    func stateAction() {
        Task {
            switch LiveActivityManager.shared.status {
            case .initial:
                break
            case .running:
                await LiveActivityManager.shared.end()
            case .idle:
                await LiveActivityManager.shared.start()
            }
        }
    }
    
    func createLayout() -> UICollectionViewLayout {
        let layout = UICollectionViewCompositionalLayout() { sectionIndex, layoutEnvironment in
            
            var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
            configuration.headerMode = .supplementary
            
            configuration.showsSeparators = false
            configuration.backgroundColor = AppColor.background
            
            configuration.leadingSwipeActionsConfigurationProvider = { [weak self] (indexPath) in
                guard let self = self else { return nil }
                guard let item = self.dataSource.itemIdentifier(for: indexPath), case .post(let detail) = item else {
                    return nil
                }
                
                if detail.post.isPinned {
                    let unpinAction = UIContextualAction(style: .normal, title: String(localized: "pin.unpin")) { [weak self] (action, view, completion) in
                        self?.update(post: detail.post, isPinned: false)
                        
                        completion(true)
                    }
                    unpinAction.backgroundColor = .systemGray
                    
                    return UISwipeActionsConfiguration(actions: [unpinAction])
                } else {
                    let pinAction = UIContextualAction(style: .normal, title: String(localized: "pin.pin")) { [weak self] (action, view, completion) in
                        self?.update(post: detail.post, isPinned: true)

                        completion(true)
                    }
                    pinAction.backgroundColor = .systemRed
                    
                    return UISwipeActionsConfiguration(actions: [pinAction])
                }

            }
            
            configuration.trailingSwipeActionsConfigurationProvider = { [weak self] (indexPath) in
                guard let self = self else { return nil }
                guard let item = self.dataSource.itemIdentifier(for: indexPath), case .post(let detail) = item else {
                    return nil
                }
                
                let deleteAction = UIContextualAction(style: .destructive, title: String(localized: "pin.delete")) { [weak self] (action, view, completion) in
                    self?.deleteAction(for: detail)
                    
                    completion(true)
                }
                
                return UISwipeActionsConfiguration(actions: [deleteAction])
            }
            
            let section = NSCollectionLayoutSection.list(using: configuration,
                                                         layoutEnvironment: layoutEnvironment)
            
            let headerSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0),
                                                    heightDimension: .estimated(100))
            let sectionHeader = NSCollectionLayoutBoundarySupplementaryItem(
            layoutSize: headerSize,
            elementKind: Self.sectionHeaderElementKind, alignment: .top)
            section.boundarySupplementaryItems = [sectionHeader]
            
            return section
        }
        
        return layout
    }
    
    func configureHierarchy() {
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: createLayout())
        collectionView.delegate = self
        collectionView.backgroundColor = .clear
        view.addSubview(collectionView)
        collectionView.snp.makeConstraints { make in
            make.edges.equalTo(view)
        }
        collectionView.dragDelegate = self
        collectionView.dropDelegate = self
        collectionView.dragInteractionEnabled = true
        collectionView.contentInset = .init(top: 20, left: 0, bottom: 0, right: 0)
    }
    
    func configureDataSource() {
        let blankCellRegistration = createBlankCellRegistration()
        let normalCellRegistration = createNormalCellRegistration()
        
        dataSource = UICollectionViewDiffableDataSource<Section, Item>(collectionView: collectionView, cellProvider: { collectionView, indexPath, itemIdentifier in
            switch itemIdentifier {
            case .blank:
                return collectionView.dequeueConfiguredReusableCell(using: blankCellRegistration, for: indexPath, item: itemIdentifier)
            case .post(let post):
                return collectionView.dequeueConfiguredReusableCell(using: normalCellRegistration, for: indexPath, item: post)
            }
        })
        
        let headerRegistration = UICollectionView.SupplementaryRegistration
        <HeaderReuseView>(elementKind: Self.sectionHeaderElementKind) { [weak self] supplementaryView, elementKind, indexPath in
            guard let self = self else { return }
            guard let section = self.dataSource.sectionIdentifier(for: indexPath.section) else { fatalError("Unknown section") }
            
            supplementaryView.titleLabel.text = section.title
        }
        
        dataSource.supplementaryViewProvider = { collectionView, kind, index in
            return collectionView.dequeueConfiguredReusableSupplementary(using: headerRegistration, for: index)
        }
    }
    
    func createBlankCellRegistration() -> UICollectionView.CellRegistration<BlankCell, Item> {
        return UICollectionView.CellRegistration<BlankCell, Item> { (cell, indexPath, item) in
            return
        }
    }
    
    func createNormalCellRegistration() -> UICollectionView.CellRegistration<PostCell, Post.Detail> {
        return UICollectionView.CellRegistration<PostCell, Post.Detail> { [weak self] (cell, indexPath, item) in
            guard let self = self else { return }
            cell.delegate = self
            cell.update(with: item)
        }
    }
    
    @objc
    func reloadData() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        
        let pinnedPostDetails = DataManager.shared.fetchAllPostDetails(isPinned: true)
        let otherPostDetails = DataManager.shared.fetchAllPostDetails(isPinned: false)
        
        if pinnedPostDetails.count + otherPostDetails.count == 0 {
            snapshot.appendSections([.pinned])
            snapshot.appendItems([.blank(.pinned)], toSection: .pinned)
        } else {
            snapshot.appendSections([.pinned])
            if pinnedPostDetails.count == 0 {
                snapshot.appendItems([.blank(.pinned)], toSection: .pinned)
            } else {
                snapshot.appendItems(pinnedPostDetails.map{ .post($0) }, toSection: .pinned)
            }
            
            snapshot.appendSections([.others])
            if otherPostDetails.count == 0 {
                snapshot.appendItems([.blank(.others)], toSection: .others)
            } else {
                snapshot.appendItems(otherPostDetails.map{ .post($0) }, toSection: .others)
            }
        }
        
        dataSource.apply(snapshot, animatingDifferences: true)
    }
}

extension MainViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
    }
}

extension MainViewController: UICollectionViewDragDelegate {
    func collectionView(_ collectionView: UICollectionView, itemsForBeginning session: UIDragSession, at indexPath: IndexPath) -> [UIDragItem] {
        if let item = dataSource.itemIdentifier(for: indexPath) {
            switch item {
            case .blank:
                return []
            case .post(let detail):
                let title = detail.title
                let itemProvider = NSItemProvider(object: title as NSString)
                let dragItem = UIDragItem(itemProvider: itemProvider)
                dragItem.localObject = item
                return [dragItem]
            }
        } else {
            return []
        }
    }
    
    func collectionView(_ collectionView: UICollectionView, dragPreviewParametersForItemAt indexPath: IndexPath) -> UIDragPreviewParameters? {
        guard let cell = collectionView.cellForItem(at: indexPath) else {
            return nil
        }
        let previewParameters = UIDragPreviewParameters()
        previewParameters.visiblePath = UIBezierPath(rect: cell.bounds)
        previewParameters.backgroundColor = .clear
        previewParameters.shadowPath = UIBezierPath(rect: .zero)
        return previewParameters
    }
}

extension MainViewController: UICollectionViewDropDelegate {
    func collectionView(_ collectionView: UICollectionView, performDropWith coordinator: UICollectionViewDropCoordinator) {
        guard let destinationIndexPath = coordinator.destinationIndexPath else {
            return
        }
        switch coordinator.proposal.operation {
        case .cancel:
            break
        case .forbidden:
            break
        case .copy:
            break
        case .move:
            if let item = coordinator.items.first, let cellItem = item.dragItem.localObject as? Item {
                guard let sourceIndexPath = item.sourceIndexPath, sourceIndexPath != destinationIndexPath else { return }
                
                guard let sourceSection = dataSource.sectionIdentifier(for: sourceIndexPath.section) else { return }
                guard let destinationSection = dataSource.sectionIdentifier(for: destinationIndexPath.section) else { return }
                
                let pinnedPostDetails = DataManager.shared.fetchAllPostDetails(isPinned: true)
                let otherPostDetails = DataManager.shared.fetchAllPostDetails(isPinned: false)
                
                var snapshot = dataSource.snapshot()
                snapshot.deleteItems([cellItem])
                
                if snapshot.itemIdentifiers(inSection: .others).count == 0 {
                    snapshot.appendItems([.blank(.others)], toSection: .others)
                }
                if snapshot.itemIdentifiers(inSection: .pinned).count == 0 {
                    snapshot.appendItems([.blank(.pinned)], toSection: .pinned)
                }
                
                if let destination = dataSource.itemIdentifier(for: destinationIndexPath) {
                    if sourceSection == destinationSection {
                        // Same Section, no need update pinned state
                        if sourceIndexPath.item < destinationIndexPath.item {
                            snapshot.insertItems([cellItem], afterItem: destination)
                        } else {
                            snapshot.insertItems([cellItem], beforeItem: destination)
                        }
                    } else {
                        // Different Section
                        switch destinationSection {
                        case .pinned:
                            if pinnedPostDetails.count == 0 {
                                snapshot.deleteItems([.blank(destinationSection)])
                                snapshot.appendItems([cellItem], toSection: destinationSection)
                            } else {
                                snapshot.insertItems([cellItem], beforeItem: destination)
                            }
                        case .others:
                            if otherPostDetails.count == 0 {
                                snapshot.deleteItems([.blank(destinationSection)])
                                snapshot.appendItems([cellItem], toSection: destinationSection)
                            } else {
                                snapshot.insertItems([cellItem], beforeItem: destination)
                            }
                        }
                    }
                } else {
                    // Move to different empty section, or unempty section bottom
                    switch destinationSection {
                    case .pinned:
                        if pinnedPostDetails.count == 0 {
                            snapshot.deleteItems([.blank(destinationSection)])
                        }
                    case .others:
                        if otherPostDetails.count == 0 {
                            snapshot.deleteItems([.blank(destinationSection)])
                        }
                    }
                    snapshot.appendItems([cellItem], toSection: destinationSection)
                }
                dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
                    self?.updatePostsOrder(by: snapshot)
                }
            }
        @unknown default:
            fatalError()
        }
    }
    
    func collectionView(_ collectionView: UICollectionView, dropSessionDidUpdate session: UIDropSession, withDestinationIndexPath destinationIndexPath: IndexPath?) -> UICollectionViewDropProposal {
        if session.localDragSession != nil {
            if collectionView.hasActiveDrag {
                return UICollectionViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
            } else {
                return UICollectionViewDropProposal(operation: .cancel)
            }
        } else {
            return UICollectionViewDropProposal(operation: .forbidden)
        }
    }
}

extension MainViewController: PostCellDelegate {
    func getMoreButtonMenu(for post: Post.Detail) -> UIMenu {
        var elements: [UIMenuElement] = []
        
        if let postImage = post.images.first {
            let cropAction = UIAction(title: String(localized: "image.action.fastCrop"), image: UIImage(systemName: "crop")) { [weak self] _ in
                self?.enterFastCropEditor(for: postImage)
            }
            
            let currentPageDivider = UIMenu(title: "", image: nil, options: [.displayInline], children: [cropAction])
            
            elements.append(currentPageDivider)
        }
        
        let editAction = UIAction(title: String(localized: "pin.edit"), image: UIImage(systemName: "pencil")) { [weak self] _ in
            self?.edit(post: post)
        }
        
        elements.append(editAction)
        
        if post.texts.first != nil {
            let copyAction = UIAction(title: String(localized: "pin.copy"), image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in
                self?.copyText(from: post)
            }
            
            elements.append(copyAction)
        }
        
        if post.images.first != nil {
            let copyOriginalAction = UIAction(title: String(localized: "pin.copy.original"), image: UIImage(systemName: "photo")) { [weak self] _ in
                self?.copyImage(from: post, isOriginal: true)
            }
            
            let copyProcessedAction = UIAction(title: String(localized: "pin.copy.processed"), image: UIImage(systemName: "photo.circle")) { [weak self] _ in
                self?.copyImage(from: post, isOriginal: false)
            }
            
            let currentPageDivider = UIMenu(title: String(localized: "pin.copy"), image: UIImage(systemName: "doc.on.clipboard"), options: [], children: [copyOriginalAction, copyProcessedAction])
            
            elements.append(currentPageDivider)
        }
        
        let deleteAction = UIAction(title: String(localized: "pin.delete"), image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
            self?.deleteAction(for: post)
        }
        let currentPageDivider = UIMenu(title: "", options: .displayInline, children: [deleteAction])
        elements.append(currentPageDivider)
        
        return UIMenu(title: String(format: String(localized: "post.create%@"), post.post.createText), children: elements)
    }
    
    func update(post: Post, isPinned: Bool) {
        _ = DataManager.shared.update(post: post, isPinned: isPinned  )
    }
    
    func tap(for post: Post.Detail) {
        switch post.detailType {
        case .text:
            enterTextDetail(for: post)
        case .image:
            enterImageDetail(for: post)
        }
    }
    
    public func viewDetail(for id: Int64) {
        guard let detail = DataManager.shared.fetchPostDetail(for: [id]).first else { return }
        
        navigationController?.dismiss(animated: false)
        
        enterImageDetail(for: detail)
    }
    
    func getStyleButtonMenu(for post: Post.Detail) -> UIMenu {
        var elements: [UIMenuElement] = []
        
        let defaultStyleAction = UIAction(title: PostStyle.noneTitle, state: post.style == nil ? .on : .off) { _ in
            _ = DataManager.shared.update(post: post.post, styleId: nil)
        }
        elements.append(defaultStyleAction)
        
        let styles = DataManager.shared.fetchAllStyles()
        
        let styleActions = styles.map({ style in
            let action = UIAction(title: style.name, state: post.style == style ? .on : .off) {  _ in
                _ = DataManager.shared.update(post: post.post, styleId: style.id)
            }
            return action
        })
        let currentPageDivider = UIMenu(title: "", options: .displayInline, children: styleActions)

        elements.append(currentPageDivider)
        
        return UIMenu(title: "", children: elements)
    }
}

extension MainViewController {
    func enterTextDetail(for detail: Post.Detail) {
        guard let text = detail.texts.first else { return }
        navigationController?.dismiss(animated: ConsideringUser.animated)
        
        let textDetail = TextDetailViewController(textInfo: text)
        textDetail.editClosure = { [weak self] _ in
            self?.edit(post: detail)
        }
        
        navigationController?.present(UINavigationController(rootViewController: textDetail), animated: ConsideringUser.animated)
    }
    
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
        browser.reloadCellAtIndex = { [weak self] context in
            guard let self = self else { return }
            let browserCell = context.cell as? JXPhotoBrowserImageCell
            if context.index == 0 {
                browserCell?.imageView.image = displayImage
            } else {
                browserCell?.imageView.image = originalImage
            }
            browserCell?.longPressedAction = { [weak self] cell, _ in
                self?.longPress(for: cell, detail: detail)
            }
        }
        browser.pageIndex = 0
        browser.show(method: .present(fromVC: self.navigationController, embed: nil))
    }
    
    func enterFastCropEditor(for postImage: PostImage) {
        if let image = postImage.getOriginalImage() {
            handle(image, postImage: postImage)
        }
    }
    
    func longPress(for cell: JXPhotoBrowserImageCell, detail: Post.Detail) {
        guard let image = detail.images.first else { return }
        
        let alertController = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        let cropAction = UIAlertAction(title: String(localized: "image.action.fastCrop"), style: .default) { [weak self] _ in
            alertController.dismiss(animated: ConsideringUser.animated)
            cell.photoBrowser?.dismiss(animated: ConsideringUser.animated) {
                self?.enterFastCropEditor(for: image)
            }
        }
        let copyProcessedAction = UIAlertAction(title: String(localized: "image.action.copyProcessed"), style: .default) { [weak self] _ in
            alertController.dismiss(animated: ConsideringUser.animated)
            cell.photoBrowser?.dismiss(animated: ConsideringUser.animated) {
                self?.copyImage(from: detail, isOriginal: false)
            }
        }
        let copyOriginalAction = UIAlertAction(title: String(localized: "image.action.copyOriginal"), style: .default) { [weak self] _ in
            alertController.dismiss(animated: ConsideringUser.animated)
            cell.photoBrowser?.dismiss(animated: ConsideringUser.animated) {
                self?.copyImage(from: detail, isOriginal: true)
            }
        }
        let editPostAction = UIAlertAction(title: String(localized: "image.action.editPost"), style: .default) { [weak self] _ in
            alertController.dismiss(animated: ConsideringUser.animated)
            cell.photoBrowser?.dismiss(animated: ConsideringUser.animated) {
                self?.edit(post: detail)
            }
        }
        let deleteAction = UIAlertAction(title: String(localized: "image.action.deletePost"), style: .destructive) { [weak self] _ in
            alertController.dismiss(animated: ConsideringUser.animated)
            cell.photoBrowser?.dismiss(animated: ConsideringUser.animated) {
                self?.deleteAction(for: detail)
            }
        }
        alertController.addAction(cropAction)
        alertController.addAction(copyOriginalAction)
        alertController.addAction(copyProcessedAction)
        alertController.addAction(editPostAction)
        alertController.addAction(deleteAction)

        if let popoverController = alertController.popoverPresentationController {
            popoverController.sourceView = cell.photoBrowser?.browserView
            popoverController.sourceRect = cell.photoBrowser?.browserView.frame ?? .zero
        }
        
        cell.photoBrowser?.present(alertController, animated: ConsideringUser.animated, completion: nil)
    }
}

extension MainViewController {
    func edit(post: Post.Detail) {
        let editorViewController = EditorViewController(postDetail: post) { detail in
            for text in detail.texts {
                _ = DataManager.shared.update(text: text)
            }
            for image in detail.images {
                _ = DataManager.shared.update(image: image)
            }
            if let style = detail.style {
                _ = DataManager.shared.update(post: detail.post, styleId: style.id)
            }
            _ = DataManager.shared.update(post: detail.post)
        }
        
        navigationController?.present(UINavigationController(rootViewController: editorViewController), animated: ConsideringUser.animated)
    }
    
    func deleteAction(for post: Post.Detail) {
        switch DeleteOperationConfirmation.current {
        case .enable:
            showDeleteAlert(for: post)
        case .disable, .disableUntilAppBackgrounds:
            delete(post: post.post)
        }
    }
    
    func showDeleteAlert(for post: Post.Detail) {
        let alertController = UIAlertController(title: String(localized: "pin.delete.alert.title"), message: nil, preferredStyle: .alert)
        let deleteAction = UIAlertAction(title: String(localized: "button.delete"), style: .destructive) { [weak self] _ in
            alertController.dismiss(animated: ConsideringUser.animated)
            self?.delete(post: post.post)
        }
        let cancelAction = UIAlertAction(title: String(localized: "button.cancel"), style: .cancel)
        alertController.addAction(deleteAction)
        alertController.addAction(cancelAction)
        present(alertController, animated: ConsideringUser.animated)
    }
    
    func delete(post: Post) {
        _ = DataManager.shared.delete(post: post)
    }
    
    func showDeleteAllUnpinsAlert() {
        let alertController = UIAlertController(title: String(localized: "pin.delete.allUnpins.alert.title"), message: nil, preferredStyle: .alert)
        let deleteAction = UIAlertAction(title: String(localized: "button.delete"), style: .destructive) { _ in
            alertController.dismiss(animated: ConsideringUser.animated)
            _ = DataManager.shared.deleteAllUnpins()
        }
        let cancelAction = UIAlertAction(title: String(localized: "button.cancel"), style: .cancel)
        alertController.addAction(deleteAction)
        alertController.addAction(cancelAction)
        present(alertController, animated: ConsideringUser.animated)
    }
    
    func copyText(from postDetail: Post.Detail) {
        guard let first = postDetail.texts.first?.content else { return }
        UIPasteboard.general.string = first
    }
    
    func copyImage(from postDetail: Post.Detail, isOriginal: Bool) {
        guard let postImage = postDetail.images.first else { return }
        guard let originalImage = ImageCacheManager.shared.retrieveImage(fileName: postImage.original, type: .original) else { return }

        if isOriginal {
            UIPasteboard.general.image = originalImage
        } else {
            // Need Calculator
            if postImage.rect == .zero {
                UIPasteboard.general.image = originalImage
            } else {
                if let rotateImage = originalImage.rotatedByDegrees(Int(postImage.orientation)), let processedImage = ImageCropper.cropImage(rotateImage, to: postImage.rect) {
                    UIPasteboard.general.image = processedImage
                }
            }
        }
    }
}

extension MainViewController {
    func updatePostsOrder(by snapshot: NSDiffableDataSourceSnapshot<Section, Item>) {
        let pinnedItems = snapshot.itemIdentifiers(inSection: .pinned).compactMap{ $0.post }
        let othersItems = snapshot.itemIdentifiers(inSection: .others).compactMap{ $0.post }
        
        let posts = findRequiredUpdates(pinnedPosts: pinnedItems, unpinnedPosts: othersItems)
        
        _ = DataManager.shared.update(posts: posts)
    }
    
    func findRequiredUpdates(pinnedPosts: [Post], unpinnedPosts: [Post]) -> [Post] {
        var updates: [Post] = []
        
        for var pinnedPost in pinnedPosts {
            if pinnedPost.isPinned == false {
                pinnedPost.isPinned = true
                updates.append(pinnedPost)
            }
        }
        
        for var unpinnedPost in unpinnedPosts {
            if unpinnedPost.isPinned == true {
                unpinnedPost.isPinned = false
                updates.append(unpinnedPost)
            }
        }
        
        for (index, var post) in pinnedPosts.enumerated() {
            let newOrder = pinnedPosts.count - index - 1
            if post.order != newOrder {
                if let existingIndex = updates.firstIndex(where: { $0.id == post.id }) {
                    post = updates[existingIndex]
                    post.order = Int64(newOrder)
                    updates[existingIndex] = post
                } else {
                    post.order = Int64(newOrder)
                    updates.append(post)
                }
            }
        }
        
        for (index, var post) in unpinnedPosts.enumerated() {
            let newOrder = unpinnedPosts.count - index - 1
            if post.order != newOrder {
                if let existingIndex = updates.firstIndex(where: { $0.id == post.id }) {
                    post = updates[existingIndex]
                    post.order = Int64(newOrder)
                    updates[existingIndex] = post
                } else {
                    post.order = Int64(newOrder)
                    updates.append(post)
                }
            }
        }
        
        return updates
    }
}

extension MainViewController {
    func showPasteboardAlert() {
        let alertController = UIAlertController(title: String(localized: "pin.pasteboard.alert.title"), message: String(localized: "pin.pasteboard.alert.message"), preferredStyle: .alert)
        
        let checkAction = UIAlertAction(title: String(localized: "pin.pasteboard.alert.action"), style: .default) { [weak self] _ in
            self?.jumpToSettings()
        }
        
        let cancelAction = UIAlertAction(title: String(localized: "button.cancel"), style: .cancel)
        
        alertController.addAction(checkAction)
        alertController.addAction(cancelAction)

        present(alertController, animated: ConsideringUser.animated, completion: nil)
    }
    
    func jumpToSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else {
            return
        }
        if UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url, options: [:])
        }
    }
}

extension MainViewController {
    func showEditor(with text: String) {
        navigationController?.dismiss(animated: ConsideringUser.animated)
        addAction(text: text)
    }
    
    func showEditor(with image: UIImage) {
        navigationController?.dismiss(animated: ConsideringUser.animated)
        handle(image, postImage: nil)
    }
}

extension MainViewController {
    func pickImage() {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 1
        
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        present(picker, animated: ConsideringUser.animated)
    }
    
    func handle(_ image: UIImage, postImage: PostImage?) {
        currentImage = image
        currentPostImage = postImage
        
        let cropController = CropViewController(croppingStyle: .default, image: image)
        cropController.delegate = self
        cropController.title = String(localized: "editor.image.crop")
        if let rect = postImage?.rect {
            cropController.imageCropFrame = rect
        }
        
        let nav = UINavigationController(rootViewController: cropController)
        
        present(nav, animated: ConsideringUser.animated, completion: nil)
    }
}

extension MainViewController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: ConsideringUser.animated)
        
        guard let result = results.first else { return }
        
        result.itemProvider.loadObject(ofClass: UIImage.self) { [weak self] object, error in
            if let image = object as? UIImage {
                DispatchQueue.main.async {
                    self?.handle(image, postImage: nil)
                }
            } else {
                if error != nil {
                    print(error ?? "")
                }
            }
        }
    }
}

extension MainViewController: CropViewControllerDelegate {
    func cropViewController(_ cropViewController: CropViewController, didCropToImage image: UIImage, withRect cropRect: CGRect, angle: Int) {
        defer {
            currentImage = nil
            currentPostImage = nil
            
            cropViewController.dismiss(animated: ConsideringUser.animated)
        }
        
        let resizedImage = image.resizeImageIfNeeded(maxWidth: 320 * 3, maxHeight: 160 * 3)
        
        if var postImage = currentPostImage {
            _ = ImageCacheManager.shared.deleteImage(fileName: postImage.processed, type: .processed)
            if let processed = ImageCacheManager.shared.storeImage(resizedImage, type: .processed) {
                postImage.processed = processed
                postImage.orientation = Int64(angle)
                postImage.minX = Int64(cropRect.minX)
                postImage.minY = Int64(cropRect.minY)
                postImage.maxX = Int64(cropRect.maxX)
                postImage.maxY = Int64(cropRect.maxY)
                _ = DataManager.shared.update(image: postImage)
            }
        } else {
            if let currentImage = currentImage, let original = ImageCacheManager.shared.storeImage(currentImage, type: .original), let processed = ImageCacheManager.shared.storeImage(resizedImage, type: .processed) {
                _ = DataManager.shared.createPost(original: original, processed: processed, rect: cropRect, orientation: angle, expirationTime: Post.getDefaultExpirationTime(), styleId: nil)
            }
        }
    }
    
    func cropViewController(_ cropViewController: CropViewController, didFinishCancelled cancelled: Bool) {
        currentImage = nil
        
        cropViewController.dismiss(animated: ConsideringUser.animated)
    }
}

extension MainViewController {
    func scrollToPost(by id: Int64) {
        let item = dataSource.snapshot().itemIdentifiers.first { item in
            switch item {
            case .blank:
                return false
            case .post(let detail):
                return detail.post.id == id
            }
        }
        if let item = item, let indexPath = dataSource.indexPath(for: item) {
            collectionView.scrollToItem(at: indexPath, at: .top, animated: true)
        }
    }
}

extension UICollectionViewDiffableDataSource where SectionIdentifierType: Hashable, ItemIdentifierType: Hashable {
    func findAllIndexPaths(where predicate: (ItemIdentifierType) -> Bool) -> [IndexPath] {
        let snapshot = snapshot()
        var results: [IndexPath] = []
        
        for (sectionIndex, section) in snapshot.sectionIdentifiers.enumerated() {
            let items = snapshot.itemIdentifiers(inSection: section)
            for (itemIndex, item) in items.enumerated() {
                if predicate(item) {
                    results.append(IndexPath(item: itemIndex, section: sectionIndex))
                }
            }
        }
        
        return results
    }
    
    func findFirstIndexPath(where predicate: (ItemIdentifierType) -> Bool) -> IndexPath? {
        let snapshot = snapshot()
        
        for (sectionIndex, section) in snapshot.sectionIdentifiers.enumerated() {
            let items = snapshot.itemIdentifiers(inSection: section)
            if let itemIndex = items.firstIndex(where: predicate) {
                return IndexPath(item: itemIndex, section: sectionIndex)
            }
        }
        
        return nil
    }
}
