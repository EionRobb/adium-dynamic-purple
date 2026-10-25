/* SPDX-License-Identifier: GPL-3.0-or-later */
#import <Cocoa/Cocoa.h>
@class ADPAccount;
@interface ADPBackend : NSObject {
    NSTask *task;
    NSFileHandle *input;
    NSArray *protocols;
    NSMutableDictionary *accounts;
    NSMutableDictionary *requests;
    NSUInteger generation;
    BOOL receivedProtocols;
    BOOL starting;
    BOOL stopping;
}
+ (ADPBackend *)sharedBackend;
- (NSArray *)protocols;
- (BOOL)start;
- (void)stop;
- (void)sendCommand:(NSDictionary *)command;
- (void)registerAccount:(ADPAccount *)account;
- (void)unregisterAccount:(ADPAccount *)account;
- (void)report:(NSString *)message;
@end
