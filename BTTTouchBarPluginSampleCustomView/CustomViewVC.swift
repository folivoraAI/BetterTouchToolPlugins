//
//  CustomViewVC.swift
//  BTTTouchBarPluginSampleCustomView
//
//  Created by Andreas Hegenberg on 22.06.19.
//  Copyright © 2019 Andreas Hegenberg. All rights reserved.
//

import Cocoa

class CustomViewVC: NSViewController {
    
    override func loadView() {
        self.view = NSView.init(frame: NSMakeRect(0, 0, 40, 30));
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Do view setup here.
        
        //create a red dot, you can do whatever you want to do here
        self.view.wantsLayer = true;
        self.view.layer?.backgroundColor = NSColor.red.cgColor;
        self.view.layer?.cornerRadius = 10;
    }
    
}
