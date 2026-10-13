// Minimal stand-in for BetterTouchTool's launcher plugin host. Loads the
// compiled plugin, calls it through the public plugin protocol and saves
// screenshots of the Notes browser surface. Run through run-tests.py --e2e,
// which builds a synthetic Notes library and points the plugin at it.

#import <Cocoa/Cocoa.h>
#import "BTTSwiftPluginHeader.h"
#include <dlfcn.h>

#include "GeneratedPluginConstants.inc"

@implementation BTTPluginFormItem @end
@implementation BTTLauncherPluginShortcut @end
@implementation BTTLauncherPluginCommand @end
@implementation BTTLauncherPluginResult @end
@implementation BTTLauncherPluginInstance @end
@implementation BTTLauncherPluginContext @end
@implementation BTTLauncherPluginActionResult @end
@implementation BTTLauncherPluginSurfaceCommandResult @end

@interface HostDelegate : NSObject <BTTLauncherPluginSurfaceDelegate>
@property NSInteger refreshRequests;
@property NSInteger surfaceUpdates;
@end

@implementation HostDelegate
- (void)setVariable:(NSString *)name value:(id)value {}
- (id)getVariable:(NSString *)name { return nil; }
- (void)executeNamedTrigger:(NSString *)triggerName {}
- (void)requestLauncherResultsRefresh { self.refreshRequests++; }
- (NSString *)replaceVariablesInString:(NSString *)string extraVariables:(NSDictionary *)extraVariables { return string; }
- (NSArray<BTTLauncherPluginInstance *> *)launcherPluginInstancesForPluginIdentifier:(NSString *)pluginIdentifier launcherID:(NSString *)launcherID { return @[]; }
- (BTTLauncherPluginInstance *)saveLauncherPluginInstance:(BTTLauncherPluginInstance *)instance pluginIdentifier:(NSString *)pluginIdentifier launcherID:(NSString *)launcherID { return instance; }
- (void)deleteLauncherPluginInstance:(NSString *)instanceIdentifier pluginIdentifier:(NSString *)pluginIdentifier launcherID:(NSString *)launcherID {}
- (NSArray<NSDictionary<NSString *, id> *> *)launcherGroupsForLauncherID:(NSString *)launcherID { return @[]; }
- (void)requestLauncherSurfaceUpdate { self.surfaceUpdates++; }
- (void)requestLauncherSurfaceGoBack {}
- (void)requestLauncherSurfaceClose {}
@end

// cacheDisplayInRect: does not draw the window background, so screenshots get
// an explicit appearance-aware one.
@interface BackgroundView : NSView
@end

@implementation BackgroundView
- (void)drawRect:(NSRect)dirtyRect {
    [[NSColor windowBackgroundColor] setFill];
    NSRectFill(dirtyRect);
}
@end

static int failures = 0;

static void Check(BOOL condition, NSString *message) {
    if (!condition) {
        failures++;
        printf("FAILED: %s\n", message.UTF8String);
    }
}

static void Spin(NSTimeInterval seconds) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while ([until timeIntervalSinceNow] > 0) {
        [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    }
}

static BTTLauncherPluginContext *Context(NSString *query) {
    BTTLauncherPluginContext *context = [BTTLauncherPluginContext new];
    context.query = query;
    context.launcherID = @"default";
    context.timestamp = [NSDate date];
    return context;
}

