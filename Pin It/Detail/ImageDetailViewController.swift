//
//  ImageDetailViewController.swift
//  Pin It
//
//  Created by Ci Zi on 2025/11/8.
//

import Foundation
import UIKit
import Kingfisher

class ImageDetailViewController: UIViewController {
    private var imageInfo: PostImage!
    private var image: UIImage? {
        didSet {
            setupDetailUI()
        }
    }
    
    convenience init(imageInfo: PostImage) {
        self.init(nibName: nil, bundle: nil)
        self.imageInfo = imageInfo
    }
    
    var editClosure: ((PostImage) -> ())?
    
    enum Section: Hashable {
        case image
        case data
    }
    
    enum Item: Hashable {
        case image
        case title(String)
    }
    
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>! = nil
    private var collectionView: UICollectionView! = nil
    private var moonTitle: String?
    
    private var editButton: UIBarButtonItem?
    private var closeButton: UIBarButtonItem?

    deinit {
        print("ImageDetailViewController is deinited.")
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
        
        DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 0.1) {
            self.loadImage()
        }
    }
    
    func configureHierarchy() {
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: createLayout())
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        view.addSubview(collectionView)
        collectionView.snp.makeConstraints { make in
            make.edges.equalTo(view)
        }
    }
    
    func configureDataSource() {
        let imageCellRegistration = UICollectionView.CellRegistration<ImageDetailCell, Item> { [weak self] (cell, indexPath, item) in
            guard let self = self else { return }
            cell.update(with: self.imageInfo)
        }
        let dataCellRegistration = UICollectionView.CellRegistration<TitleAndDateCell, Item> { [weak self] (cell, indexPath, item) in
            guard let self = self else { return }
            switch item {
            case .image:
                break
            case .title(let moonTitle):
                cell.moonTitle = moonTitle
            }
            cell.update(with: self.imageInfo)
        }
        
        dataSource = UICollectionViewDiffableDataSource<Section, Item>(collectionView: collectionView) { (collectionView, indexPath, itemIdentifier) -> UICollectionViewCell? in
            switch itemIdentifier {
            case .image:
                return collectionView.dequeueConfiguredReusableCell(using: imageCellRegistration, for: indexPath, item: itemIdentifier)
            case .title:
                return collectionView.dequeueConfiguredReusableCell(using: dataCellRegistration, for: indexPath, item: itemIdentifier)
            }
        }
    }
    
    func loadImage() {
        image = ImageCacheManager.shared.retrieveImage(fileName: imageInfo.original, type: .original)
    }
    
    func setupDetailUI() {
        configureHierarchy()
        configureDataSource()
        reloadData()
    }
    
    func reloadData() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.image])
        snapshot.appendItems([.image], toSection: .image)
        if let moonTitle = moonTitle {
            snapshot.appendSections([.data])
            snapshot.appendItems([.title(moonTitle)], toSection: .data)
        }
        
        dataSource.apply(snapshot, animatingDifferences: true)
    }
    
    @objc
    func editAction() {
        dismiss(animated: ConsideringUser.animated)
        
        editClosure?(imageInfo)
    }
    
    @objc
    func closeAction() {
        dismiss(animated: ConsideringUser.animated)
    }
}

extension ImageDetailViewController {
    func createLayout() -> UICollectionViewLayout {
        let sectionProvider = { [weak self] (sectionIndex: Int, layoutEnvironment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection? in
            guard let self = self else { return nil }
            guard let section = self.dataSource.sectionIdentifier(for: sectionIndex) else { return nil }

            switch section {
            case .image:
                return self.getImageSection(layoutEnvironment)
            case .data:
                return self.getDataSection(layoutEnvironment)
            }
        }

        let config = UICollectionViewCompositionalLayoutConfiguration()
        config.interSectionSpacing = 20

        let layout = UICollectionViewCompositionalLayout(sectionProvider: sectionProvider, configuration: config)
        return layout
    }
    
    func getImageSection(_ layoutEnvironment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection {
        let itemSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0),
                                              heightDimension: .fractionalHeight(1.0))
        let item = NSCollectionLayoutItem(layoutSize: itemSize)

        let width = layoutEnvironment.container.effectiveContentSize.width
        let height = floor(width / CGFloat(image!.size.width) * CGFloat(image!.size.height))
        let groupSize = NSCollectionLayoutSize(widthDimension: .absolute(width),
                                              heightDimension: .absolute(height))
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item])

        let layoutSection = NSCollectionLayoutSection(group: group)
        layoutSection.contentInsets = .zero
        
        return layoutSection
    }
    
    func getDataSection(_ layoutEnvironment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection {
        let itemSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0),
                                              heightDimension: .estimated(100))
        let item = NSCollectionLayoutItem(layoutSize: itemSize)

        let groupSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0),
                                               heightDimension: .estimated(100))
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item])

        let layoutSection = NSCollectionLayoutSection(group: group)
        layoutSection.contentInsets = .zero
        
        return layoutSection
    }
}

extension ImageDetailViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didDeselectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
    }
}
