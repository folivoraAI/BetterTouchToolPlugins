//
//  BTTLauncherPluginSupport.h
//  BTTPluginSupport
//

#import <Cocoa/Cocoa.h>
#import "BTTPluginFormItem.h"

#ifndef BTT_LAUNCHER_PLUGIN_SUPPORT_DECLARATIONS
#define BTT_LAUNCHER_PLUGIN_SUPPORT_DECLARATIONS

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, BTTLauncherPluginInputCommand) {
    BTTLauncherPluginInputCommandMoveUp = 1,
    BTTLauncherPluginInputCommandMoveDown = 2,
    BTTLauncherPluginInputCommandMoveLeft = 3,
    BTTLauncherPluginInputCommandMoveRight = 4,
    BTTLauncherPluginInputCommandRestartRecording = 5,
    BTTLauncherPluginInputCommandSpacebar = 6,
    BTTLauncherPluginInputCommandActivateSelection = 7,
    BTTLauncherPluginInputCommandAlternateActivateSelection = 8,
    BTTLauncherPluginInputCommandCopySelection = 9,
    BTTLauncherPluginInputCommandOpenSecondary = 10,
    BTTLauncherPluginInputCommandGoBackOrClose = 11,
    BTTLauncherPluginInputCommandDeleteSelection = 12
};

typedef NS_ENUM(NSInteger, BTTLauncherPluginDisplayMode) {
    BTTLauncherPluginDisplayModeHidden = 0,
    BTTLauncherPluginDisplayModeLauncherResult = 1,
    BTTLauncherPluginDisplayModeEmbeddedInLauncher = 2,
    BTTLauncherPluginDisplayModeLauncherResultAlwaysVisible = 3,
    BTTLauncherPluginDisplayModeLauncherResultKeywordOnly = 4,
    BTTLauncherPluginDisplayModeLauncherResultPromptMatchesOnly = 5,
    BTTLauncherPluginDisplayModeLauncherResultPromptMatchesOrFallback = 6
};

@interface BTTLauncherPluginShortcut : NSObject
@property (nullable, nonatomic, strong) NSString *character;
@property (nullable, nonatomic, strong) NSNumber *keyCode;
@property (nonatomic) NSEventModifierFlags modifierFlags;
@property (nullable, nonatomic, strong) NSArray<NSString *> *displayKeys;
@end

@interface BTTLauncherPluginCommand : NSObject
@property (nullable, nonatomic, strong) NSString *commandIdentifier;
@property (nullable, nonatomic, strong) NSString *title;
@property (nullable, nonatomic, strong) NSString *subtitle;
@property (nullable, nonatomic, strong) NSString *systemImageName;
@property (nullable, nonatomic, strong) BTTLauncherPluginShortcut *shortcut;
@property (nullable, nonatomic, strong) NSString *surfaceIdentifier;
@property (nonatomic) BOOL closesLauncherOnSuccess;
@property (nonatomic) BOOL destructive;
@end

@interface BTTLauncherPluginResult : NSObject
@property (nullable, nonatomic, strong) NSString *itemIdentifier;
@property (nullable, nonatomic, strong) NSString *title;
@property (nullable, nonatomic, strong) NSString *subtitle;
@property (nullable, nonatomic, strong) NSString *systemImageName;
@property (nullable, nonatomic, strong) NSImage *iconImage;
@property (nullable, nonatomic, strong) NSArray<NSString *> *keywords;
@property (nullable, nonatomic, strong) NSString *trailingHint;
@property (nullable, nonatomic, strong) NSString *primaryActionIdentifier;
@property (nullable, nonatomic, strong) NSString *surfaceIdentifier;
@property (nullable, nonatomic, strong) NSString *launcherGroup;
@property (nullable, nonatomic, strong) NSNumber *sortOrder;
@property (nullable, nonatomic, strong) NSNumber *searchMatchPriority;
@property (nullable, nonatomic, strong) NSNumber *launcherDisplayMode;
@property (nonatomic) BOOL opensChildrenByDefault;
@property (nullable, nonatomic, strong) NSString *dynamicChildrenIdentifier;
@property (nullable, nonatomic, strong) NSArray<BTTLauncherPluginResult *> *children;
@property (nullable, nonatomic, strong) NSArray<BTTLauncherPluginCommand *> *commands;
@end

