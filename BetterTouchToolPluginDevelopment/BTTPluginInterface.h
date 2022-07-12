//
//  BTTPluginInterface.h
//  BetterTouchTool
//
//  Created by Andreas Hegenberg on 20.06.19.
//

#import <Foundation/Foundation.h>
#import <Cocoa/Cocoa.h>

@class BTTPluginFormItem;


@protocol BTTStreamDeckPluginDelegate

-(void)executeAssignedBTTActions:(id _Nonnull )sender;
-(void)requestUpdate:(id _Nonnull )sender;

@end


@protocol BTTStreamDeckPluginInterface <NSObject>


@optional

// the delegate will be set automatically after this plugin is loaded in BTT
@property (nullable, weak) id <BTTStreamDeckPluginDelegate> delegate;

//MARK: Side-Bar configuration:
// here you can configure and return the form items are shown in the BTT configuration side-bar for this plugin
+(BTTPluginFormItem* _Nullable)configurationFormItems;

// This defines whether the appearance tab will be shown when configuring this plugin
+(BOOL)showAppearanceTab;
// This defines whether the alternate appearance tab will be shown when configuring this plugin
+(BOOL)showAlternateAppearanceTab;

// Return a dictionary with default configuation items here.
// (the ones you get when copying a trigger in BTT and looking at the BTTTriggerConfig object)
+(NSDictionary* _Nullable)defaultConfiguration;

/*
 * NOTE: NOT YET SUPPORTED
 *
 * This defines whether the buttons of this widget will be put into a group.
 * If you activate this,the first item in the arrays below always needs to be the
 * group item.
*/
 +(BOOL)groupWidgetButtons;
 

// MARK: RENDERING the Buttons

/*
 * If this returns true, BTT will attempt to render with alternate appearance
 */
-(BOOL)alternateModeActive;

/*
 * NOTE: while all the following methods return arrays,
 * currently only the first item in the array is being used.
 *
 * You need to implement one of the
 * following 4 methods. If you implement
 * multiple, BTT will only execute the first,
 * trying in this order:
 */

/* MARK: Option 1: Returning an Array of Strings
 * If you return an array of strings here, it will render one button
 * per string applying the appearance settings defined in BetterTouchTool.
 * This means all standard properties like background color
 * will be applied.
 */
-(NSArray<NSString*>* _Nullable)widgetTitleStrings;

/* MARK: Option 2: Returning an Array of Attributed Strings
 * If you return an array of attributed strings, BTT will render buttons
 * based on these but also apply additional styling as configured by the user
 * (e.g. background color)
 */
-(NSArray<NSAttributedString*>* _Nullable)widgetAttributedTitleStrings;

/* MARK: Option 3: Returning an Array of Dictionaries with the rendering description
 * You can return an array of dictionaries with the following keys. They might be mutually exclusive:
 * {
 "BTTStreamDeckBackgroundColor" : "80.954640, 96.000000, 94.000000, 255.000000",
 "BTTStreamDeckCornerRadius" : 13,
 "BTTStreamDeckImageReal": a real NSImage instance
 "BTTStreamDeckImage" : "base64imagesstring",
 "BTTStreamDeckImageOffsetY" : 2,
 "BTTStreamDeckImageOffsetX" : 2
 "BTTStreamDeckImageChangeColor" : 1,
 "BTTStreamDeckResizeImage" : 2,
 "BTTStreamDeckImageHeight" : 30,
 "BTTStreamDeckImageWidth" : 30,
 "BTTStreamDeckSFSymbolStyle" : 3,
 "BTTStreamDeckSFSymbolName" : "square.and.arrow.up.circle.fill",
 "BTTStreamDeckIconType" : 1,
 "BTTStreamDeckAlternateImageHeight" : 50,
 "BTTStreamDeckIconColor1" : "255.000000, 74.896763, 114.000000, 255.000000",
 "BTTStreamDeckIconColor2" : "255, 255, 255, 255",
 "BTTStreamDeckIconColor3" : "255, 255, 255, 255",
 "BTTStreamDeckAttributedTitleReal": a real NSAttributedString instance
 "BTTStreamDeckAttributedTitle" : "cnRmZAAAAAADAAAAAgAAAAcAAABUWFQucnRmAQAAAC6BAQAAKwAAAAEAAAB5AQAAe1xydGYxXGFuc2lcYW5zaWNwZzEyNTJcY29jb2FydGYyNjM4Clxjb2NvYXRleHRzY2FsaW5nMFxjb2NvYXBsYXRmb3JtMHtcZm9udHRibFxmMFxmbmlsXGZjaGFyc2V0MCBTRlByby1SZWd1bGFyO30Ke1xjb2xvcnRibDtccmVkMjU1XGdyZWVuMjU1XGJsdWUyNTU7XHJlZDI1NVxncmVlbjI1NVxibHVlMjU1O30Ke1wqXGV4cGFuZGVkY29sb3J0Ymw7O1xjc3NyZ2JcYzEwMDAwMFxjMTAwMDAwXGMxMDAwMDA7fQpccGFyZFx0eDU2MFx0eDExMjBcdHgxNjgwXHR4MjI0MFx0eDI4MDBcdHgzMzYwXHR4MzkyMFx0eDQ0ODBcdHg1MDQwXHR4NTYwMFx0eDYxNjBcdHg2NzIwXHBhcmRpcm5hdHVyYWxccWNccGFydGlnaHRlbmZhY3RvcjAKClxmMFxmczUwIFxjZjIgdGVzdH0BAAAAIwAAAAEAAAAHAAAAVFhULnJ0ZhAAAABk2cZitgEAAAAAAAAAAAAA",

}
 * The individual widget buttons will be rendered based on these descriptions.
 */
-(NSArray<NSDictionary*>* _Nullable)widgetDictionaries;


/* MARK: Option 4: Returning an Array of rendered Images
 * You can also just return an array of rendered images.
 * The images should be sized at around 140x140 (BTT will resize it to fit for any device)
 */
-(NSArray<NSImage*>* _Nullable)widgetImages;

// this will give you the current configuration values for your widget
// (as defined in the form you returned via configurationFormItems)
-(void)didReceiveNewConfigurationValues:(NSDictionary* _Nonnull)configurationValues;


// If you return more than one button you need to return an array of
// strings that identify the buttons in the same order as returned from
// widgetTitleStrings, widgetAttributedTitleStrings, widgetDictionaries or
// widgetImages
-(NSArray<NSString*>* _Nullable)buttonIdentifiers;

// called when the user presses the button down.
// return true to cancel assigned BTT actions.
-(BOOL)buttonDown:( NSString* _Nullable )identifier;

// called when the user releases the button
// return true to cancel assigned BTT actions.
-(BOOL)buttonUp:(NSInteger)identifier;
@end



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
-(void)executeActionWithConfiguration:(NSDictionary* _Nullable)configurationValues completionBlock:(void (^_Nullable)(_Nullable id))actionExecutedWithResult;

@optional
// by default the action name is specified in the info.plist, in case you want
// to display additional dynamic names, you can generate them here.
+(NSString* _Nullable)actionNameWithConfiguration:(NSDictionary* _Nullable)configurationValues;
// the delegate will be set automatically after this plugin is loaded in BTT
@property (nullable, weak) id <BTTActionPluginDelegate> delegate;


@end
