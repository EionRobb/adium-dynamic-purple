/* SPDX-License-Identifier: GPL-3.0-or-later */
#import "ADPBackend.h"
#import "ADPAccount.h"
#import <Adium/ESDebugAILog.h>
#include <stdio.h>
#include <signal.h>
#include <fcntl.h>
#ifndef F_SETNOSIGPIPE
#define F_SETNOSIGPIPE 73
#endif

/* The build SDK is 10.6, but Adium runs on 10.8+ for this backend. */
@interface NSObject (ADPJSON)
+ (id)JSONObjectWithData:(NSData *)data options:(NSUInteger)options error:(NSError **)error;
+ (NSData *)dataWithJSONObject:(id)object options:(NSUInteger)options error:(NSError **)error;
@end
static NSString *requestKey(id value) { return [value description]; }

@interface ADPRequestPanel : NSWindowController <NSWindowDelegate> {
    NSDictionary *request;
    NSMutableDictionary *controls;
    ADPBackend *backend;
    BOOL finished;
}
- (id)initWithRequest:(NSDictionary *)event backend:(ADPBackend *)client;
- (void)invalidate;
@end

@implementation ADPRequestPanel
- (id)initWithRequest:(NSDictionary *)event backend:(ADPBackend *)client
{
    NSArray *fields = [event objectForKey:@"fields"];
    CGFloat height = MIN(600, 180 + [fields count] * 48);
    NSPanel *panel = [[[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 520, height)
        styleMask:NSTitledWindowMask | NSClosableWindowMask backing:NSBackingStoreBuffered defer:NO] autorelease];
    if ((self = [super initWithWindow:panel])) {
        request = [event copy]; backend = client;
        controls = [[NSMutableDictionary alloc] init];
        [panel setTitle:[event objectForKey:@"title"] ?: @"Protocol request"];
        [panel setDelegate:self]; [panel setReleasedWhenClosed:NO];
        NSTextField *text = [[[NSTextField alloc] initWithFrame:NSMakeRect(16, height - 115, 488, 98)] autorelease];
        [text setEditable:NO]; [text setSelectable:YES]; [text setBezeled:NO]; [text setDrawsBackground:NO];
        [text setStringValue:[NSString stringWithFormat:@"%@\n%@\n%@", [event objectForKey:@"primary"] ?: @"", [event objectForKey:@"secondary"] ?: @"", [event objectForKey:@"message"] ?: @""]];
        [[panel contentView] addSubview:text];
        NSScrollView *scroll = [[[NSScrollView alloc] initWithFrame:NSMakeRect(12, 56, 496, MAX(0, height - 175))] autorelease];
        [scroll setHasVerticalScroller:YES];
        CGFloat formHeight = MAX(height - 175, [fields count] * 48);
        NSView *form = [[[NSView alloc] initWithFrame:NSMakeRect(0, 0, 472, formHeight)] autorelease];
        [scroll setDocumentView:form]; [[panel contentView] addSubview:scroll];
        CGFloat y = formHeight - 42;
        for (NSDictionary *field in fields) {
            NSString *key = [field objectForKey:@"id"];
            if (![key isKindOfClass:[NSString class]]) continue;
            NSTextField *label = [[[NSTextField alloc] initWithFrame:NSMakeRect(4, y + 20, 460, 18)] autorelease];
            [label setEditable:NO]; [label setBezeled:NO]; [label setDrawsBackground:NO];
            [label setStringValue:[field objectForKey:@"label"] ?: key]; [form addSubview:label];
            NSString *type = [field objectForKey:@"type"];
            id value = [field objectForKey:@"value"];
            NSControl *control;
            if ([type isEqual:@"bool"]) {
                NSButton *button = [[[NSButton alloc] initWithFrame:NSMakeRect(4, y, 460, 22)] autorelease];
                [button setButtonType:NSSwitchButton]; [button setTitle:@""]; [button setState:[value boolValue]]; control = button;
            } else if ([type isEqual:@"list"]) {
                NSPopUpButton *popup = [[[NSPopUpButton alloc] initWithFrame:NSMakeRect(4, y, 460, 24)] autorelease];
                for (NSDictionary *choice in [field objectForKey:@"values"]) {
                    [popup addItemWithTitle:@""]; [[popup lastItem] setTitle:[choice objectForKey:@"label"] ?: @""];
                    [[popup lastItem] setRepresentedObject:[choice objectForKey:@"value"]];
                    if ([value isEqual:[choice objectForKey:@"value"]]) [popup selectItem:[popup lastItem]];
                }
                control = popup;
            } else {
                Class kind = [[field objectForKey:@"masked"] boolValue] ? [NSSecureTextField class] : [NSTextField class];
                NSTextField *entry = [[[kind alloc] initWithFrame:NSMakeRect(4, y, 460, 22)] autorelease];
                [entry setStringValue:(value && value != [NSNull null]) ? [value description] : @""]; control = entry;
            }
            [control setEnabled:![[field objectForKey:@"readOnly"] boolValue]];
            [controls setObject:control forKey:key]; [form addSubview:control]; y -= 48;
        }
        CGFloat x = 504;
        NSArray *actions = [event objectForKey:@"actions"];
        if (![actions count]) actions = [NSArray arrayWithObject:[NSDictionary dictionaryWithObjectsAndKeys:@"Close", @"label", @-1, @"index", nil]];
        for (NSDictionary *action in [actions reverseObjectEnumerator]) {
            NSButton *button = [[[NSButton alloc] initWithFrame:NSMakeRect(x - 120, 12, 116, 32)] autorelease];
            [button setTitle:[action objectForKey:@"label"] ?: @"OK"]; [button setBezelStyle:NSRoundedBezelStyle];
            [button setTag:[[action objectForKey:@"index"] integerValue]]; [button setTarget:self]; [button setAction:@selector(answer:)];
            [[panel contentView] addSubview:button]; x -= 124;
        }
        [panel center];
    }
    return self;
}
- (void)answer:(NSButton *)button
{
    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    for (NSDictionary *field in [request objectForKey:@"fields"]) {
        NSString *key = [field objectForKey:@"id"]; NSControl *control = [controls objectForKey:key];
        id value = [control isKindOfClass:[NSButton class]] ? (id)[NSNumber numberWithBool:[(NSButton *)control state] == NSOnState] :
            ([control isKindOfClass:[NSPopUpButton class]] ? [[(NSPopUpButton *)control selectedItem] representedObject] : [control stringValue]);
        if ([[field objectForKey:@"type"] isEqual:@"int"]) value = [NSNumber numberWithInteger:[value integerValue]];
        if ([button tag] == 0 && [[field objectForKey:@"required"] boolValue] && ![[value description] length]) { NSBeep(); return; }
        if (value && key) [values setObject:value forKey:key];
    }
    finished = YES;
    if ([request objectForKey:@"request"]) [backend sendCommand:[NSDictionary dictionaryWithObjectsAndKeys:@"reply", @"command", [request objectForKey:@"request"], @"request",
        [NSNumber numberWithInteger:[button tag]], @"action", values, @"values", nil]];
    [[self window] close];
}
- (BOOL)windowShouldClose:(id)sender
{
    if (!finished && [request objectForKey:@"request"]) {
        finished = YES;
        [backend sendCommand:[NSDictionary dictionaryWithObjectsAndKeys:@"reply", @"command", [request objectForKey:@"request"], @"request", @-1, @"action", nil]];
    }
    return YES;
}
- (void)windowWillClose:(NSNotification *)notification
{
    [backend performSelector:@selector(dismissPanel:) withObject:self afterDelay:0];
}
- (void)invalidate { finished = YES; [[self window] close]; }
- (void)dealloc { [[self window] setDelegate:nil]; [request release]; [controls release]; [super dealloc]; }
@end