@interface BTTLauncherPluginInstance : NSObject
@property (nullable, nonatomic, strong) NSString *instanceIdentifier;
@property (nullable, nonatomic, strong) NSString *title;
@property (nullable, nonatomic, strong) NSString *subtitle;
@property (nullable, nonatomic, strong) NSString *systemImageName;
@property (nullable, nonatomic, strong) NSArray<NSString *> *keywords;
@property (nullable, nonatomic, strong) NSString *trailingHint;
@property (nullable, nonatomic, strong) NSString *primaryActionIdentifier;
@property (nullable, nonatomic, strong) NSString *surfaceIdentifier;
@property (nullable, nonatomic, strong) NSString *launcherGroup;
@property (nullable, nonatomic, strong) NSNumber *sortOrder;
@property (nullable, nonatomic, strong) NSNumber *searchMatchPriority;
@property (nullable, nonatomic, strong) NSNumber *launcherDisplayMode;
@property (nullable, nonatomic, strong) NSDictionary<NSString *, id> *configuration;
@property (nonatomic) BOOL isEnabled;
@end

typedef void (^BTTLauncherPluginResultsCompletion)(NSArray<BTTLauncherPluginResult *> * _Nullable results);

@interface BTTLauncherPluginContext : NSObject
@property (nullable, nonatomic, strong) NSString *launcherID;
@property (nullable, nonatomic, strong) NSString *query;
@property (nullable, nonatomic, strong) NSString *frontmostBundleIdentifier;
@property (nullable, nonatomic, strong) NSArray<NSURL *> *finderURLs;
@property (nonatomic) BOOL finderSelection;
@property (nullable, nonatomic, strong) NSDate *timestamp;
@property (nullable, nonatomic, strong) BTTLauncherPluginInstance *launcherPluginInstance;
@end

@interface BTTLauncherPluginActionResult : NSObject
@property (nonatomic) BOOL success;
@property (nullable, nonatomic, strong) NSString *message;
@property (nonatomic) BOOL closeLauncher;
@end

@interface BTTLauncherPluginSurfaceCommandResult : NSObject
@property (nonatomic) BOOL handled;
@property (nonatomic) BOOL closeLauncher;
@property (nonatomic) BOOL goBack;
@end

@protocol BTTLauncherPluginDelegate
-(void)setVariable:(NSString *)name value:(id)value;
-(nullable id)getVariable:(NSString *)name;
-(void)executeNamedTrigger:(NSString *)triggerName;
-(void)requestLauncherResultsRefresh;
-(nullable NSString *)replaceVariablesInString:(nullable NSString *)string extraVariables:(nullable NSDictionary<NSString *, id> *)extraVariables NS_SWIFT_NAME(replaceVariables(in:extraVariables:));
-(NSArray<BTTLauncherPluginInstance *> *)launcherPluginInstancesForPluginIdentifier:(NSString *)pluginIdentifier launcherID:(nullable NSString *)launcherID NS_SWIFT_NAME(launcherPluginInstances(forPluginIdentifier:launcherID:));
-(nullable BTTLauncherPluginInstance *)saveLauncherPluginInstance:(BTTLauncherPluginInstance *)instance pluginIdentifier:(NSString *)pluginIdentifier launcherID:(nullable NSString *)launcherID NS_SWIFT_NAME(saveLauncherPluginInstance(_:pluginIdentifier:launcherID:));
-(void)deleteLauncherPluginInstance:(NSString *)instanceIdentifier pluginIdentifier:(NSString *)pluginIdentifier launcherID:(nullable NSString *)launcherID NS_SWIFT_NAME(deleteLauncherPluginInstance(_:pluginIdentifier:launcherID:));
-(NSArray<NSDictionary<NSString *, id> *> *)launcherGroupsForLauncherID:(nullable NSString *)launcherID NS_SWIFT_NAME(launcherGroups(launcherID:));
@end

