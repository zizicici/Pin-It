//
//  StyleViewController.swift
//  Pin It
//
//  Created by Ci Zi on 2025/11/24.
//

import UIKit
import SnapKit
import MoreKit

// MARK: - 样式编辑器委托
protocol StyleEditorDelegate: AnyObject {
    func styleEditor(_ editor: StyleViewController, didUpdateStyle style: PostStyle)
}

// MARK: - 颜色配置管理器
class ColorConfigurationManager {
    private(set) var configurations: [ColorConfiguration] = []
    
    func addConfiguration(_ configuration: ColorConfiguration) {
        configurations.append(configuration)
    }
    
    func configuration(for type: ColorConfiguration.ColorType) -> ColorConfiguration? {
        return configurations.first { $0.type == type }
    }
}

// MARK: - 颜色配置模型
class ColorConfiguration {
    enum ColorType: Hashable, CaseIterable {
        case lockBackground
        case lockText
        case islandText
        case symbol
        
        var title: String {
            switch self {
            case .lockBackground:
                return String(localized: "style.lockBackgroundColor")
            case .lockText:
                return String(localized: "style.lockTextColor")
            case .islandText:
                return String(localized: "style.islandTextColor")
            case .symbol:
                return String(localized: "style.symbolColor")
            }
        }
        
        var defaultLightColor: UIColor {
            switch self {
            case .lockBackground:
                return AppColor.paper
            case .lockText:
                return AppColor.text
            case .islandText:
                return .white
            case .symbol:
                return .systemRed
            }
        }
        
        var defaultDarkColor: UIColor {
            switch self {
            case .lockBackground:
                return AppColor.paper
            case .lockText:
                return AppColor.text
            case .islandText:
                return .white
            case .symbol:
                return .systemRed
            }
        }
        
        var styleColorKeyPath: WritableKeyPath<PostStyle, String?> {
            switch self {
            case .lockBackground:
                return \.lockBackgroundColor
            case .lockText:
                return \.lockTextColor
            case .islandText:
                return \.islandTextColor
            case .symbol:
                return \.symbolColor
            }
        }
    }
    
    let type: ColorType
    var isEnabled: Bool
    var lightColor: UIColor
    var darkColor: UIColor
    var customColors: [UIColor] = []
    
    init(type: ColorType, style: PostStyle) {
        self.type = type
        
        // 从样式数据初始化状态和颜色
        let colorString = style[keyPath: type.styleColorKeyPath]
        self.isEnabled = colorString != nil
        
        if let colorString = colorString, let color = UIColor(string: colorString) {
            self.lightColor = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
            self.darkColor = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        } else {
            // 使用默认颜色
            self.lightColor = type.defaultLightColor
            self.darkColor = type.defaultDarkColor
        }
    }
    
    var resolvedColor: UIColor {
        return UIColor { traitCollection in
            switch traitCollection.userInterfaceStyle {
            case .light, .unspecified:
                return self.lightColor
            case .dark:
                return self.darkColor
            @unknown default:
                return self.lightColor
            }
        }
    }
    
    func updateLightColor(_ color: UIColor) {
        lightColor = color
    }
    
    func updateDarkColor(_ color: UIColor) {
        darkColor = color
    }
    
    func resetToDefaultColors() {
        lightColor = type.defaultLightColor
        darkColor = type.defaultDarkColor
    }
    
    func updateStyle(_ style: inout PostStyle) {
        if isEnabled {
            let colorString = resolvedColor.generateLightDarkString()
            style[keyPath: type.styleColorKeyPath] = colorString
        } else {
            style[keyPath: type.styleColorKeyPath] = nil
        }
    }
}

// MARK: - 颜色配置 Section 管理
struct ColorConfigurationSection {
    let section: StyleViewController.Section
    let configurations: [ColorConfiguration.ColorType]
    
    static let lockScreenSection = ColorConfigurationSection(
        section: .lockScreen,
        configurations: [.lockBackground, .lockText]
    )
    
    static let islandSection = ColorConfigurationSection(
        section: .island,
        configurations: [.islandText]
    )
    
    static let symbolSection = ColorConfigurationSection(
        section: .symbol,
        configurations: [.symbol]
    )
}

