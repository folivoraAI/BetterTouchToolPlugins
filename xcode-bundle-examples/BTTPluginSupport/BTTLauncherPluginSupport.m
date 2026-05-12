//
//  BTTLauncherPluginSupport.m
//  BTTPluginSupport
//

#import "BTTLauncherPluginSupport.h"

@implementation BTTLauncherPluginShortcut
@end

@implementation BTTLauncherPluginCommand
@end

@implementation BTTLauncherPluginResult
@end

@implementation BTTLauncherPluginInstance

- (instancetype)init {
    self = [super init];
    if (self) {
        _isEnabled = YES;
    }
    return self;
}

@end

@implementation BTTLauncherPluginContext
@end

@implementation BTTLauncherPluginActionResult
@end

@implementation BTTLauncherPluginSurfaceCommandResult
@end
