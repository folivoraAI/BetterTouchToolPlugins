//
//  ShowNotificationPlugin.swift
//  BTTDisplayNotificationActionPlugin
//
//  Created by Andreas Hegenberg on 19.01.20.
//  Copyright © 2020 Andreas Hegenberg. All rights reserved.
//

import Foundation
import AppKit

@objc class ShowNotificationPlugin : NSObject, BTTActionPluginInterface
{
    static func configurationFormItems() -> BTTPluginFormItem? {
        let group = BTTPluginFormItem.init();
        group.formFieldType = BTTFormTypeFormGroup;
        
        
        // here we just create a text field, we will receive the
        // current value in didReceiveNewConfigurationValues
        let item = BTTPluginFormItem.init();
        item.formFieldType = BTTFormTypeTextField;
        item.formLabel1 = "Notification Title";
        item.formFieldID = "notificationTitle";
        
        let item2 = BTTPluginFormItem.init();
        item2.formFieldType = BTTFormTypeTextField;
        item2.formLabel1 = "Notification Subtitle";
        item2.formFieldID = "notificationSubtitle";
        
        let item3 = BTTPluginFormItem.init();
        item3.formFieldType = BTTFormTypeTextField;
        item3.formLabel1 = "Notification Sound Name";
        item3.formFieldID = "notificationSoundName";
        item3.defaultValue = NSUserNotificationDefaultSoundName;
        
        let iconPicker = BTTPluginFormItem.init();
        iconPicker.formFieldType = BTTFormTypeImagePicker;
        iconPicker.formFieldID = "notificationIcon";
        iconPicker.formLabel1 = "Icon:";
        
        group.formOptions = [item,item2, item3, iconPicker];
        return group;
    }
    
    static func actionName(withConfiguration configurationValues: [AnyHashable : Any]?)-> String? {
        let titleString = configurationValues?["plugin_var_notificationTitle"] as! String? ?? "";
        return "Show Notification " + titleString ;
    }
    
    func executeAction(withConfiguration configurationValues: [AnyHashable : Any]?, completionBlock actionExecutedWithResult: ((Any?) -> Void)!) {

        
        if(configurationValues != nil) {
            
            let titleString = configurationValues?["plugin_var_notificationTitle"];
            let subtitleString = configurationValues?["plugin_var_notificationSubtitle"];
            let soundName = configurationValues?["plugin_var_notificationSoundName"];
            
            // things like images always come back as base64 string
            let iconStringBase64 = configurationValues?["plugin_var_notificationIcon"];
            
            
            let notification = NSUserNotification()

            
            if(iconStringBase64 != nil) {
                let iconData = Data.init(base64Encoded: iconStringBase64 as! String, options: []) ?? nil;
                
                if(iconData != nil) {
                    var icon: NSImage? = nil;
                    if(iconData != nil) {
                        icon = NSImage.init(data: iconData!);
                        notification.contentImage = icon;
                    }
                }
            }
            
          
            notification.title = titleString as? String
            notification.subtitle = subtitleString as? String
            notification.soundName = soundName as? String
            NSUserNotificationCenter.default.deliver(notification)
        }
       
    }
}