// MARK: - 主视图控制器
class StyleViewController: UIViewController {
    private var style: PostStyle!
    private var colorManager = ColorConfigurationManager()
    private let lockScreenSectionManager = ColorConfigurationSection.lockScreenSection
    private let islandSectionManager = ColorConfigurationSection.islandSection
    private let iconSectionManager = ColorConfigurationSection.symbolSection
    weak var delegate: StyleEditorDelegate?
    
    private var tableView: UITableView!
    private var dataSource: DataSource!
    
    private var isEdited: Bool = true
    private var saveBarButton: UIBarButtonItem?
    private weak var nameCell: TextInputCell?
    
    private var colorConfigurationCells: [ColorConfiguration.ColorType: (lightCell: ColorPickerCell?, darkCell: ColorPickerCell?)] = [:]
    private var colorToggleDebounces: [ColorConfiguration.ColorType: Debounce<Bool>] = [:]
    
    private var styleName: String {
        get { return style.name }
        set {
            if style.name != newValue {
                style.name = newValue
                markAsEdited()
            }
        }
    }
    
    private var lockTextSize: PostTextSize {
        get { return style.lockTextSize }
        set {
            if style.lockTextSize != newValue {
                style.lockTextSize = newValue
                markAsEdited()
                reloadData()
            }
        }
    }
    
    private var islandTextSize: PostTextSize {
        get { return style.islandTextSize }
        set {
            if style.islandTextSize != newValue {
                style.islandTextSize = newValue
                markAsEdited()
                reloadData()
            }
        }
    }
    
    private var lockTextAlignment: PostTextAlignment {
        get { return style.lockTextAlignment }
        set {
            if style.lockTextAlignment != newValue {
                style.lockTextAlignment = newValue
                markAsEdited()
                reloadData()
            }
        }
    }
    
    private var islandTextAlignment: PostTextAlignment {
        get { return style.islandTextAlignment }
        set {
            if style.islandTextAlignment != newValue {
                style.islandTextAlignment = newValue
                markAsEdited()
                reloadData()
            }
        }
    }
    
    private var symbol: String {
        get { return style.symbol }
        set {
            if style.symbol != newValue {
                style.symbol = newValue
                markAsEdited()
                reloadData()
            }
        }
    }
    
    private var symbolAngle: Int {
        get { return style.symbolAngle }
        set {
            if style.symbolAngle != newValue {
                style.symbolAngle = newValue
                markAsEdited()
                reloadData()
            }
        }
    }
    
    private var imageDisplayMode: PostImageDisplayMode {
        get { return style.imageDisplayMode }
        set {
            if style.imageDisplayMode != newValue {
                style.imageDisplayMode = newValue
                markAsEdited()
                reloadData()
            }
        }
    }
    
    private var controlDisplayMode: PostControlDisplayMode {
        get {
            if style.controlAlpha != 0 {
                return .normal
            } else {
                return .transparent
            }
        }
        set {
            style.controlAlpha = newValue.rawValue
            markAsEdited()
            reloadData()
        }
    }
    
    // MARK: - Section 定义
    enum Section: Int, Hashable {
        case name
        case lockScreen
        case island
        case symbol
        case others
        case action
        
        var header: String? {
            switch self {
            case .name:
                return String(localized: "style.name")
            case .lockScreen:
                return String(localized: "style.lockScreen")
            case .island:
                return String(localized: "style.island")
            case .symbol:
                return String(localized: "style.symbol")
            case .others:
                return String(localized: "style.others")
            case .action:
                return nil
            }
        }
        
        var footer: String? {
            return nil
        }
    }
    
    // MARK: - Item 定义
    enum Item: Hashable {
        case name(String?)
        case colorToggle(ColorConfiguration.ColorType, Bool)
        case colorLight(ColorConfiguration.ColorType, ColorPickerItem)
        case colorDark(ColorConfiguration.ColorType, ColorPickerItem)
        case textSize(Section, PostTextSize)
        case textAlignment(Section, PostTextAlignment)
        case symbol(String, UIColor)
        case symbolAngle(Int)
        case imageDisplayMode(PostImageDisplayMode)
        case controlDisplayMode(PostControlDisplayMode)
        case delete
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
    
    // MARK: - 初始化
    private override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    convenience init(style: PostStyle) {
        self.init()
        self.style = style
        setupColorConfigurations()
        setupToggleDebounces()
    }
    
    deinit {
        print("StyleViewController is deinited")
    }
    
