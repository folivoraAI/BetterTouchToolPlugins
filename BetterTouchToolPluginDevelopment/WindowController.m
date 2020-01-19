//
//  WindowController.m
//  BetterTouchToolPluginDevelopment
//
//  Created by Andreas Hegenberg on 22.06.19.
//  Copyright © 2019 Andreas Hegenberg. All rights reserved.
//

#import "WindowController.h"

@interface WindowController ()

@end

@implementation WindowController

- (void)windowDidLoad {
    [super windowDidLoad];
   // [self loadDevPluginBundles];
    [self makeTouchBar];
    // Implement this method to handle any initialization after your window controller's window has been loaded from its nib file.
    [self loadDevPluginBundles];
}


-(NSTouchBar*)makeTouchBar {
    self.tbIdentifier = @"BTTPluginDevTB";
    self.touchBarViewController = [[DemoTouchBarViewController alloc] init];
    NSTouchBar* bar = [[NSTouchBar alloc] init];
    bar.delegate = self;
    bar.defaultItemIdentifiers = @[ self.tbIdentifier ];
    self.touchBar = bar;

    return bar;
}

- (nullable NSTouchBarItem*)touchBar:(NSTouchBar*)touchBar makeItemForIdentifier:(NSTouchBarItemIdentifier)identifier
{
    
    if (!self.customItem) {
        self.customItem = [[NSCustomTouchBarItem alloc] initWithIdentifier:self.tbIdentifier];
        
        self.customItem.viewController = self.touchBarViewController;
        self.customItem.customizationLabel = @"";
    }
    
    return self.customItem;
}

-(void)loadDevPluginBundles {
    NSURL *appURL = [[[NSBundle mainBundle] bundleURL] URLByDeletingLastPathComponent];
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSDirectoryEnumerator* enumerator = [fileManager enumeratorAtURL:appURL includingPropertiesForKeys:nil options:0 errorHandler:^BOOL(NSURL * _Nonnull url, NSError * _Nonnull error) {
        NSLog(@"error %@", error);
        return NO;
    }];
    
    NSURL *file;
    CGFloat lastX = 0;
    while (file = [enumerator nextObject]) {
        
        if([file.pathExtension containsString:@"btttouchbarplugin"]) {
            
            NSBundle *bundle = [NSBundle bundleWithURL:file];
            
            NSDictionary *infoDictionary = [bundle infoDictionary];
            NSString *pluginName = [infoDictionary objectForKey:@"BTTPluginName"];
            NSString *pluginIdentifier = [infoDictionary objectForKey:@"BTTPluginIdentifier"];
            NSString *imageName = [infoDictionary objectForKey:@"BTTPluginIcon"];
            ;
            NSImage *pluginIcon = [[NSImage alloc] initWithContentsOfFile:[bundle pathForResource:imageName ofType:@"tiff"]] ;
            
            
            
            NSLog(@"found plugin %@ | %@ | icon %@ - loaded: %@", pluginName, pluginIdentifier, imageName, pluginIcon ? @"YES" : @"NO");
            
            NSView *touchbarView = nil;
            id<BTTPluginInterface> pluginInstance = [[[bundle principalClass] alloc] init];
            
            if([pluginInstance respondsToSelector:@selector(touchBarTitleString)]) {
                NSString *title = [pluginInstance touchBarTitleString];
                touchbarView = [NSButton buttonWithTitle:title target:nil action: nil];
            }
            if([pluginInstance respondsToSelector:@selector(touchBarButton)]) {
                touchbarView = [pluginInstance touchBarButton];
            }
            if(!touchbarView) {
                if([pluginInstance respondsToSelector:@selector(touchBarViewController)]) {
                    touchbarView = [pluginInstance touchBarViewController].view;
                }
            }
            
            if(touchbarView) {
                NSRect frame = touchbarView.frame;
                frame.origin.x += lastX+5;
                touchbarView.frame = frame;
                [self.touchBarViewController.view addSubview:touchbarView];
                lastX += touchbarView.frame.origin.x + touchbarView.frame.size.width;
            }
        }
    }
    
}



@end
