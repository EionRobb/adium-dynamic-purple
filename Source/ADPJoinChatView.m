/* SPDX-License-Identifier: GPL-3.0-or-later */
#import "ADPJoinChatView.h"
#import "ADPAccount.h"
#import "ADPBackend.h"
#import <Adium/DCJoinChatWindowController.h>

@implementation ADPJoinChatView
- (id)init
{
    if ((self = [super init])) {
        view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 100)];
        fields = [[NSMutableDictionary alloc] init];
        required = [[NSMutableSet alloc] init];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(chatFieldsChanged:) name:ADPChatFieldsChangedNotification object:nil];
    }
    return self;
}
- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; [fields release]; [required release]; [super dealloc]; }
- (void)validate
{
    BOOL valid = available;
    for (NSString *key in required) if (![[[fields objectForKey:key] stringValue] length]) valid = NO;
    if ([delegate respondsToSelector:@selector(setJoinChatEnabled:)]) [delegate setJoinChatEnabled:valid];
}
- (void)controlTextDidChange:(NSNotification *)notification { [self validate]; }
- (void)buildFieldsForAccount:(AIAccount *)inAccount
{

    for (NSView *child in [[[view subviews] copy] autorelease]) [child removeFromSuperview];
    [fields removeAllObjects]; [required removeAllObjects];
    NSDictionary *metadata = [(ADPAccount *)inAccount protocolDescriptor];
    available = inAccount.online && [[metadata objectForKey:@"chat"] boolValue];
    /* The wire contract has no live chat_info request. Honor optional serialized
     * chatFields; otherwise accept a room plus arbitrary protocol component keys. */
    NSArray *entries = [metadata objectForKey:@"chatFields"];
    if (!entries) entries = [NSArray arrayWithObjects:
        [NSDictionary dictionaryWithObjectsAndKeys:@"room", @"key", @"Room", @"label", [NSNumber numberWithBool:YES], @"required", nil],
        [NSDictionary dictionaryWithObjectsAndKeys:@"_components", @"key", @"Other fields (key=value; ...)", @"label", nil], nil];
    CGFloat height = MAX(60, 12 + [entries count] * 34);
    [view setFrameSize:NSMakeSize(400, height)];
    CGFloat y = height - 32;
    for (NSDictionary *entry in entries) {
        NSString *key = [entry objectForKey:@"key"];
        if (![key length]) continue;
        NSTextField *label = [[[NSTextField alloc] initWithFrame:NSMakeRect(0, y, 155, 24)] autorelease];
        [label setEditable:NO]; [label setBezeled:NO]; [label setDrawsBackground:NO];
        [label setStringValue:[entry objectForKey:@"label"] ?: key]; [view addSubview:label];
        Class type = [[entry objectForKey:@"masked"] boolValue] ? [NSSecureTextField class] : [NSTextField class];
        NSTextField *field = [[[type alloc] initWithFrame:NSMakeRect(160, y, 235, 24)] autorelease];
        [field setStringValue:[[entry objectForKey:@"default"] description] ?: @""];
        if ([[entry objectForKey:@"type"] isEqualToString:@"int"]) {
            NSNumberFormatter *formatter = [[[NSNumberFormatter alloc] init] autorelease];
            [formatter setAllowsFloats:NO]; [field setFormatter:formatter];
        }
        [field setDelegate:self]; [view addSubview:field]; [fields setObject:field forKey:key];
        if ([[entry objectForKey:@"required"] boolValue]) [required addObject:key];
        y -= 34;
    }
    [self validate];
}
- (void)configureForAccount:(AIAccount *)inAccount
{
    [super configureForAccount:inAccount];
    [self buildFieldsForAccount:inAccount];
    if (available) [[ADPBackend sharedBackend] sendCommand:[NSDictionary dictionaryWithObjectsAndKeys:
        @"chatInfo", @"command", inAccount.internalObjectID, @"account", nil]];
}
- (void)chatFieldsChanged:(NSNotification *)notification
{
    if ([notification object] != account) return;
    NSMutableDictionary *entered = [NSMutableDictionary dictionary];
    for (NSString *key in fields) [entered setObject:[[fields objectForKey:key] stringValue] forKey:key];
    [self buildFieldsForAccount:account];
    for (NSString *key in entered) if ([fields objectForKey:key]) [[fields objectForKey:key] setStringValue:[entered objectForKey:key]];
    [self validate];
}
- (void)joinChatWithAccount:(AIAccount *)inAccount
{
    if (!available || !inAccount.online) return;
    NSMutableDictionary *components = [NSMutableDictionary dictionary];
    NSString *fallback = nil;
    for (NSString *key in [[fields allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        NSString *value = [[fields objectForKey:key] stringValue];
        if (![value length] && [required containsObject:key]) return;
        if ([key isEqualToString:@"_components"]) {
            for (NSString *pair in [value componentsSeparatedByString:@";"]) {
                NSRange separator = [pair rangeOfString:@"="];
                if (separator.location == NSNotFound) continue;
                NSString *component = [[pair substringToIndex:separator.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if ([component length]) [components setObject:[pair substringFromIndex:separator.location + 1] forKey:component];
            }
        } else {
            [components setObject:value forKey:key];
            if (!fallback && [value length]) fallback = value;
        }
    }
    NSString *name = [components objectForKey:@"room"] ?: ([components objectForKey:@"channel"] ?: fallback);
    if ([name length]) [self doJoinChatWithName:name onAccount:inAccount chatCreationInfo:components invitingContacts:nil withInvitationMessage:nil];
}
@end