    // MARK: - 配置颜色设置
    private func setupColorConfigurations() {
        for colorType in ColorConfiguration.ColorType.allCases {
            let config = ColorConfiguration(type: colorType, style: style)
            colorManager.addConfiguration(config)
        }
    }
    
    private func setupToggleDebounces() {
        for colorType in ColorConfiguration.ColorType.allCases {
            colorToggleDebounces[colorType] = Debounce(duration: 0.2, block: { [weak self] value in
                await self?.commitUpdate(for: colorType, isEnabled: value)
            })
        }
    }
    
    // MARK: - 生命周期
    override func viewDidLoad() {
        super.viewDidLoad()
        
        view.backgroundColor = AppColor.background
        self.title = String(localized: "style.editor")
        
        setupNavigationBar()
        configureHierarchy()
        configureDataSource()
        reloadData()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        if style.id == nil {
            _ = nameCell?.becomeFirstResponder()
        }
    }
    
    private func setupNavigationBar() {
        let saveItem = UIBarButtonItem(title: String(localized: "button.save"), style: .done, target: self, action: #selector(save))
        saveItem.tintColor = .systemRed
        saveItem.isEnabled = false
        saveBarButton = saveItem
        
        let cancelItem = UIBarButtonItem(title: String(localized: "button.cancel"), style: .plain, target: self, action: #selector(dismissViewController))
        cancelItem.tintColor = .systemRed
        
        navigationItem.trailingItemGroups = [UIBarButtonItemGroup.fixedGroup(items: [saveItem])]
        navigationItem.leadingItemGroups = [UIBarButtonItemGroup.fixedGroup(items: [cancelItem])]
    }
    
    // MARK: - UI 配置
    func configureHierarchy() {
        tableView = UIDraggableTableView(frame: .zero, style: .insetGrouped)
        tableView.backgroundColor = AppColor.background
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: NSStringFromClass(UITableViewCell.self))
        tableView.register(TextInputCell.self, forCellReuseIdentifier: NSStringFromClass(TextInputCell.self))
        tableView.register(ColorPickerCell.self, forCellReuseIdentifier: NSStringFromClass(ColorPickerCell.self))
        tableView.register(OptionCell<PostTextSize>.self, forCellReuseIdentifier: NSStringFromClass(OptionCell<PostTextSize>.self))
        tableView.register(OptionCell<PostTextAlignment>.self, forCellReuseIdentifier: NSStringFromClass(OptionCell<PostTextAlignment>.self))
        tableView.register(SymbolCell.self, forCellReuseIdentifier: NSStringFromClass(SymbolCell.self))
        tableView.register(SymbolTextCell.self, forCellReuseIdentifier: NSStringFromClass(SymbolTextCell.self))
        tableView.register(OptionCell<PostImageDisplayMode>.self, forCellReuseIdentifier: NSStringFromClass(OptionCell<PostImageDisplayMode>.self))
        tableView.register(OptionCell<PostControlDisplayMode>.self, forCellReuseIdentifier: NSStringFromClass(OptionCell<PostControlDisplayMode>.self))
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 50.0
        tableView.delegate = self
        view.addSubview(tableView)
        
        tableView.snp.makeConstraints { make in
            make.edges.equalTo(view)
        }
        
        tableView.contentInset = .zero
        tableView.keyboardDismissMode = .onDrag
    }
    
    func configureDataSource() {
        dataSource = DataSource(tableView: tableView) { [weak self] (tableView, indexPath, item) -> UITableViewCell? in
            guard let self = self else { return nil }
            return self.createCell(for: item, at: indexPath)
        }
    }
    
    private func createCell(for item: Item, at indexPath: IndexPath) -> UITableViewCell {
        switch item {
        case .name(let name):
            return createNameCell(name: name)
        case .colorToggle(let colorType, let isEnabled):
            return createColorToggleCell(colorType: colorType, isEnabled: isEnabled)
        case .colorLight(let colorType, let colorPickerItem):
            return createColorPickerCell(colorType: colorType, isLight: true, colorPickerItem: colorPickerItem)
        case .colorDark(let colorType, let colorPickerItem):
            return createColorPickerCell(colorType: colorType, isLight: false, colorPickerItem: colorPickerItem)
        case .textSize(let section, let textSize):
            let cell = tableView.dequeueReusableCell(withIdentifier: NSStringFromClass(OptionCell<PostTextSize>.self), for: indexPath)
            if let cell = cell as? OptionCell<PostTextSize> {
                cell.update(with: textSize)
                let actions = PostTextSize.allCases.map { target in
                    let action = UIAction(title: target.title, subtitle: target.subtitle, state: textSize == target ? .on : .off) { [weak self] _ in
                        switch section {
                        case .name, .symbol, .others, .action:
                            break
                        case .lockScreen:
                            self?.lockTextSize = target
                        case .island:
                            self?.islandTextSize = target
                        }
                    }
                    return action
                }
                let menu = UIMenu(children: actions)
                cell.valueButton.menu = menu
            }
            return cell
        case .textAlignment(let section, let textAlignment):
            let cell = tableView.dequeueReusableCell(withIdentifier: NSStringFromClass(OptionCell<PostTextAlignment>.self), for: indexPath)
            if let cell = cell as? OptionCell<PostTextAlignment> {
                cell.update(with: textAlignment)
                let actions = PostTextAlignment.allCases.map { target in
                    let action = UIAction(title: target.title, subtitle: target.subtitle, state: textAlignment == target ? .on : .off) { [weak self] _ in
                        switch section {
                        case .name, .symbol, .others, .action:
                            break
                        case .lockScreen:
                            self?.lockTextAlignment = target
                        case .island:
                            self?.islandTextAlignment = target
                        }
                    }
                    return action
                }
                let menu = UIMenu(children: actions)
                cell.valueButton.menu = menu
            }
            return cell
        case .symbol(let symbol, let color):
            let cell = tableView.dequeueReusableCell(withIdentifier: NSStringFromClass(SymbolCell.self), for: indexPath)
            cell.accessoryType = .disclosureIndicator
            var content = UIListContentConfiguration.cell()
            content.attributedText = NSAttributedString.symbol(symbol, pointSize: 20.0, color: color)
            cell.contentConfiguration = content
            return cell
        case .symbolAngle(let angle):
            let cell = tableView.dequeueReusableCell(withIdentifier: NSStringFromClass(SymbolTextCell.self), for: indexPath)
            var content = UIListContentConfiguration.valueCell()
            content.text = String(localized: "style.symbol.angle")
            content.textProperties.color = AppColor.text
            content.secondaryText = String(format: String(localized: "style.symbol.angle%d"), angle / 100)
            cell.contentConfiguration = content
            cell.accessoryType = .disclosureIndicator
            return cell
        case .imageDisplayMode(let displayMode):
            let cell = tableView.dequeueReusableCell(withIdentifier: NSStringFromClass(OptionCell<PostImageDisplayMode>.self), for: indexPath)
            if let cell = cell as? OptionCell<PostImageDisplayMode> {
                cell.update(with: displayMode)
                let actions = PostImageDisplayMode.allCases.map { target in
                    let action = UIAction(title: target.title, subtitle: target.subtitle, state: displayMode == target ? .on : .off) { [weak self] _ in
                        self?.imageDisplayMode = target
                    }
                    return action
                }
                let menu = UIMenu(children: actions)
                cell.valueButton.menu = menu
            }
            return cell
        case .controlDisplayMode(let displayMode):
            let cell = tableView.dequeueReusableCell(withIdentifier: NSStringFromClass(OptionCell<PostControlDisplayMode>.self), for: indexPath)
            if let cell = cell as? OptionCell<PostControlDisplayMode> {
                cell.update(with: displayMode)
                let actions = PostControlDisplayMode.allCases.map { target in
                    let action = UIAction(title: target.title, subtitle: target.subtitle, state: displayMode == target ? .on : .off) { [weak self] _ in
                        self?.controlDisplayMode = target
                    }
                    return action
                }
                let menu = UIMenu(children: actions)
                cell.valueButton.menu = menu
            }
            return cell
        case .delete:
            let cell = tableView.dequeueReusableCell(withIdentifier: NSStringFromClass(UITableViewCell.self), for: indexPath)
            var content = UIListContentConfiguration.valueCell()
            content.text = String(localized: "button.delete")
            content.textProperties.color = .systemRed
            content.textProperties.alignment = .center
            cell.contentConfiguration = content
            cell.accessoryType = .none
            return cell
        }
    }
    
    private func createNameCell(name: String?) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: NSStringFromClass(TextInputCell.self)) as! TextInputCell
        nameCell = cell
        cell.update(text: name, placeholder: String(localized: "style.name"))
        cell.textDidChanged = { [weak self] text in
            self?.styleName = text
        }
        cell.tintColor = .systemRed
        return cell
    }
    
