//
//  MainViewController.swift
//  Pin It
//
//  Created by Ci Zi on 2025/10/13.
//

import UIKit
import SnapKit

class MainViewController: UIViewController {
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    
    static let sectionHeaderElementKind = "sectionHeaderElementKind"
    
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
    }
    
    private var addButton: UIBarButtonItem?
    
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
        self.title = String(localized: "controller.pin.title")
        
        let addButton = UIBarButtonItem(image: UIImage(systemName: "plus"), style: .plain, target: self, action: #selector(addAction))
        addButton.tintColor = .systemRed
        self.navigationItem.rightBarButtonItem = addButton
        self.addButton = addButton
        
        configureHierarchy()
        configureDataSource()
        reloadData()
        
        NotificationCenter.default.addObserver(self, selector: #selector(reloadData), name: .DatabaseUpdated, object: nil)
    }
    
    @objc
    func addAction() {
        let editorViewController = EditorViewController(postText: PostText(postId: -1, content: "", order: 0)) { postText in
            let result = DataManager.shared.createPost(content: postText.content)
            print(result)
            if result {
                
            } else {
                
            }
        }
        
        navigationController?.present(UINavigationController(rootViewController: editorViewController), animated: ConsideringUser.animated)
    }
    
    func createLayout() -> UICollectionViewLayout {
        let config = UICollectionViewCompositionalLayoutConfiguration()
        config.scrollDirection = .vertical
        
        let layout = UICollectionViewCompositionalLayout(sectionProvider: { index, environment in
            let itemSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0),
                                                 heightDimension: .estimated(100))
            let item = NSCollectionLayoutItem(layoutSize: itemSize)

            let groupSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0),
                                                  heightDimension: .estimated(100))
            let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize,
                                                             subitems: [item])

            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = 20.0
            section.contentInsets = NSDirectionalEdgeInsets(top: 10.0, leading: 16.0, bottom: 20.0, trailing: 16.0)
            
            let headerSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0),
                                                         heightDimension: .estimated(100))
            let sectionHeader = NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: headerSize,
                elementKind: Self.sectionHeaderElementKind, alignment: .top)
            section.boundarySupplementaryItems = [sectionHeader]
            
            return section
        }, configuration: config)
        
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
        
        dataSource.apply(snapshot, animatingDifferences: true)
    }
}

extension MainViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
    }
}

extension MainViewController: PostCellDelegate {
    func getMoreButtonMenu(for post: Post.Detail) -> UIMenu {
        var elements: [UIMenuElement] = []
        let editAction = UIAction(title: String(localized: "pin.edit"), image: UIImage(systemName: "pencil")) { [weak self] _ in
            self?.edit(post: post)
        }
        elements.append(editAction)
        let deleteAction = UIAction(title: String(localized: "pin.delete"), image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
            self?.showDeleteAlert(for: post)
        }
        let currentPageDivider = UIMenu(title: "", options: .displayInline, children: [deleteAction])
        elements.append(currentPageDivider)
        
        return UIMenu(children: elements)
    }
    
    func update(post: Post, isPinned: Bool) {
        _ = DataManager.shared.update(post: post, isPinned: isPinned  )
    }
}

extension MainViewController {
    func edit(post: Post.Detail) {
        guard let postText = post.texts.first else { return }
        let editorViewController = EditorViewController(postText: postText) { postText in
            let result = DataManager.shared.update(text: postText)
            print(result)
            if result {
                
            } else {
                
            }
        }
        
        navigationController?.present(UINavigationController(rootViewController: editorViewController), animated: ConsideringUser.animated)
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
}
