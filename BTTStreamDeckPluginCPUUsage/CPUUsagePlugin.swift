//
//  CPUUsagePlugin.swift
//  BTTStreamDeckPluginCPUUsage
//
//  Created by Andreas Hegenberg on 07.07.22.
//  Copyright © 2022 Andreas Hegenberg. All rights reserved.
//

import Foundation
import AppKit

@objc class CPUUsagePlugin : NSObject, BTTStreamDeckPluginInterface {
    let cpuUsageMonitor = MyCpuUsage()
    
    var displayString: String = ""
    // the delegate will be set automatically after this plugin is loaded in BTT
    var delegate : BTTStreamDeckPluginDelegate?
    
    override init() {
        super.init();
        
        // monitor the cpu usage and update the widget accordingly
        cpuUsageMonitor.startMonitoring { currentCPULoad in
            self.displayString = String(format: "%.0f%%", currentCPULoad*100)
            
            // when this is called BTT will call the "widgetTitleStrings" function again
            self.delegate?.requestUpdate(self)

        }
    }
    
   
    // we just return a string with the current cpu usage
    // and make use of the default styling defined by the user
    func widgetTitleStrings() -> [String]? {
        return [displayString]
    }
    
    
    /*
     Alternatively these could be used:
     
     func widgetAttributedTitleStrings() -> [NSAttributedString]? {
     
     }
     
     func widgetImages() -> [NSImage]? {
     
     }
     
     func widgetDictionaries() -> [[AnyHashable : Any]]? {
     
     }
     */
    
    
    func didReceiveNewConfigurationValues(_ configurationValues: [AnyHashable : Any]) {
        //let widgetName = configurationValues["plugin_var_widgetName"]
        //let checkboxValue = configurationValues["plugin_var_someCheckboxValue"]
    }
    
    
    // here you can configure what items are shown in the BTT configuration side-bar for this plugin
    class func configurationFormItems() -> BTTPluginFormItem? {
        
        let groupItem = BTTPluginFormItem.init();
        groupItem.formFieldType = BTTFormTypeFormGroup;
        
        // add a bold title label
        let titleField = BTTPluginFormItem.init();
        titleField.formFieldType = BTTFormTypeTitleField;
        titleField.formLabel1 = "CPU Load Example Widget (no further config available yet)";
        
//        // here we create a text field, we will receive the
//        // current value in didReceiveNewConfigurationValues
//        let textField = BTTPluginFormItem.init();
//        textField.formFieldType = BTTFormTypeTextField;
//        textField.formLabel1 = "Custom Widget Name";
//        // the id must stat with plugin_var_ (will be added automatically if necessary)
//        textField.formFieldID = "plugin_var_widgetName";
//
//        // here we create a checkbox, we will receive the
//        // current value in didReceiveNewConfigurationValues
//        let checkbox = BTTPluginFormItem.init();
//        checkbox.formFieldType = BTTFormTypeCheckbox;
//        checkbox.formLabel1 = "Some Checkbox";
//        // the id must stat with plugin_var_ (will be added automatically if necessary)
//        checkbox.formFieldID = "plugin_var_someCheckboxValue";
        
        
        groupItem.formOptions = [titleField /*, textField, checkbox*/];
        
        return groupItem;
    }
}