    private func createColorToggleCell(colorType: ColorConfiguration.ColorType, isEnabled: Bool) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: NSStringFromClass(UITableViewCell.self))!
        let itemSwitch = UISwitch()
        itemSwitch.isOn = isEnabled
        itemSwitch.addTarget(self, action: #selector(colorToggleAction(_:)), for: .valueChanged)
        itemSwitch.tag = colorType.hashValue
        itemSwitch.onTintColor = .systemRed
        
        var content = cell.defaultContentConfiguration()
        if let config = colorManager.configuration(for: colorType) {
            content.text = config.type.title
        }
        content.textProperties.color = AppColor.text
        cell.accessoryView = itemSwitch
        cell.contentConfiguration = content
        return cell
    }
    
    private func createColorPickerCell(colorType: ColorConfiguration.ColorType, isLight: Bool, colorPickerItem: ColorPickerItem) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: NSStringFromClass(ColorPickerCell.self)) as! ColorPickerCell
        
        guard let config = colorManager.configuration(for: colorType) else { return cell }
        
        // 存储单元格引用
        if colorConfigurationCells[colorType] == nil {
            colorConfigurationCells[colorType] = (nil, nil)
        }
        
        if isLight {
            colorConfigurationCells[colorType]?.lightCell = cell
        } else {
            colorConfigurationCells[colorType]?.darkCell = cell
        }
        
        cell.update(with: colorPickerItem)
        
        let interfaceStyle: UIUserInterfaceStyle = isLight ? .light : .dark
        let currentColor = isLight ? config.lightColor : config.darkColor
        cell.update(colors: getColors(for: colorType, interfaceStyle: interfaceStyle),
                   selectedColor: currentColor.generateLightDarkString(interfaceStyle))
        
        cell.selectedColorDidChange = { [weak self] newColor in
            if let color = UIColor(hex: newColor) {
                self?.updateColorConfiguration(colorType: colorType, color: color, isLight: isLight)
            }
        }
        
        cell.showPicker = { [weak self] in
            self?.showColorPicker(for: colorType, isLight: isLight)
        }
        
        return cell
    }
    
    // MARK: - 数据重载
    func reloadData() {
        updateSaveButtonStatus()
        
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.name, .lockScreen, .island, .symbol, .others])
        
        // 名称部分
        snapshot.appendItems([.name(styleName)], toSection: .name)
        
        snapshot.appendItems([.symbol(symbol, UIColor(string: style.symbolColor ?? "") ?? .systemRed)], toSection: .symbol)
        
        // 颜色配置部分
        for sectionManager in [lockScreenSectionManager, islandSectionManager, iconSectionManager] {
            for colorType in sectionManager.configurations {
                guard let config = colorManager.configuration(for: colorType) else { continue }
                
                let toggleItem = Item.colorToggle(colorType, config.isEnabled)
                snapshot.appendItems([toggleItem], toSection: sectionManager.section)
                
                if config.isEnabled {
                    let lightItem = Item.colorLight(colorType, ColorPickerItem(title: String(localized: "color.light")))
                    let darkItem = Item.colorDark(colorType, ColorPickerItem(title: String(localized: "color.dark")))
                    snapshot.appendItems([lightItem, darkItem], toSection: sectionManager.section)
                }
            }
        }
        
        snapshot.appendItems([.textSize(.lockScreen, lockTextSize)], toSection: .lockScreen)
        snapshot.appendItems([.textAlignment(.lockScreen, lockTextAlignment)], toSection: .lockScreen)
        snapshot.appendItems([.controlDisplayMode(controlDisplayMode)], toSection: .lockScreen)
        
        snapshot.appendItems([.textSize(.island, islandTextSize)], toSection: .island)
        snapshot.appendItems([.textAlignment(.island, islandTextAlignment)], toSection: .island)
        
        snapshot.appendItems([.symbolAngle(symbolAngle)], toSection: .symbol)
        
        snapshot.appendItems([.imageDisplayMode(imageDisplayMode)], toSection: .others)
        
        if let styleId = style.id, DefaultStyle.current.rawValue != Int(styleId) {
            snapshot.appendSections([.action])
            snapshot.appendItems([.delete], toSection: .action)
        }
        
        dataSource.apply(snapshot, animatingDifferences: false)
    }
    
    // MARK: - 颜色管理
    private func defaultColors() -> [UIColor] {
        return [.systemPink, .systemRed, .systemOrange, .systemYellow, .systemGreen,
                .systemMint, .systemTeal, .systemCyan, .systemBlue, .systemIndigo,
                .systemPurple, .systemBrown, .white,
                UIColor(white: 0.9, alpha: 1.0), UIColor(white: 0.8, alpha: 1.0),
                UIColor(white: 0.7, alpha: 1.0), UIColor(white: 0.6, alpha: 1.0),
                .gray, UIColor(white: 0.4, alpha: 1.0), UIColor(white: 0.3, alpha: 1.0),
                UIColor(white: 0.2, alpha: 1.0), UIColor(white: 0.1, alpha: 1.0), .black]
    }
    
    private func getColors(for colorType: ColorConfiguration.ColorType, interfaceStyle: UIUserInterfaceStyle) -> [String] {
        guard let config = colorManager.configuration(for: colorType) else { return [] }
        
        var colors: [String] = []
        let defaultColorStrings = defaultColors().map { $0.generateLightDarkString(interfaceStyle) }.unique()
        
        // 确保当前颜色在自定义颜色列表中（如果是自定义颜色）
        let currentColor = interfaceStyle == .light ? config.lightColor : config.darkColor
        let currentColorString = currentColor.generateLightDarkString(interfaceStyle)
        
        if !defaultColorStrings.contains(currentColorString) {
            // 如果当前颜色不在默认颜色中，且不在自定义颜色中，则添加到自定义颜色
            if !config.customColors.contains(where: { $0.generateLightDarkString(interfaceStyle) == currentColorString }) {
                config.customColors.append(currentColor)
            }
        }
        
        // 添加自定义颜色
        config.customColors.reversed().forEach { customColor in
            let customColorString = customColor.generateLightDarkString(interfaceStyle)
            if !defaultColorStrings.contains(customColorString), !colors.contains(customColorString) {
                colors.append(customColorString)
            }
        }
        
        // 添加默认颜色
        colors.append(contentsOf: defaultColorStrings)
        
        return colors
    }
    
    private func updateColorConfiguration(colorType: ColorConfiguration.ColorType, color: UIColor, isLight: Bool) {
        guard let config = colorManager.configuration(for: colorType) else { return }
        
        // 更新颜色配置
        if isLight {
            config.updateLightColor(color)
        } else {
            config.updateDarkColor(color)
        }
        
        // 更新样式
        updateStyleFromConfigurations()
        
        // 刷新相关单元格
        refreshColorCells(for: colorType)
        
        if colorType == .symbol {
            reloadData()
        }
        
        markAsEdited()
    }
    
    private func updateStyleFromConfigurations() {
        // 更新所有配置到style
        for config in colorManager.configurations {
            config.updateStyle(&style)
        }
    }
    
    private func refreshColorCells(for colorType: ColorConfiguration.ColorType) {
        guard let config = colorManager.configuration(for: colorType),
              let cells = colorConfigurationCells[colorType] else { return }
        
        let lightColors = getColors(for: colorType, interfaceStyle: .light)
        let darkColors = getColors(for: colorType, interfaceStyle: .dark)
        
        cells.lightCell?.update(colors: lightColors, selectedColor: config.lightColor.generateLightDarkString(.light))
        cells.darkCell?.update(colors: darkColors, selectedColor: config.darkColor.generateLightDarkString(.dark))
    }
    
    // MARK: - 动作处理
    @objc func save() {
        // 确保所有配置都更新到style
        updateStyleFromConfigurations()
        
        // 通知委托
        delegate?.styleEditor(self, didUpdateStyle: style)
        
        // 关闭界面
        dismiss(animated: ConsideringUser.animated)
    }
    
    @objc func dismissViewController() {
        dismiss(animated: ConsideringUser.animated)
    }
    
    @objc func colorToggleAction(_ sender: UISwitch) {
        // 通过遍历找到对应的颜色类型
        for config in colorManager.configurations {
            if config.type.hashValue == sender.tag {
                colorToggleDebounces[config.type]?.emit(value: sender.isOn)
                break
            }
        }
    }
    
    private func commitUpdate(for colorType: ColorConfiguration.ColorType, isEnabled: Bool) {
        guard let config = colorManager.configurations.first(where: { $0.type == colorType }) else { return }
        guard config.isEnabled != isEnabled else { return }
        
        let oldValue = config.isEnabled
        config.isEnabled = isEnabled
        
        if !config.isEnabled {
            // 禁用时清除颜色设置 - 在updateStyleFromConfigurations中处理
        } else if !oldValue && config.isEnabled {
            // 从关闭到开启时，重置为默认颜色
            config.resetToDefaultColors()
        }
        
        // 更新样式
        updateStyleFromConfigurations()
        
        markAsEdited()
        reloadData()
    }
    
    // MARK: - 颜色选择器
    private func showColorPicker(for colorType: ColorConfiguration.ColorType, isLight: Bool) {
        guard let config = colorManager.configuration(for: colorType) else { return }
        
        let colorPicker = StyleColorPickerViewController()
        colorPicker.style = .init(colorType: colorType, isLight: isLight)
        colorPicker.selectedColor = isLight ? config.lightColor : config.darkColor
        colorPicker.delegate = self
        present(colorPicker, animated: ConsideringUser.animated)
    }
    
    private func markAsEdited() {
        isEdited = true
        updateSaveButtonStatus()
    }
    
    private func updateSaveButtonStatus() {
        let nameValid = !styleName.isEmpty
        saveBarButton?.isEnabled = nameValid && isEdited
    }
    
    //
    @objc
    private func showSymbolPicker() {
        presentSymbolPicker(currentSymbol: symbol) { [weak self] symbol in
            self?.symbol = symbol
        }
    }
}

