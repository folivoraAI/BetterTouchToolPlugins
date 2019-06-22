//
//  BTTFormConstants.h
//  BTTSamplePlugin
//
//  Created by Andreas Hegenberg on 20.06.19.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface BTTFormConstants : NSObject

extern NSString * const BTTFormType;
extern NSString * const BTTFormDefault ;
extern NSString * const BTTFormDataType ;
extern NSString * const BTTFormKeyPath;
extern NSString * const BTTFormOptions;
extern NSString * const BTTFormShouldTriggerReload;

extern NSString * const BTTFormTypeCheckbox;
extern NSString * const BTTFormTypeTextField;
extern NSString * const BTTFormTypeTwoTextFields;
extern NSString * const BTTFormTypeTextArea;
extern NSString * const BTTFormTypeTitleField;

extern NSString * const BTTFormTypeDetailTitleField;
extern NSString * const BTTFormTypePopupButton;
extern NSString * const BTTFormTypeSlider;

extern NSString * const BTTFormLabel1;
extern NSString * const BTTFormLabel2;
extern NSString * const BTTFormLabel3;
extern NSString * const BTTFormMinValue;
extern NSString * const BTTFormMaxValue;
extern NSString * const BTTFormOption;
extern NSString * const BTTFormSaveBlock;
extern NSString * const BTTFormIsHiddenBlock;
extern NSString * const BTTFormIsDisabledBlock;
extern NSString * const BTTFormLoadingBlock;
extern NSString * const BTTFormTypeSelectorPopover;
extern NSString * const BTTFormTypeModifiers;
extern NSString * const BTTFormTypeSeparator;
extern NSString * const BTTFormShortcutRecorder;
extern NSString * const BTTFormTypeNoAction;
extern NSString * const BTTFormTypeColorPicker;
extern NSString * const BTTFormTypeImagePicker;
extern NSString * const BTTFormTypeFormGroup;
extern NSString * const BTTFormTypeAppleScript;
extern NSString * const BTTFormTypeShellScript;
extern NSString * const BTTFormTypeButton;
extern NSString * const BTTFormTypeCustomTextInsertDropDown;
extern NSString * const BTTFormTypeMouseClickRecognizer;
extern NSString * const BTTFormTypeScalingBezierPath;

extern NSString * const BTTFormTypeDescription;
extern NSString * const BTTFormTypeTabs;
extern NSString * const BTTFormDataType;
extern NSString * const BTTFormFieldID;
typedef enum {
    BTTFormDataString = 1,
    BTTFormDataNumber = 2,
    BTTFormDataJSON = 3,
    BTTFormDataIcon= 5,
    BTTFormDataData = 6
    
    
} BTTFormData;

@end

NS_ASSUME_NONNULL_END
