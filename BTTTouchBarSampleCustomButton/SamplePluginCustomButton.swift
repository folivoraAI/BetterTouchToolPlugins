import Foundation
import AppKit
@objc class SamplePluginCustomButton : NSObject, BTTTouchBarPluginInterface
{
    // the delegate will be set automatically after this plugin is loaded in BTT
    var delegate : BTTTouchBarPluginDelegate?
    
    
    var button: NSButton?;
    var configurationValues: Dictionary<AnyHashable, Any> = [:];
    
    
    /* MARK: Option 2: Returning a NSButton instance
     * If you return a button, BTT will just display that button on the Touch Bar.
     * You are responsible for any styling you want to apply.
     * Make sure to always return the same instance of the button here
     * as BTT may call this method multiple times.
     */
    func touchBarButton() -> NSButton? {
        if(self.button == nil) {
            self.button = NSButton.init(title: "Hello Custom Button!", target: self, action: #selector(executeAssignedBTTActions));
            self.configureButton();
            
        }
        return self.button;
    }
    
    func configureButton() {
        self.button?.bezelColor = NSColor.blue;
        
        if((self.configurationValues["plugin_var_widgetName"]) != nil) {
            self.button?.title = configurationValues["plugin_var_widgetName"] as! String;
            
            //MARK: Important: you need to make sure the button/view has the correct frame.
            self.button?.sizeToFit();
        }
    }
    
    // here you can configure what items are shown in the BTT configuration side-bar for this plugin
    class func configurationFormItems() -> BTTPluginFormItem? {
        
        // here we just create a text field, we will receive the
        // current value in didReceiveNewConfigurationValues
        let item = BTTPluginFormItem.init();
        item.formFieldType = BTTFormTypeTextField;
        item.formLabel1 = "Custom Widget Name";
        item.formFieldID = "widgetName";
        
        return item;
    }
    
    func didReceiveNewConfigurationValues(_ configurationValues: [AnyHashable : Any]) {
        self.configurationValues = configurationValues;
        if (self.button != nil) {
            self.configureButton();
        }
    }
    
    // this will tell BTT to execute the actions the user assigned to this widget
    @objc func executeAssignedBTTActions() {
        self.delegate?.executeAssignedBTTActions(self);
    }
    
}