// MARK: - TableView 代理
extension StyleViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        
        if let identifier = dataSource.itemIdentifier(for: indexPath) {
            switch identifier {
            case .symbol:
                showSymbolPicker()
            case .symbolAngle:
                let alertController = UIAlertController(title: String(localized: "style.alert.angle.title"), message: String(localized: "style.alert.angle.message"), preferredStyle: .alert)
                alertController.addTextField { [weak self] textField in
                    guard let self = self else { return }
                    textField.placeholder = ""
                    textField.text = "\(self.symbolAngle / 100)"
                    textField.addTarget(alertController, action: #selector(alertController.textDidChangeInAngle), for: .editingChanged)
                }
                let cancelAction = UIAlertAction(title: String(localized: "button.cancel"), style: .cancel) { _ in
                    //
                }
                let okAction = UIAlertAction(title: String(localized: "button.confirm"), style: .default) { [weak self] _ in
                    if let text = alertController.textFields?.first?.text, let value = Int(text) {
                        self?.symbolAngle = value * 100
                    } else {
                        self?.symbolAngle = 0
                    }
                }

                alertController.addAction(cancelAction)
                alertController.addAction(okAction)
                present(alertController, animated: ConsideringUser.animated, completion: nil)
            case .delete:
                let alertController = UIAlertController(title: String(localized: "style.alert.delete.title"), message: nil, preferredStyle: .alert)
                let deleteAction = UIAlertAction(title: String(localized: "button.delete"), style: .destructive) { [weak self] _ in
                    guard let self = self else { return }
                    alertController.dismiss(animated: ConsideringUser.animated)
                    self.dismissViewController()
                    _ = DataManager.shared.delete(style: self.style)
                }
                
                let cancelAction = UIAlertAction(title: String(localized: "button.cancel"), style: .cancel)
                alertController.addAction(deleteAction)
                alertController.addAction(cancelAction)
                
                present(alertController, animated: ConsideringUser.animated)
            default:
                break
            }
        }
    }
}