@protocol BTTLauncherPluginSurfaceDelegate <BTTLauncherPluginDelegate>
-(void)requestLauncherSurfaceUpdate;
-(void)requestLauncherSurfaceGoBack;
-(void)requestLauncherSurfaceClose;
@end

@protocol BTTLauncherPluginSurfaceInterface <NSObject>
@optional
@property (nullable, weak) id<BTTLauncherPluginSurfaceDelegate> delegate;

-(NSView *)makeLauncherSurfaceView;
-(void)launcherSurfaceDidAppear;
-(void)launcherSurfaceWillDisappear;
-(void)launcherSurfaceQueryDidChange:(nullable NSString *)query;
-(nullable BTTLauncherPluginSurfaceCommandResult *)handleLauncherInputCommand:(BTTLauncherPluginInputCommand)command;
-(BOOL)handleLauncherRawKeyEvent:(NSEvent *)event;
-(BOOL)launcherSurfaceShouldBypassGlobalKeyboardHandlingForEvent:(NSEvent *)event;
-(nullable NSString *)launcherSurfacePlaceholderText;
-(nullable NSString *)launcherSurfaceFooterHint;
-(nullable NSString *)launcherSurfaceStatusText;
-(CGSize)launcherSurfacePreferredContentSize;
-(CGSize)launcherSurfaceMinimumContentSize;
-(BOOL)launcherSurfaceKeepsLauncherPinned;
@end

@protocol BTTLauncherPluginInterface <NSObject>
@optional
@property (nullable, weak) id<BTTLauncherPluginDelegate> delegate;

+(NSString *)launcherPluginName;
+(NSString *)launcherPluginDescription;
+(NSString *)launcherPluginIcon;
+(nullable BTTPluginFormItem *)configurationFormItems;
-(void)didReceiveNewConfigurationValues:(nullable NSDictionary *)configurationValues;
-(nullable NSArray<BTTLauncherPluginResult *> *)launcherResultsForContext:(BTTLauncherPluginContext *)context;
-(void)loadLauncherResultsForContext:(BTTLauncherPluginContext *)context
                          completion:(BTTLauncherPluginResultsCompletion)completion;
-(nullable NSArray<BTTLauncherPluginResult *> *)launcherChildrenForItemIdentifier:(NSString *)itemIdentifier
                                                               childrenIdentifier:(nullable NSString *)childrenIdentifier
                                                                          context:(BTTLauncherPluginContext *)context;
-(void)loadLauncherChildrenForItemIdentifier:(NSString *)itemIdentifier
                          childrenIdentifier:(nullable NSString *)childrenIdentifier
                                     context:(BTTLauncherPluginContext *)context
                                  completion:(BTTLauncherPluginResultsCompletion)completion;
-(nullable BTTLauncherPluginActionResult *)performActionForItemIdentifier:(NSString *)itemIdentifier
                                                         actionIdentifier:(nullable NSString *)actionIdentifier
                                                                  context:(BTTLauncherPluginContext *)context;
-(nullable id<BTTLauncherPluginSurfaceInterface>)launcherSurfaceForItemIdentifier:(NSString *)itemIdentifier
                                                                 surfaceIdentifier:(nullable NSString *)surfaceIdentifier
                                                                           context:(BTTLauncherPluginContext *)context;
-(nullable BTTLauncherPluginResult *)launcherResultForInstance:(BTTLauncherPluginInstance *)instance
                                                       context:(BTTLauncherPluginContext *)context;
@end

NS_ASSUME_NONNULL_END

#endif
