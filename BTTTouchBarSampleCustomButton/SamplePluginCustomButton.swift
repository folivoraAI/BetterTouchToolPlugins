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
        
        let groupItem = BTTPluginFormItem.init();
        groupItem.formFieldType = BTTFormTypeFormGroup;
        
        // add a bold title label
        let titleField = BTTPluginFormItem.init();
        titleField.formFieldType = BTTFormTypeTitleField;
        titleField.formLabel1 = "Some Example Title";
        
        // here we create a text field, we will receive the
        // current value in didReceiveNewConfigurationValues
        let textField = BTTPluginFormItem.init();
        textField.formFieldType = BTTFormTypeTextField;
        textField.formLabel1 = "Custom Widget Name";
        // the id must stat with plugin_var_ (will be added automatically if necessary)
        textField.formFieldID = "plugin_var_widgetName";
        
        // here we create a checkbox, we will receive the
        // current value in didReceiveNewConfigurationValues
        let checkbox = BTTPluginFormItem.init();
        checkbox.formFieldType = BTTFormTypeCheckbox;
        checkbox.formLabel1 = "Some Checkbox";
        // the id must stat with plugin_var_ (will be added automatically if necessary)
        checkbox.formFieldID = "plugin_var_someCheckboxValue";
        
        
        groupItem.formOptions = [titleField, textField, checkbox];
        
        return groupItem;
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