// MARK: - 颜色选择器代理
extension StyleViewController: UIColorPickerViewControllerDelegate {
    func colorPickerViewControllerDidFinish(_ viewController: UIColorPickerViewController) {
        guard let styleVC = viewController as? StyleColorPickerViewController else { return }
        
        updateColorConfiguration(
            colorType: styleVC.style.colorType,
            color: viewController.selectedColor,
            isLight: styleVC.style.isLight
        )
        
        reloadData()
    }
}

// MARK: - 扩展颜色选择器样式
class StyleColorPickerViewController: UIColorPickerViewController {
    struct ColorPickerStyle {
        var colorType: ColorConfiguration.ColorType
        var isLight: Bool
    }
    
    var style: ColorPickerStyle = ColorPickerStyle(colorType: .lockBackground, isLight: true)
}

// MARK: - 数组去重扩展
extension Array where Element: Hashable {
    func unique() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

extension PostTextSize: OptionItem {
    static var noneTitle: String {
        return ""
    }
    
    static var sectionTitle: String {
        return String(localized: "style.textSize")
    }
    
    var title: String {
        switch self {
        case .automatic:
            return String(localized: "style.textSize.auto")
        default:
            return String(format: String(localized: "style.textSize.specific%d"), rawValue)
        }
    }
    
