//
//  Tips.swift
//  Pin It
//
//  Created by Ci Zi on 2025/11/1.
//

import TipKit

struct AddPostTip: Tip {
    var title: Text {
        Text("tips.addPost.title")
    }
    
    var message: Text? {
        Text("tips.addPost.message")
    }
    
    var image: Image? {
        Image(systemName: "plus.circle")
    }
}