@implementation ADPBackend
- (void)dismissPanel:(ADPRequestPanel *)panel
{
    for (NSString *key in [[[requests allKeys] copy] autorelease])
        if ([requests objectForKey:key] == panel) [requests removeObjectForKey:key];
}
+ (ADPBackend *)sharedBackend
{
    static ADPBackend *shared;
    if (!shared) shared = [[self alloc] init];
    return shared;
}
- (id)init
{
    if ((self = [super init])) {
        accounts = [[NSMutableDictionary alloc] init]; requests = [[NSMutableDictionary alloc] init];
        protocols = [[NSArray alloc] initWithContentsOfFile:[self metadataPath]];
        if (!protocols) protocols = [[NSArray alloc] init];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationWillTerminate:)
            name:NSApplicationWillTerminateNotification object:nil];
    }
    return self;
}
- (NSString *)metadataPath
{
    return [[[NSProcessInfo processInfo] environment] objectForKey:@"ADP_METADATA_PATH"] ?:
        [@"~/Library/Application Support/Adium DynamicPurple/protocols.plist" stringByExpandingTildeInPath];
}
- (void)report:(NSString *)message
{
    NSLog(@"[DynamicPurple] %@", message); AILog(@"[DynamicPurple] %@", message);
    NSString *path = [[[NSProcessInfo processInfo] environment] objectForKey:@"ADP_LOG_PATH"] ?:
        [@"~/Library/Logs/DynamicPurple.log" stringByExpandingTildeInPath];
    [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:NULL];
    FILE *file = fopen([path fileSystemRepresentation], "a");
    if (file) { fprintf(file, "%s [DynamicPurple] %s\n", [[[NSDate date] description] UTF8String], [message UTF8String]); fclose(file); }
}
- (NSArray *)protocols { return protocols; }
- (void)registerAccount:(ADPAccount *)account
{
    if (account.internalObjectID) [accounts setObject:[NSValue valueWithNonretainedObject:account] forKey:account.internalObjectID];
}
- (void)unregisterAccount:(ADPAccount *)account
{
    if ([[accounts objectForKey:account.internalObjectID] nonretainedObjectValue] == account) [accounts removeObjectForKey:account.internalObjectID];
}
- (BOOL)start
{
    if (task && [task isRunning]) return YES;
    if (starting || stopping) return NO;
    starting = YES; receivedProtocols = NO;
    NSString *helper = [[NSBundle bundleForClass:[self class]] pathForAuxiliaryExecutable:@"macports-purple-backend"];
    if (!helper) helper = [[[NSBundle bundleForClass:[self class]] bundlePath] stringByAppendingPathComponent:@"Contents/MacOS/macports-purple-backend"];
    [task release]; task = [[NSTask alloc] init];
    [task setLaunchPath:helper];
    NSMutableDictionary *environment = [NSMutableDictionary dictionaryWithDictionary:[[NSProcessInfo processInfo] environment]];
    /* A helper must resolve MacPorts dylibs independently of Adium's frameworks. */
    for (NSString *key in [[[environment allKeys] copy] autorelease])
        if ([key hasPrefix:@"DYLD_"]) [environment removeObjectForKey:key];
    [environment setObject:@"/opt/local/bin:/opt/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin" forKey:@"PATH"];
    [task setEnvironment:environment];
    NSPipe *commands = [NSPipe pipe], *events = [NSPipe pipe], *errors = [NSPipe pipe];
    [task setStandardInput:commands]; [task setStandardOutput:events]; [task setStandardError:errors];
    [input release]; input = [[commands fileHandleForWriting] retain];
    fcntl([input fileDescriptor], F_SETNOSIGPIPE, 1);
    generation++;
    @try { [task launch]; }
    @catch (NSException *exception) { [self report:[NSString stringWithFormat:@"Cannot launch system libpurple backend: %@", [exception reason]]]; starting = NO; return NO; }
    NSDictionary *reader = [NSDictionary dictionaryWithObjectsAndKeys:[events fileHandleForReading], @"handle", [NSNumber numberWithUnsignedInteger:generation], @"generation", [NSNumber numberWithBool:NO], @"stderr", nil];
    [NSThread detachNewThreadSelector:@selector(readStream:) toTarget:self withObject:reader];
    reader = [NSDictionary dictionaryWithObjectsAndKeys:[errors fileHandleForReading], @"handle", [NSNumber numberWithUnsignedInteger:generation], @"generation", [NSNumber numberWithBool:YES], @"stderr", nil];
    [NSThread detachNewThreadSelector:@selector(readStream:) toTarget:self withObject:reader];
    [self sendCommand:[NSDictionary dictionaryWithObject:@"discover" forKey:@"command"]];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:15];
    while (!receivedProtocols && [task isRunning] && [deadline timeIntervalSinceNow] > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    starting = NO;
    if (!receivedProtocols) { [self report:@"Backend discovery did not complete; check MacPorts libpurple and json-glib installation. Cached services are retained."]; [self stop]; return NO; }
    return YES;
}
- (void)readStream:(NSDictionary *)reader
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSMutableData *buffer = [NSMutableData data]; BOOL errors = [[reader objectForKey:@"stderr"] boolValue];
    NSFileHandle *handle = [reader objectForKey:@"handle"];
    @try {
        while (YES) {
            NSAutoreleasePool *iteration = [[NSAutoreleasePool alloc] init];
            NSData *chunk = [handle availableData];
            if (![chunk length]) { [iteration drain]; break; }
            [buffer appendData:chunk];
            if ([buffer length] > 8 * 1024 * 1024) { [iteration drain]; break; }
            NSUInteger consumed = 0; const unsigned char *bytes = [buffer bytes];
            for (NSUInteger i = 0; i < [buffer length]; i++) if (bytes[i] == '\n') {
                NSData *line = [NSData dataWithBytes:bytes + consumed length:i - consumed]; consumed = i + 1;
                id event = errors ? (id)[[[NSString alloc] initWithData:line encoding:NSUTF8StringEncoding] autorelease] :
                    [NSClassFromString(@"NSJSONSerialization") JSONObjectWithData:line options:0 error:NULL];
                if (event) [self performSelectorOnMainThread:@selector(deliver:) withObject:[NSDictionary dictionaryWithObjectsAndKeys:event, @"payload", [reader objectForKey:@"generation"], @"generation", [reader objectForKey:@"stderr"], @"stderr", nil] waitUntilDone:NO];
            }
            if (consumed) [buffer replaceBytesInRange:NSMakeRange(0, consumed) withBytes:NULL length:0];
            [iteration drain];
        }
    } @catch (NSException *exception) { /* EOF/closed pipe is handled below. */ }
    if (!errors) [self performSelectorOnMainThread:@selector(backendEnded:) withObject:[reader objectForKey:@"generation"] waitUntilDone:NO];
    [pool drain];
}
- (void)deliver:(NSDictionary *)envelope
{
    if ([[envelope objectForKey:@"generation"] unsignedIntegerValue] != generation) return;
    id payload = [envelope objectForKey:@"payload"];
    if ([[envelope objectForKey:@"stderr"] boolValue]) {
        /* Do not copy arbitrary third-party debug output to persistent logs. */
        if ([payload hasPrefix:@"dyld["] || [payload hasPrefix:@"  Library not loaded:"])
            [self report:payload];
        return;
    }
    if (![payload isKindOfClass:[NSDictionary class]]) return;
    NSDictionary *event = payload; NSString *kind = [event objectForKey:@"event"];
    if ([kind isEqual:@"protocols"]) {
        NSArray *found = [event objectForKey:@"protocols"];
        if (![found isKindOfClass:[NSArray class]]) return;
        [protocols release]; protocols = [found copy]; receivedProtocols = YES;
        NSString *path = [self metadataPath];
        [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent] withIntermediateDirectories:YES
            attributes:[NSDictionary dictionaryWithObject:@0700 forKey:NSFilePosixPermissions] error:NULL];
        [protocols writeToFile:path atomically:YES];
        [self report:[NSString stringWithFormat:@"System backend discovered %lu protocols (libpurple %@)", (unsigned long)[protocols count], [event objectForKey:@"purpleVersion"] ?: @"unknown"]];
    } else if ([kind isEqual:@"request"]) {
        id identifier = [event objectForKey:@"request"];
        if (!identifier) return;
        ADPRequestPanel *panel = [[[ADPRequestPanel alloc] initWithRequest:event backend:self] autorelease];
        [requests setObject:panel forKey:requestKey(identifier)]; [panel showWindow:nil];
    } else if ([kind isEqual:@"requestClosed"]) {
        NSString *key = requestKey([event objectForKey:@"request"]);
        [[requests objectForKey:key] invalidate]; [requests removeObjectForKey:key];
    } else if ([kind isEqual:@"notification"]) {
        NSString *uri = [event objectForKey:@"uri"];
        if ([uri isKindOfClass:[NSString class]]) {
            NSURL *url = [NSURL URLWithString:uri];
            if ([[[url scheme] lowercaseString] isEqual:@"https"] || [[[url scheme] lowercaseString] isEqual:@"http"])
                [[NSWorkspace sharedWorkspace] openURL:url];
            return;
        }
        ADPRequestPanel *panel = [[[ADPRequestPanel alloc] initWithRequest:event backend:self] autorelease];
        [requests setObject:panel forKey:[NSString stringWithFormat:@"notification:%p", panel]]; [panel showWindow:nil];
    } else if ([kind isEqual:@"backendError"]) {
        [self report:[event objectForKey:@"message"] ?: @"System libpurple backend reported an error"];
    } else {
        ADPAccount *account = [[accounts objectForKey:[event objectForKey:@"account"] ?: @""] nonretainedObjectValue];
        if (account) [account handleBackendEvent:event];
    }
}
- (void)sendCommand:(NSDictionary *)command
{
    if ((!task || ![task isRunning]) && !starting && !stopping) {
        if (![self start]) {
            ADPAccount *account = [[accounts objectForKey:[command objectForKey:@"account"] ?: @""] nonretainedObjectValue];
            [account handleBackendEvent:[NSDictionary dictionaryWithObjectsAndKeys:@"disconnected", @"event", account.internalObjectID, @"account", @"System libpurple backend could not start. Check ~/Library/Logs/DynamicPurple.log.", @"error", @1, @"reason", nil]];
            return;
        }
    }
    NSData *json = [NSClassFromString(@"NSJSONSerialization") dataWithJSONObject:command options:0 error:NULL];
    if (!json || !input) return;
    NSMutableData *line = [NSMutableData dataWithData:json]; [line appendBytes:"\n" length:1];
    @try { [input writeData:line]; }
    @catch (NSException *exception) { [self backendEnded:[NSNumber numberWithUnsignedInteger:generation]]; }
}
- (void)backendEnded:(NSNumber *)endedGeneration
{
    if ([endedGeneration unsignedIntegerValue] != generation || stopping) return;
    generation++;
    [self report:@"System libpurple backend exited; its accounts have been disconnected. Reconnect to start a new backend."];
    for (ADPRequestPanel *panel in [requests allValues]) [panel invalidate]; [requests removeAllObjects];
    for (NSString *key in [[[accounts allKeys] copy] autorelease]) {
        ADPAccount *account = [[accounts objectForKey:key] nonretainedObjectValue];
        [account handleBackendEvent:[NSDictionary dictionaryWithObjectsAndKeys:@"disconnected", @"event", key, @"account", @"The system libpurple backend exited.", @"error", @1, @"reason", nil]];
    }
    [input closeFile]; [input release]; input = nil;
    if ([task isRunning]) [task terminate];
    [task release]; task = nil;
}
- (void)applicationWillTerminate:(NSNotification *)notification { [self stop]; }
- (void)finishTask:(NSTask *)finishedTask
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2];
    while ([finishedTask isRunning] && [deadline timeIntervalSinceNow] > 0) [NSThread sleepForTimeInterval:0.02];
    if ([finishedTask isRunning]) [finishedTask terminate];
    [pool drain];
}
- (void)stop
{
    stopping = YES; generation++;
    for (ADPRequestPanel *panel in [requests allValues]) [panel invalidate]; [requests removeAllObjects];
    @try { [input closeFile]; } @catch (NSException *exception) {}
    [input release]; input = nil;
    if (task && [task isRunning]) [NSThread detachNewThreadSelector:@selector(finishTask:) toTarget:self withObject:task];
    [task release]; task = nil; stopping = NO;
}
@end