    var subtitle: String? {
        return nil
    }
}

extension PostTextAlignment: OptionItem {
    static var noneTitle: String {
        return ""
    }
    
    static var sectionTitle: String {
        return String(localized: "style.textAlignment")
    }
    
    var title: String {
        switch self {
        case .leading:
            return String(localized: "style.textAlignment.leading")
        case .center:
            return String(localized: "style.textAlignment.center")
        case .trailing:
            return String(localized: "style.textAlignment.trailing")
        }
    }
    
    var subtitle: String? {
        return nil
    }
}

extension PostImageDisplayMode: OptionItem {
    static var noneTitle: String {
        return ""
    }
    
    static var sectionTitle: String {
        return String(localized: "style.imageDisplayMode")
    }
    
    var title: String {
        switch self {
        case .aspectFit:
            return String(localized: "style.imageDisplayMode.aspectFit")
        case .aspectFill:
            return String(localized: "style.imageDisplayMode.aspectFill")
        }
    }
    
    var subtitle: String? {
        return nil
    }
}

enum PostControlDisplayMode: Int, OptionItem, CaseIterable {
    case normal = 100
    case transparent = 0
    
    static var noneTitle: String {
        return ""
    }
    
    static var sectionTitle: String {
        return String(localized: "style.postControlDisplayMode")
    }
    
