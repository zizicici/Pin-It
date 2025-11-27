//
//  StyleEntity.swift
//  Pin It
//
//  Created by Ci Zi on 2025/11/27.
//

import Foundation
import AppIntents
import UIKit

struct StyleEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "intent.style.type")
    typealias DefaultQuery = StyleIntentQuery
    static var defaultQuery = StyleIntentQuery()
    var displayRepresentation: DisplayRepresentation {
        return DisplayRepresentation(title: "\(name)", subtitle: isDefault ? "intent.style.isDefaultValue" : nil, image: DisplayRepresentation.Image(systemName: symbolName, tintColor: tintColor, symbolConfiguration: UIImage.SymbolConfiguration.preferringMulticolor()))
    }
    
    var id: Int
    
    @Property(title: "intent.style.nameValue")
    var name: String
    
    @Property(title: "intent.style.isDefaultValue")
    var isDefault: Bool
    
    var symbolName: String!
    
    var symbolColor: String?
    
    var tintColor: UIColor? {
        if let symbolColor = symbolColor {
            return UIColor(string: symbolColor)
        } else {
            return nil
        }
    }
    
    init? (style: PostStyle, defaultId: (any SignedInteger)?) {
        guard let styleId = style.id, let defaultId = defaultId else {
            return nil
        }
        self.id = Int(styleId)
        self.name = style.name
        self.isDefault = (styleId == defaultId)
        self.symbolName = style.symbol
        self.symbolColor = style.symbolColor
    }
}

struct StyleIntentQuery: EntityQuery {
    func entities(for identifiers: [Int]) async throws -> [StyleEntity] {
        let defaultStyleId: Int64 = Int64(UserDefaults(suiteName: appGroupId)?.getInt(forKey: UserDefaults.Settings.DefaultStyle.rawValue) ?? -1)
        
        let styles = DataManager.shared.fetchStyles(by: identifiers.map{ Int64($0) })
        
        let result = styles.compactMap { style in
            return StyleEntity(style: style, defaultId: defaultStyleId)
        }
        
        return result
    }
    
    func suggestedEntities() async throws -> [StyleEntity] {
        let defaultStyleId: Int64 = Int64(UserDefaults(suiteName: appGroupId)?.getInt(forKey: UserDefaults.Settings.DefaultStyle.rawValue) ?? -1)
        
        let styles = DataManager.shared.fetchAllStyles()
        
        let result = styles.compactMap { style in
            return StyleEntity(style: style, defaultId: defaultStyleId)
        }
        
        return result
    }
}
