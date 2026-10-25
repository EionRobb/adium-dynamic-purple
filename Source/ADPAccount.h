/* SPDX-License-Identifier: GPL-3.0-or-later */
#import <Adium/AIAccount.h>
extern NSString * const ADPChatFieldsChangedNotification;
@interface ADPAccount : AIAccount {
    NSMutableDictionary *backendChats;
    NSMutableSet *pendingChats;
    NSArray *backendChatFields;
    NSString *lastBackendPassword;
    BOOL backendRegistered;
    BOOL disconnectRequested;
    NSString *backendStatus;
    NSString *backendStatusMessage;
}
- (NSDictionary *)protocolDescriptor;
- (id)protocolOptionValue:(NSDictionary *)option;
- (void)setProtocolOptionValues:(NSDictionary *)values;
- (void)handleBackendEvent:(NSDictionary *)event;
@end