    var title: String {
        switch self {
        case .normal:
            return String(localized: "style.postControlDisplayMode.normal")
        case .transparent:
            return String(localized: "style.postControlDisplayMode.transparent")
        }
    }
    
    var subtitle: String? {
        switch self {
        case .normal:
            return nil
        case .transparent:
            return String(localized: "style.postControlDisplayMode.transparent.hint")
        }
    }
}

extension NSAttributedString {
    static func symbol(
        _ symbolName: String,
        pointSize: CGFloat = 17,
        color: UIColor? = nil
    ) -> NSAttributedString {
        let symbolConfig = UIImage.SymbolConfiguration(pointSize: pointSize)
        
        guard let symbolImage = UIImage(systemName: symbolName)?.withConfiguration(symbolConfig) else {
            return NSAttributedString(string: "")
        }
        
        let imageAttachment = NSTextAttachment()
        if let color = color {
            imageAttachment.image = symbolImage.withTintColor(color, renderingMode: .alwaysOriginal)
        } else {
            imageAttachment.image = symbolImage
        }
        
        return NSAttributedString(attachment: imageAttachment)
    }
}

extension UIAlertController {
    @objc
    func textDidChangeInAngle() {
        if let title = textFields?[0].text, let action = actions.last {
            action.isEnabled = (title.count > 0) && (Int(title) != nil)
        }
    }
}

struct DefaultStyle: RawRepresentable, UserDefaultSettable {
    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    var rawValue: Int

    static func getKey() -> String {
        UserDefaults.Settings.DefaultStyle.rawValue
    }
    
    static var defaultOption: DefaultStyle = Self.init(rawValue: 0)
    
    func getName() -> String {
        let style = DataManager.shared.fetchStyle(by: Int64(rawValue))
        return style?.name ?? ""
    }
    
    static func getTitle() -> String {
        return String(localized: "style.default")
    }
    
    static func getOptions() -> [DefaultStyle] {
        let styleIds = DataManager.shared.fetchAllStyles().compactMap({ $0.id }).map({ Int($0) })
        
        return styleIds.map{ DefaultStyle.init(rawValue: $0) }
    }
    
    static func setCurrent(_ value: DefaultStyle) throws {
        setValue(value)
        
        NotificationCenter.default.post(name: NSNotification.Name.DefaultStyleDidChanged, object: nil)
    }
}
