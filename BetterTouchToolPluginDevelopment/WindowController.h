//
//  WindowController.h
//  BetterTouchToolPluginDevelopment
//
//  Created by Andreas Hegenberg on 22.06.19.
//  Copyright © 2019 Andreas Hegenberg. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import "DemoTouchBarViewController.h"
#import "BTTPluginInterface.h"

NS_ASSUME_NONNULL_BEGIN

@interface WindowController : NSWindowController<NSTouchBarProvider,NSTouchBarDelegate>

@property (nonatomic, strong) NSTouchBar *touchBar;
@property (nonatomic, strong) NSCustomTouchBarItem* customItem;
@property (nonatomic, strong) DemoTouchBarViewController *touchBarViewController;
@property (nonatomic, copy) NSString *tbIdentifier;
@end

NS_ASSUME_NONNULL_END
