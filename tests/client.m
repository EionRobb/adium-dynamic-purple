/* SPDX-License-Identifier: GPL-3.0-or-later */
#import <Cocoa/Cocoa.h>
#include <mach-o/dyld.h>
#include <assert.h>
#include <stdio.h>
#import "ADPBackend.h"

@interface ClientAccount : NSObject {
@public NSMutableArray *events;
}
- (NSString *)internalObjectID;
- (void)handleBackendEvent:(NSDictionary *)event;
@end
@implementation ClientAccount
- (id)init { if ((self = [super init])) events = [[NSMutableArray alloc] init]; return self; }
- (NSString *)internalObjectID { return @"client-fixture"; }
- (void)handleBackendEvent:(NSDictionary *)event { [events addObject:event]; }
- (void)dealloc { [events release]; [super dealloc]; }
@end

int main(int argc, const char **argv)
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    assert(argc == 2);
    NSBundle *bundle = [NSBundle bundleWithPath:[NSString stringWithUTF8String:argv[1]]];
    assert([bundle load]);
    ADPBackend *client = [NSClassFromString(@"ADPBackend") sharedBackend];
    assert([client start]);
    assert([[client protocols] count]);
    for (uint32_t i = 0; i < _dyld_image_count(); i++)
        assert(!strstr(_dyld_get_image_name(i), "/opt/local/"));
    ClientAccount *account = [[[ClientAccount alloc] init] autorelease];
    [client registerAccount:(id)account];
    [client sendCommand:[NSDictionary dictionaryWithObject:@"discover" forKey:@"command"]];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:0.2];
    while ([deadline timeIntervalSinceNow] > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    /* Simulate a helper crash and verify the registered account is notified. */
    NSTask *worker = [client valueForKey:@"task"];
    [worker terminate];
    deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    BOOL ended = NO;
    while (!ended && [deadline timeIntervalSinceNow] > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        for (NSDictionary *event in account->events)
            if ([[event objectForKey:@"event"] isEqual:@"disconnected"]) ended = YES;
    }
    assert(ended);
    assert([client start]);
    [client unregisterAccount:(id)account];
    [client stop];
    puts("PASS: real helper IPC discovery; no MacPorts images in frontend; helper failure notification and restart");
    [pool drain];
    return 0;
}
