//
//  MainViewController.swift
//  Pin It
//
//  Created by Ci Zi on 2025/10/13.
//

import UIKit
import SnapKit

class MainViewController: UIViewController {
    var startButton: UIButton = {
        var configuration = UIButton.Configuration.bordered()
        configuration.cornerStyle = .large
        configuration.image = UIImage(systemName: "pin")
        let button = UIButton(configuration: configuration)
        button.showsMenuAsPrimaryAction = true
        return button
    }()
    
    var endButton: UIButton = {
        var configuration = UIButton.Configuration.bordered()
        configuration.cornerStyle = .large
        configuration.image = UIImage(systemName: "pin.slash")
        let button = UIButton(configuration: configuration)
        button.showsMenuAsPrimaryAction = true
        return button
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view.
        
        view.backgroundColor = UIColor.background
        
        view.addSubview(startButton)
        startButton.snp.makeConstraints { make in
            make.centerX.equalTo(view)
            make.top.equalTo(view.snp.centerY)
        }
        
        view.addSubview(endButton)
        endButton.snp.makeConstraints { make in
            make.centerX.equalTo(view)
            make.top.equalTo(startButton.snp.bottom).offset(20)
        }
        
        startButton.addTarget(self, action: #selector(startAction), for: .touchUpInside)
        endButton.addTarget(self, action: #selector(endAction), for: .touchUpInside)
    }
    
    @objc
    func startAction() {
        Task {
            await LiveActivityManager.shared.start()
        }
    }
    
    @objc
    func endAction() {
        Task {
            await LiveActivityManager.shared.end()
        }
    }
}