static NSArray<BTTLauncherPluginResult *> *Results(id<BTTLauncherPluginInterface> plugin, NSString *query) {
    __block NSArray<BTTLauncherPluginResult *> *results = nil;
    __block BOOL done = NO;
    [plugin loadLauncherResultsForContext:Context(query) completion:^(NSArray<BTTLauncherPluginResult *> *value) {
        results = value;
        done = YES;
    }];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10];
    while (!done && [deadline timeIntervalSinceNow] > 0) {
        [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    Check(done, [NSString stringWithFormat:@"results for \"%@\" arrive", query]);
    return results ?: @[];
}

static void PrintResults(NSString *query, NSArray<BTTLauncherPluginResult *> *results) {
    printf("\nQuery \"%s\" -> %lu results\n", query.UTF8String, (unsigned long)results.count);
    for (BTTLauncherPluginResult *result in results) {
        NSMutableArray *commands = [NSMutableArray array];
        for (BTTLauncherPluginCommand *command in result.commands) {
            [commands addObject:[NSString stringWithFormat:@"%@%@", command.title,
                                 command.shortcut ? [NSString stringWithFormat:@" (%@)", [command.shortcut.displayKeys componentsJoinedByString:@""]] : @""]];
        }
        printf("  [%s] %s\n      %s\n      score=%s action=%s surface=%s icon=%s\n      commands: %s\n",
               result.itemIdentifier.UTF8String, result.title.UTF8String, (result.subtitle ?: @"").UTF8String,
               (result.searchMatchPriority.stringValue ?: @"-").UTF8String, (result.primaryActionIdentifier ?: @"-").UTF8String,
               (result.surfaceIdentifier ?: @"-").UTF8String, (result.systemImageName ?: (result.iconImage ? @"image" : @"-")).UTF8String,
               [commands componentsJoinedByString:@", "].UTF8String);
    }
}

static NSArray<NSString *> *Identifiers(NSArray<BTTLauncherPluginResult *> *results) {
    NSMutableArray *identifiers = [NSMutableArray array];
    for (BTTLauncherPluginResult *result in results) [identifiers addObject:result.itemIdentifier];
    return identifiers;
}

// Mirrors the host's validation in LauncherArgumentRequest(pluginPayload:target:).
static void CheckArgumentRequest(NSDictionary *payload, NSString *label) {
    Check(payload != nil, [label stringByAppendingString:@" returns a form"]);
    if (!payload) return;
    Check([NSJSONSerialization isValidJSONObject:payload], [label stringByAppendingString:@" is JSON"]);
    Check([payload[@"id"] length] > 0 && [payload[@"title"] length] > 0, [label stringByAppendingString:@" has id and title"]);
    NSRegularExpression *names = [NSRegularExpression regularExpressionWithPattern:@"^[A-Za-z_][A-Za-z0-9_.-]*$" options:0 error:nil];
    NSMutableSet *fieldNames = [NSMutableSet set];
    for (NSDictionary *field in payload[@"fields"]) {
        NSString *name = field[@"name"];
        Check([names numberOfMatchesInString:name options:0 range:NSMakeRange(0, name.length)] == 1, [label stringByAppendingFormat:@" field %@ name", name]);
        [fieldNames addObject:name];
        if ([field[@"kind"] isEqual:@"choice"]) {
            NSArray *options = field[@"options"];
            Check(options.count > 0 && options.count <= 100, [label stringByAppendingString:@" choice has 1-100 options"]);
            NSString *defaultValue = field[@"defaultValue"];
            if (defaultValue) {
                Check([[options valueForKey:@"value"] containsObject:defaultValue], [label stringByAppendingString:@" default is an option"]);
            }
        }
    }
    for (NSString *key in [payload[@"contextBindings"] allKeys]) {
        Check([fieldNames containsObject:key], [label stringByAppendingFormat:@" binding %@ names a field", key]);
    }
    NSData *json = [NSJSONSerialization dataWithJSONObject:payload options:NSJSONWritingSortedKeys error:nil];
    printf("\n%s form: %s\n", label.UTF8String, [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
}

static void Snapshot(NSView *view, NSString *path) {
    [view layoutSubtreeIfNeeded];
    [view displayIfNeeded];
    NSBitmapImageRep *representation = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
    [view cacheDisplayInRect:view.bounds toBitmapImageRep:representation];
    [[representation representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
    printf("Saved %s\n", path.UTF8String);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 3) {
            fprintf(stderr, "usage: PluginHost <plugin dylib> <screenshot folder>\n");
            return 2;
        }
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

        if (!dlopen(argv[1], RTLD_NOW)) {
            fprintf(stderr, "dlopen failed: %s\n", dlerror());
            return 1;
        }
        NSString *screenshots = [NSString stringWithUTF8String:argv[2]];
        Class pluginClass = NSClassFromString(@"AppleNotesLauncherPlugin.AppleNotesLauncherPlugin");
        Check(pluginClass != Nil, @"principal class exists");
        Check([pluginClass conformsToProtocol:@protocol(BTTLauncherPluginInterface)], @"conforms to BTTLauncherPluginInterface");

        id<BTTLauncherPluginInterface> plugin = [[pluginClass alloc] init];
        HostDelegate *delegate = [HostDelegate new];
        plugin.delegate = delegate;
        printf("%s: %s (%s)\n", [pluginClass launcherPluginName].UTF8String,
               [pluginClass launcherPluginDescription].UTF8String, [pluginClass launcherPluginIcon].UTF8String);

        BTTPluginFormItem *form = [pluginClass configurationFormItems];
        NSMutableArray *fieldIDs = [NSMutableArray array];
        for (BTTPluginFormItem *item in form.formOptions) if (item.formFieldID) [fieldIDs addObject:item.formFieldID];
        printf("Configuration fields: %s\n", [fieldIDs componentsJoinedByString:@", "].UTF8String);
        [plugin didReceiveNewConfigurationValues:@{@"plugin_var_inlineLimit": @5, @"plugin_var_keywords": @"notes, n"}];

        for (NSString *selector in @[@"loadLauncherResultsForContext:completion:",
                                     @"launcherArgumentRequestForItemIdentifier:actionIdentifier:context:",
                                     @"performActionForItemIdentifier:actionIdentifier:context:argumentValues:capturedContext:",
                                     @"launcherSurfaceForItemIdentifier:surfaceIdentifier:context:"]) {
            Check([(id)plugin respondsToSelector:NSSelectorFromString(selector)], [@"responds to " stringByAppendingString:selector]);
        }

        NSArray *empty = Results(plugin, @"");
        PrintResults(@"", empty);
        Check([Identifiers(empty) isEqual:@[@"apple-notes"]], @"empty query returns only the root row");

        NSArray *groceries = Results(plugin, @"groceries");
        PrintResults(@"groceries", groceries);
        Check([Identifiers(groceries) containsObject:@"note:NOTE-10"], @"title match is returned inline");

        NSArray *body = Results(plugin, @"guanciale");
        PrintResults(@"guanciale", body);
        Check([Identifiers(body) containsObject:@"note:NOTE-12"], @"body match is returned inline");
        BTTLauncherPluginResult *bodyHit = body.lastObject;
        Check([bodyHit.subtitle containsString:@"guanciale"], @"body match shows a snippet");
        Check(bodyHit.searchMatchPriority.integerValue < 30, @"body-only match ranks below substring tier");

        NSArray *keyword = Results(plugin, @"notes road");
        PrintResults(@"notes road", keyword);
        Check([Identifiers(keyword) containsObject:@"note:NOTE-11"], @"keyword search finds the note");

        NSArray *browse = Results(plugin, @"notes");
        PrintResults(@"notes", browse);
        Check(browse.count >= 7, @"bare keyword browses recent notes");
        Check(![Identifiers(browse) containsObject:@"note:NOTE-17"], @"Recently Deleted stays hidden");

        NSArray *tagged = Results(plugin, @"#work");
        PrintResults(@"#work", tagged);
        Check([Identifiers(tagged) isEqual:@[@"apple-notes", @"note:NOTE-11"]], @"tag filter");

        NSArray *todo = Results(plugin, @"n has:todo");
        PrintResults(@"n has:todo", todo);
        Check([Identifiers(todo) isEqual:@[@"apple-notes", @"note:NOTE-10"]], @"open checklist filter after short keyword");

        NSArray *create = Results(plugin, @"new note Buy milk");
        PrintResults(@"new note Buy milk", create);
        Check([Identifiers(create) containsObject:@"apple-notes-create"], @"create row for create phrases");

        CheckArgumentRequest([plugin launcherArgumentRequestForItemIdentifier:@"apple-notes-create" actionIdentifier:@"create"
                                                                      context:Context(@"new note Buy milk")], @"Create");
        CheckArgumentRequest([plugin launcherArgumentRequestForItemIdentifier:@"note:NOTE-11" actionIdentifier:@"move"
                                                                      context:Context(@"")], @"Move");
        Check([plugin launcherArgumentRequestForItemIdentifier:@"note:NOTE-10" actionIdentifier:@"append" context:Context(@"")] != nil,
              @"append form for a note");
        BTTLauncherPluginActionResult *refused = [plugin performActionForItemIdentifier:@"note:NOTE-11" actionIdentifier:@"append"
                                                                               context:Context(@"") argumentValues:@{@"text": @"x"} capturedContext:@{}];
        Check(!refused.success, @"append refuses notes with tables and tags");
        printf("\nAppend to a note with a table: success=%d message=%s\n", refused.success, refused.message.UTF8String);

        id<BTTLauncherPluginSurfaceInterface> surface = [plugin launcherSurfaceForItemIdentifier:@"apple-notes" surfaceIdentifier:@"browser" context:Context(@"")];
        Check(surface != nil, @"browser surface");
        surface.delegate = delegate;
        NSView *surfaceView = [surface makeLauncherSurfaceView];
        CGSize size = [surface launcherSurfacePreferredContentSize];
        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, size.width, size.height)
                                                       styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
        window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
        window.contentView = [[BackgroundView alloc] initWithFrame:NSMakeRect(0, 0, size.width, size.height)];
        surfaceView.translatesAutoresizingMaskIntoConstraints = NO;
        [window.contentView addSubview:surfaceView];
        [NSLayoutConstraint activateConstraints:@[
            [surfaceView.leadingAnchor constraintEqualToAnchor:window.contentView.leadingAnchor],
            [surfaceView.trailingAnchor constraintEqualToAnchor:window.contentView.trailingAnchor],
            [surfaceView.topAnchor constraintEqualToAnchor:window.contentView.topAnchor],
            [surfaceView.bottomAnchor constraintEqualToAnchor:window.contentView.bottomAnchor],
        ]];
        [surface launcherSurfaceQueryDidChange:@""];
        [surface launcherSurfaceDidAppear];
        Spin(1.5);
        printf("\nSurface status: %s | placeholder: %s\n", [surface launcherSurfaceStatusText].UTF8String,
               [surface launcherSurfacePlaceholderText].UTF8String);
        Snapshot(window.contentView, [screenshots stringByAppendingPathComponent:@"browser-all.png"]);

        [surface handleLauncherInputCommand:BTTLauncherPluginInputCommandMoveDown];
        Spin(0.8);
        Snapshot(window.contentView, [screenshots stringByAppendingPathComponent:@"browser-table.png"]);

        [surface launcherSurfaceQueryDidChange:@"guanciale"];
        Spin(1.0);
        printf("Surface status after body search: %s\n", [surface launcherSurfaceStatusText].UTF8String);
        Snapshot(window.contentView, [screenshots stringByAppendingPathComponent:@"browser-search.png"]);

        [surface launcherSurfaceQueryDidChange:@"has:checklist"];
        window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
        Spin(1.0);
        Snapshot(window.contentView, [screenshots stringByAppendingPathComponent:@"browser-light.png"]);
        Check(delegate.surfaceUpdates > 0, @"surface requests status updates");
        [surface launcherSurfaceWillDisappear];

        id<BTTLauncherPluginSurfaceInterface> focused = [plugin launcherSurfaceForItemIdentifier:@"note:NOTE-13" surfaceIdentifier:@"browser" context:Context(@"")];
        focused.delegate = delegate;
        NSView *focusedView = [focused makeLauncherSurfaceView];
        focusedView.frame = window.contentView.bounds;
        focusedView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [surfaceView removeFromSuperview];
        [window.contentView addSubview:focusedView];
        [focused launcherSurfaceDidAppear];
        Spin(1.2);
        Snapshot(window.contentView, [screenshots stringByAppendingPathComponent:@"browser-focused.png"]);

        printf("\n%s (%d failures)\n", failures == 0 ? "End-to-end checks passed" : "End-to-end checks FAILED", failures);
        return failures == 0 ? 0 : 1;
    }
}
