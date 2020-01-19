//
//  BTTPluginInterface.h
//  BetterTouchTool
//
//  Created by Andreas Hegenberg on 20.06.19.
//

#import <Foundation/Foundation.h>
#import <Cocoa/Cocoa.h>

@class BTTPluginFormItem;

@protocol BTTTouchBarPluginDelegate

-(void)executeAssignedBTTActions:(id _Nonnull )sender;
-(void)updateWithString:(NSString*_Nonnull)string sender:(id _Nonnull )sender;

@end


@protocol BTTPluginInterface <NSObject>


@optional

// the delegate will be set automatically after this plugin is loaded in BTT
@property (nullable, weak) id <BTTTouchBarPluginDelegate> delegate;

//MARK: Side-Bar configuration:
// here you can configure what items are shown in the BTT configuration side-bar for this plugin
+(BTTPluginFormItem* _Nullable)configurationFormItems;


/*
 * You need to implement one of the
 * following 3 methods. If you implement
 * multiple, BTT will only execute the first,
 * trying in this order:
 */

/* MARK: Option 1: Returning a String
 * If you return a string here, it will be rendered on the
 * Touch Bar using the standard BetterTouchTool render widget.
 * This means all standard properties like background color
 * will be applied.
 */
-(NSString* _Nullable)touchBarTitleString;

/* MARK: Option 2: Returning a NSButton instance
 * if you return a button, BTT will just display that
 * button on the Touch Bar.
 * You are responsible for any styling you want to apply.
 * Make sure to always return the same instance of the button
 * here.
 */
-(NSButton* _Nullable)touchBarButton;

/* MARK: Option 3: Returning a NSViewController instance
 * if you return a view controller BTT will display the view
 * controller's view on
 * the Touch Bar.
 * You are responsible for any styling you want to apply.
 * Make sure to always return the same instance of the button
 * here.
 */
-(NSViewController* _Nullable)touchBarViewController;


// MARK: Executing BTT actions
// here you can configure what items are shown in the BTT configuration side-bar for this plugin
-(void)didReceiveNewConfigurationValues:(NSDictionary* _Nonnull)configurationValues;
@end

@protocol BTTActionPluginDelegate

// doesn't have any functionality yet

@end


@protocol BTTActionPluginInterface <NSObject>


//MARK: Side-Bar configuration:
// here you can configure what items are shown in the BTT configuration side-bar for this plugin
+(BTTPluginFormItem* _Nullable)configurationFormItems;

// MARK: Execute this action
// This will be called if the user has triggered the action through some trigger in BTT.
-(void)executeActionWithConfiguration:(NSDictionary* _Nullable)configurationValues completionBlock:(void (^)(_Nullable id))actionExecutedWithResult;

@optional
// by default the action name is specified in the info.plist, in case you want
// to display additional dynamic names, you can generate them here.
+(NSString* _Nullable)actionNameWithConfiguration:(NSDictionary* _Nullable)configurationValues;
// the delegate will be set automatically after this plugin is loaded in BTT
@property (nullable, weak) id <BTTActionPluginDelegate> delegate;


@end
