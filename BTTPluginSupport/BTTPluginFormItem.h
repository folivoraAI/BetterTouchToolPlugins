//
//  BTTPluginFormItem.h
//  BTTSamplePlugin
//
//  Created by Andreas Hegenberg on 20.06.19.
//

#import <Foundation/Foundation.h>
#import "BTTFormConstants.h"
NS_ASSUME_NONNULL_BEGIN

@interface BTTPluginFormItem : NSObject
@property (nonatomic, strong) NSString *formFieldID;
@property (nonatomic, strong) NSString *formFieldID2;
@property (nonatomic, strong) NSString *formFieldType;

@property (nonatomic) BOOL doubleClickFocus;
@property (nonatomic) BOOL doubleClickActivate;
@property (nonatomic, strong) NSString *formIconName;
@property (nonatomic) BOOL formIconIsTemplate;
@property (nonatomic, strong) NSString *formLabel1;
@property (nonatomic, strong) NSString *formLabel2;
@property (nonatomic, strong) id formOption;
@property (nonatomic, strong) NSData *formData;
@property (nonatomic, strong) NSImage *formIcon;
@property (nonatomic, strong) id defaultValue;
@property (nonatomic) BOOL floats;
@property (nonatomic) BOOL autoSave;
@property (nonatomic) BOOL shouldTriggerReload;
@property (nonatomic) BOOL saveLastStateToUserDefaults;
@property (nonatomic) BTTFormData dataType;
@property (nonatomic, strong) NSNumber *minValue;
@property (nonatomic, strong) NSNumber *maxValue;
@property (nonatomic, strong) NSArray *formOptions;
@end

NS_ASSUME_NONNULL_END
