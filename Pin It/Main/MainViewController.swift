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
    private var dataSource: UICollectionViewDiffableDataSource<Section, Post.Detail>!
    
    enum Section: Hashable, Sendable {
        case main
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
        let sectionProvider = { (sectionIndex: Int, layoutEnvironment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection? in
            var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
            configuration.separatorConfiguration = UIListSeparatorConfiguration(listAppearance: .insetGrouped)
            configuration.backgroundColor = AppColor.background
            let section = NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: layoutEnvironment)
            
            return section
        }
        return UICollectionViewCompositionalLayout(sectionProvider: sectionProvider)
    }
    
    func configureHierarchy() {
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: createLayout())
        collectionView.delegate = self
        view.addSubview(collectionView)
        collectionView.snp.makeConstraints { make in
            make.edges.equalTo(view)
        }
    }
    
    func configureDataSource() {
        let normalCellRegistration = createNormalCellRegistration()
        
        dataSource = UICollectionViewDiffableDataSource<Section, Post.Detail>(collectionView: collectionView, cellProvider: { collectionView, indexPath, itemIdentifier in
            return collectionView.dequeueConfiguredReusableCell(using: normalCellRegistration, for: indexPath, item: itemIdentifier)
        })
    }
    
    func createNormalCellRegistration() -> UICollectionView.CellRegistration<UICollectionViewListCell, Post.Detail> {
        return UICollectionView.CellRegistration<UICollectionViewListCell, Post.Detail> { (cell, indexPath, item) in
            var content = UIListContentConfiguration.subtitleCell()
            content.text = item.title
            content.secondaryText = item.texts.first?.content ?? ""
            content.textToSecondaryTextVerticalPadding = 6.0
            content.secondaryTextProperties.color = AppColor.text.withAlphaComponent(0.75)
            var layoutMargins = content.directionalLayoutMargins
            layoutMargins.leading = 10.0
            layoutMargins.top = 10.0
            layoutMargins.bottom = 10.0
            content.directionalLayoutMargins = layoutMargins
            cell.contentConfiguration = content
        }
    }
    
    @objc
    func reloadData() {
        let postDetails = DataManager.shared.fetchAllPostDetails()
        var snapshot = NSDiffableDataSourceSnapshot<Section, Post.Detail>()
        snapshot.appendSections([.main])
        snapshot.appendItems(postDetails)
        
        dataSource.apply(snapshot, animatingDifferences: true)
    }
}

extension MainViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
    }
}
