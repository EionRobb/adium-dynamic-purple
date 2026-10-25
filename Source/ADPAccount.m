/* SPDX-License-Identifier: GPL-3.0-or-later */
#import "ADPAccount.h"
#import "ADPService.h"
#import "ADPBackend.h"
#import <Adium/AISharedAdium.h>
#import <Adium/AIAccountControllerProtocol.h>
#import <Adium/AIStatus.h>
#import <Adium/AIStatusControllerProtocol.h>
#import <Adium/AIChat.h>
#import <Adium/AIChatControllerProtocol.h>
#import <Adium/AIContentControllerProtocol.h>
#import <Adium/AIContentMessage.h>
#import <Adium/AIContentTyping.h>
#import <Adium/AIListContact.h>
#import <Adium/AIListGroup.h>
#import <Adium/AIHTMLDecoder.h>
#import <AIUtilities/AIKeychain.h>

NSString * const ADPChatFieldsChangedNotification = @"ADPChatFieldsChangedNotification";

/* IPC state accepts only libpurple's scalar preference types. */
static BOOL ADPStateScalar(id value)
{
    if ([value isKindOfClass:[NSString class]]) return YES;
    if (![value isKindOfClass:[NSNumber class]]) return NO;
    const char *type = [value objCType];
    return type && type[0] != 'f' && type[0] != 'd';
}
static NSString *ADPString(id value) { return [value isKindOfClass:[NSString class]] ? value : @""; }

@implementation ADPAccount
- (void)initAccount
{
    [super initAccount];
    backendChats = [[NSMutableDictionary alloc] init];
    pendingChats = [[NSMutableSet alloc] init];
    [self protocolDescriptor];
}
- (void)dealloc
{
    if (backendRegistered) [[ADPBackend sharedBackend] unregisterAccount:self];
    [backendChats release]; [pendingChats release]; [backendChatFields release];
    [backendStatus release]; [backendStatusMessage release]; [lastBackendPassword release];
    [super dealloc];
}
- (void)willBeDeleted
{
    [self disconnect];
    if (backendRegistered) { [[ADPBackend sharedBackend] unregisterAccount:self]; backendRegistered = NO; }
    for (NSDictionary *option in [[self protocolDescriptor] objectForKey:@"options"])
        if ([[option objectForKey:@"masked"] boolValue])
            [[AIKeychain defaultKeychain_error:NULL] deleteGenericPasswordForService:@"Adium DynamicPurple options"
                account:[self keychainNameForOption:option] error:NULL];
    [[AIKeychain defaultKeychain_error:NULL] deleteGenericPasswordForService:@"Adium DynamicPurple state"
        account:[self keychainNameForState] error:NULL];
    [super willBeDeleted];
}
- (NSDictionary *)protocolDescriptor
{
    NSDictionary *current = [(ADPService *)self.service protocolDescriptor];
    NSDictionary *saved = [self preferenceForKey:@"ProtocolDescriptor" group:@"DynamicPurple"];
    NSDictionary *base = saved ?: current;
    /* Store option schema for restored accounts, but never live room defaults. */
    if ([[current objectForKey:@"options"] isKindOfClass:[NSArray class]]) {
        NSMutableDictionary *persistent = [NSMutableDictionary dictionaryWithDictionary:current];
        [persistent removeObjectForKey:@"chatFields"];
        if (![saved isEqual:persistent]) [self setPreference:persistent forKey:@"ProtocolDescriptor" group:@"DynamicPurple"];
        base = current;
    }
    if (backendChatFields) {
        NSMutableDictionary *merged = [NSMutableDictionary dictionaryWithDictionary:base];
        [merged setObject:backendChatFields forKey:@"chatFields"];
        return merged;
    }
    return base;
}
- (NSString *)keychainNameForOption:(NSDictionary *)option
{
    return [NSString stringWithFormat:@"%@/%@/%@", [[self protocolDescriptor] objectForKey:@"id"], self.internalObjectID, [option objectForKey:@"key"]];
}
- (id)protocolOptionValue:(NSDictionary *)option
{
    id value = nil;
    if ([[option objectForKey:@"masked"] boolValue])
        value = [[AIKeychain defaultKeychain_error:NULL] findGenericPasswordForService:@"Adium DynamicPurple options"
            account:[self keychainNameForOption:option] keychainItem:NULL error:NULL];
    else value = [[self preferenceForKey:@"ProtocolOptions" group:@"DynamicPurple"] objectForKey:[option objectForKey:@"key"]];
    return value ?: [option objectForKey:@"default"];
}
- (NSString *)keychainNameForState
{
    return [NSString stringWithFormat:@"%@/%@", [[self protocolDescriptor] objectForKey:@"id"], self.internalObjectID];
}
- (NSDictionary *)opaqueProtocolState
{
    NSString *serialized = [[AIKeychain defaultKeychain_error:NULL] findGenericPasswordForService:@"Adium DynamicPurple state"
        account:[self keychainNameForState] keychainItem:NULL error:NULL];
    if (![serialized length]) return [NSDictionary dictionary];
    NSString *error = nil;
    id decoded = [NSPropertyListSerialization propertyListFromData:[serialized dataUsingEncoding:NSUTF8StringEncoding]
        mutabilityOption:NSPropertyListImmutable format:NULL errorDescription:&error];
    [error release];
    NSMutableDictionary *scalars = [NSMutableDictionary dictionary];
    if ([decoded isKindOfClass:[NSDictionary class]])
        for (id key in decoded)
            if ([key isKindOfClass:[NSString class]] && ADPStateScalar([decoded objectForKey:key]))
                [scalars setObject:[decoded objectForKey:key] forKey:key];
    return scalars;
}
- (void)saveOpaqueProtocolState:(NSDictionary *)state previous:(NSDictionary *)previous
{
    if ([state isEqual:previous]) return;
    AIKeychain *keychain = [AIKeychain defaultKeychain_error:NULL];
    NSString *name = [self keychainNameForState];
    if (![state count]) {
        [keychain deleteGenericPasswordForService:@"Adium DynamicPurple state" account:name error:NULL];
        return;
    }
    NSString *serializationError = nil;
    NSData *data = [NSPropertyListSerialization dataFromPropertyList:state format:NSPropertyListXMLFormat_v1_0 errorDescription:&serializationError];
    [serializationError release];
    NSString *serialized = data ? [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease] : nil;
    if (!serialized) { [[ADPBackend sharedBackend] report:@"Unable to serialize secure protocol state."]; return; }
    [keychain deleteGenericPasswordForService:@"Adium DynamicPurple state" account:name error:NULL];
    if (![keychain addGenericPassword:serialized forService:@"Adium DynamicPurple state" account:name keychainItem:NULL error:NULL])
        [[ADPBackend sharedBackend] report:@"Unable to save secure protocol state to Keychain."];
}
- (void)setProtocolOptionValues:(NSDictionary *)values
{
    [self setProtocolOptionValues:values complete:NO];
}
- (void)setProtocolOptionValues:(NSDictionary *)values complete:(BOOL)complete
{
    NSMutableDictionary *plain = [NSMutableDictionary dictionaryWithDictionary:([self preferenceForKey:@"ProtocolOptions" group:@"DynamicPurple"] ?: [NSDictionary dictionary])];
    NSMutableSet *declared = [NSMutableSet set];
    for (NSDictionary *option in [[self protocolDescriptor] objectForKey:@"options"]) {
        NSString *key = [option objectForKey:@"key"];
        [declared addObject:key];
        id value = [values objectForKey:key];
        if ([[option objectForKey:@"masked"] boolValue]) {
            if (value) {
                AIKeychain *keychain = [AIKeychain defaultKeychain_error:NULL];
                NSString *name = [self keychainNameForOption:option];
                NSString *old = [keychain findGenericPasswordForService:@"Adium DynamicPurple options" account:name keychainItem:NULL error:NULL];
                if ([old isEqualToString:[value description]]) { [plain removeObjectForKey:key]; continue; }
                NSError *error = nil;
                [keychain deleteGenericPasswordForService:@"Adium DynamicPurple options" account:name error:NULL];
                if (! [keychain addGenericPassword:[value description] forService:@"Adium DynamicPurple options" account:name keychainItem:NULL error:&error])
                    [[ADPBackend sharedBackend] report:[NSString stringWithFormat:@"Unable to save secure protocol option %@: %@", key, error]];
            }
            [plain removeObjectForKey:key];
        } else if (value) [plain setObject:value forKey:key];
    }
    NSDictionary *previous = [self opaqueProtocolState];
    NSMutableDictionary *state = complete ? [NSMutableDictionary dictionary] : [NSMutableDictionary dictionaryWithDictionary:previous];
    for (NSString *key in declared) [state removeObjectForKey:key];
    /* Partial UI updates preserve absent keys; full backend snapshots replace them. */
    for (id key in values)
        if ([key isKindOfClass:[NSString class]] && ![declared containsObject:key] && ADPStateScalar([values objectForKey:key]))
            [state setObject:[values objectForKey:key] forKey:key];
    [self saveOpaqueProtocolState:state previous:previous];
    if (![plain isEqual:[self preferenceForKey:@"ProtocolOptions" group:@"DynamicPurple"]])
        [self setPreference:plain forKey:@"ProtocolOptions" group:@"DynamicPurple"];
}
- (void)sendCommand:(NSString *)command values:(NSDictionary *)values
{
    NSMutableDictionary *message = [NSMutableDictionary dictionaryWithDictionary:values ?: [NSDictionary dictionary]];
    [message setObject:command forKey:@"command"];
    [message setObject:self.internalObjectID forKey:@"account"];
    [[ADPBackend sharedBackend] sendCommand:message];
}
- (NSString *)statusName:(AIStatus *)status
{
    switch (status.statusType) {
        case AIOfflineStatusType: return @"offline";
        case AIInvisibleStatusType: return @"invisible";
        case AIAwayStatusType: return [status.statusName isEqualToString:STATUS_NAME_DND] ? @"unavailable" : @"away";
        default: return @"available";
    }
}
- (BOOL)connectivityBasedOnNetworkReachability { return NO; }
- (void)connect
{
    if (self.online || [self boolValueForProperty:@"isConnecting"]) return;
    [super connect];
    disconnectRequested = NO;
    /* An initial backend echo must not save a temporary login credential. */
    [lastBackendPassword release]; lastBackendPassword = [(self.passwordWhileConnected ?: @"") copy];
    [backendChatFields release]; backendChatFields = nil;
    [self setLastDisconnectionError:nil];
    if (!backendRegistered) { backendRegistered = YES; [[ADPBackend sharedBackend] registerAccount:self]; }
    [self setValue:[NSNumber numberWithBool:YES] forProperty:@"isConnecting" notify:NotifyNow];
    NSDictionary *metadata = [self protocolDescriptor];
    NSMutableDictionary *options = [NSMutableDictionary dictionaryWithDictionary:[self opaqueProtocolState]];
    for (NSDictionary *option in [metadata objectForKey:@"options"]) {
        [options removeObjectForKey:[option objectForKey:@"key"]];
        id value = [self protocolOptionValue:option];
        if (value && value != [NSNull null]) {
            NSString *type = [option objectForKey:@"type"];
            if ([type isEqualToString:@"bool"]) value = [NSNumber numberWithBool:[value boolValue]];
            else if ([type isEqualToString:@"int"]) value = [NSNumber numberWithInteger:[value integerValue]];
            [options setObject:value forKey:[option objectForKey:@"key"]];
        }
    }
    [self sendCommand:@"connect" values:[NSDictionary dictionaryWithObjectsAndKeys:
        ADPString([metadata objectForKey:@"id"]), @"protocol", self.UID, @"username",
        lastBackendPassword, @"password", options, @"options",
        backendStatus ?: ((self.statusState && self.statusState.statusType != AIOfflineStatusType) ? [self statusName:self.statusState] : @"available"), @"status",
        backendStatusMessage ?: ([self.statusState.statusMessage string] ?: @""), @"statusMessage", nil]];
}
- (void)disconnect
{
    BOOL active = self.online || [self boolValueForProperty:@"isConnecting"];
    [super disconnect];
    disconnectRequested = YES;
    if (active) {
        [self setValue:[NSNumber numberWithBool:YES] forProperty:@"isDisconnecting" notify:NotifyNow];
        [self sendCommand:@"disconnect" values:nil];
    }
}
- (void)setStatusState:(AIStatus *)status usingStatusMessage:(NSAttributedString *)message
{
    [backendStatus release]; backendStatus = [[self statusName:status] copy];
    [backendStatusMessage release]; backendStatusMessage = [[message string] copy];
    if (status.statusType == AIOfflineStatusType) { [self disconnect]; return; }
    [self setValue:message forProperty:@"listObjectStatusMessage" notify:NotifyLater];
    [self setValue:[NSNumber numberWithBool:status.statusType == AIAwayStatusType] forProperty:@"Away" notify:NotifyLater];
    if (self.online || [self boolValueForProperty:@"isConnecting"])
        [self sendCommand:@"status" values:[NSDictionary dictionaryWithObjectsAndKeys:backendStatus, @"status", backendStatusMessage ?: @"", @"statusMessage", nil]];
    else [self connect];
}
- (NSSet *)supportedPropertyKeys
{
    NSMutableSet *keys = [NSMutableSet setWithSet:[super supportedPropertyKeys]];
    [keys addObjectsFromArray:[NSArray arrayWithObjects:@"isOnline", @"Offline", @"Away", @"AwayMessage", nil]];
    return keys;
}
- (BOOL)availableForSendingContentType:(NSString *)type toContact:(AIListContact *)contact
{
    return self.online && ([type isEqualToString:CONTENT_MESSAGE_TYPE] || [type isEqualToString:CONTENT_TYPING_TYPE]);
}
- (NSString *)encodedAttributedString:(NSAttributedString *)string forListObject:(AIListObject *)object
{
    return [AIHTMLDecoder encodeHTML:string encodeFullString:NO];
}
- (id)backendIDForChat:(AIChat *)chat
{
    for (id key in backendChats) if ([backendChats objectForKey:key] == chat) return key;
    return nil;
}
/* Room messages are displayed when the helper reports their authoritative echo. */
- (BOOL)shouldDisplayOutgoingMUCMessages { return NO; }
- (BOOL)sendMessageObject:(AIContentMessage *)message
{
    if (!self.online) return NO;
    AIChat *chat = message.chat;
    id target = chat.isGroupChat ? [self backendIDForChat:chat] : message.destination.UID;
    if (!target) return NO;
    if (chat.isGroupChat && ![self shouldDisplayOutgoingMUCMessages]) message.displayContent = NO;
    [self sendCommand:chat.isGroupChat ? @"sendChat" : @"sendIM" values:[NSDictionary dictionaryWithObjectsAndKeys:
        target, chat.isGroupChat ? @"chat" : @"to", message.encodedMessage ?: message.messageString, @"message", nil]];
    return YES;
}
- (void)sendTypingObject:(AIContentTyping *)typing
{
    if (!self.online || typing.chat.isGroupChat) return;
    [self sendCommand:@"typing" values:[NSDictionary dictionaryWithObjectsAndKeys:
        typing.chat.listObject.UID, @"to", [NSNumber numberWithInteger:typing.typingState], @"state", nil]];
}
- (BOOL)contactListEditable { return YES; }
- (void)addContact:(AIListContact *)contact toGroup:(AIListGroup *)group
{
    if (!self.online) return;
    [self sendCommand:@"addBuddy" values:[NSDictionary dictionaryWithObjectsAndKeys:contact.UID, @"name", group.UID ?: @"Buddies", @"group", nil]];
}
- (void)removeContacts:(NSArray *)objects fromGroups:(NSArray *)groups
{
    if (!self.online) return;
    for (AIListContact *contact in objects)
        [self sendCommand:@"removeBuddy" values:[NSDictionary dictionaryWithObject:contact.UID forKey:@"name"]];
}
- (BOOL)joiningGroupChatRequiresCreationDictionary { return YES; }
- (BOOL)openChat:(AIChat *)chat
{
    if (!chat.isGroupChat) return YES;
    if (!self.online || ![self.service canCreateGroupChats]) return NO;
    if ([self backendIDForChat:chat] || [pendingChats containsObject:chat]) return YES;
    if (![chat.chatCreationDictionary count]) return NO;
    [pendingChats addObject:chat];
    [self sendCommand:@"joinChat" values:[NSDictionary dictionaryWithObject:chat.chatCreationDictionary forKey:@"components"]];
    return YES;
}
- (BOOL)rejoinChat:(AIChat *)chat { return [self openChat:chat]; }
- (BOOL)closeChat:(AIChat *)chat
{
    id chatID = [self backendIDForChat:chat];
    if (chatID) {
        [self sendCommand:@"leaveChat" values:[NSDictionary dictionaryWithObject:chatID forKey:@"chat"]];
        [backendChats removeObjectForKey:chatID];
    }
    [pendingChats removeObject:chat];
    return YES;
}
- (AIChat *)chatForEvent:(NSDictionary *)event create:(BOOL)create
{
    id chatID = [event objectForKey:@"chat"];
    if (!chatID || chatID == [NSNull null]) return nil;
    AIChat *chat = [backendChats objectForKey:chatID];
    if (!chat && create) {
        NSString *name = ADPString([event objectForKey:@"name"]);
        if (![name length]) name = [chatID description];
        /* Preserve the UI-created chat and its saved join components where possible. */
        for (AIChat *candidate in pendingChats) if ([candidate.name isEqualToString:name]) { chat = candidate; break; }
        if (!chat && [pendingChats count] == 1) chat = [pendingChats anyObject];
        if (!chat) chat = [adium.chatController chatWithName:name identifier:chatID onAccount:self chatCreationInfo:nil];
        chat.isGroupChat = YES;
        chat.identifier = chatID;
        [backendChats setObject:chat forKey:chatID];
        [pendingChats removeObject:chat];
    }
    return chat;
}
- (void)handleBackendEvent:(NSDictionary *)event
{
    if (![NSThread isMainThread]) { [self performSelectorOnMainThread:@selector(handleBackendEvent:) withObject:event waitUntilDone:NO]; return; }
    if (![[event objectForKey:@"account"] isEqual:self.internalObjectID]) return;
    NSString *kind = [event objectForKey:@"event"];
    if ([kind isEqualToString:@"connected"]) {
        if (disconnectRequested) { [self sendCommand:@"disconnect" values:nil]; return; }
        [self setLastDisconnectionError:nil]; [self didConnect];
    } else if ([kind isEqualToString:@"disconnected"]) {
        NSString *reason = ADPString([event objectForKey:@"reason"]);
        id error = [event objectForKey:@"error"];
        if (![reason length] && [error isKindOfClass:[NSString class]]) reason = error;
        if (!disconnectRequested && ![reason length]) reason = @"The libpurple backend disconnected.";
        [self setLastDisconnectionError:disconnectRequested ? nil : reason];
        [backendChats removeAllObjects]; [pendingChats removeAllObjects];
        [self didDisconnect];
    } else if ([kind isEqualToString:@"chatInfo"]) {
        NSArray *fields = [event objectForKey:@"fields"];
        if ([fields isKindOfClass:[NSArray class]]) {
            [backendChatFields release]; backendChatFields = [fields copy];
            [[NSNotificationCenter defaultCenter] postNotificationName:ADPChatFieldsChangedNotification object:self];
        }
    } else if ([kind isEqualToString:@"accountUpdated"]) {
        NSDictionary *options = [event objectForKey:@"options"];
        if ([options isKindOfClass:[NSDictionary class]])
            [self setProtocolOptionValues:options complete:[[event objectForKey:@"optionsComplete"] boolValue]];
        NSString *updatedPassword = [event objectForKey:@"password"];
        if ([updatedPassword isKindOfClass:[NSString class]] && ![updatedPassword isEqualToString:lastBackendPassword]) {
            NSString *stored = [adium.accountController passwordForAccount:self];
            if (![updatedPassword isEqualToString:stored]) [adium.accountController setPassword:updatedPassword forAccount:self];
            [self setPasswordTemporarily:updatedPassword];
            [lastBackendPassword release]; lastBackendPassword = [updatedPassword copy];
        }
    } else if ([kind isEqualToString:@"buddy"]) {
        NSString *name = ADPString([event objectForKey:@"name"]);
        if (![name length]) return;
        AIListContact *contact = [self contactWithUID:name];
        if (!contact.countOfRemoteGroupNames) [contact addRemoteGroupName:@"Buddies"];
        [contact setServersideAlias:ADPString([event objectForKey:@"alias"]) silently:silentAndDelayed];
        BOOL online = [[event objectForKey:@"online"] boolValue];
        NSString *status = ADPString([event objectForKey:@"status"]);
        BOOL away = [status isEqualToString:@"away"] || [status isEqualToString:@"unavailable"] || [status isEqualToString:@"extended_away"];
        [contact setOnline:online notify:NotifyLater silently:silentAndDelayed];
        [contact setStatusWithName:nil statusType:!online ? AIOfflineStatusType : (away ? AIAwayStatusType : AIAvailableStatusType) notify:NotifyLater];
        [contact setStatusMessage:[AIHTMLDecoder decodeHTML:ADPString([event objectForKey:@"statusMessage"])] notify:NotifyLater];
        [contact notifyOfChangedPropertiesSilently:silentAndDelayed];
    } else if ([kind isEqualToString:@"typing"]) {
        NSString *from = ADPString([event objectForKey:@"from"]);
        if (![from length]) return;
        AIChat *chat = [adium.chatController existingChatWithContact:[self contactWithUID:from]];
        NSInteger state = [[event objectForKey:@"state"] integerValue];
        [chat setValue:state ? [NSNumber numberWithInteger:state] : nil forProperty:KEY_TYPING notify:NotifyNow];
    } else if ([kind isEqualToString:@"chatJoined"]) {
        AIChat *chat = [self chatForEvent:event create:YES];
        chat.isOpen = YES;
    } else if ([kind isEqualToString:@"chatLeft"]) {
        AIChat *chat = [self chatForEvent:event create:NO];
        if (chat) { [chat removeAllParticipatingContactsSilently]; [adium.chatController accountDidCloseChat:chat]; }
        if ([event objectForKey:@"chat"]) [backendChats removeObjectForKey:[event objectForKey:@"chat"]];
    } else if ([kind isEqualToString:@"chatBuddy"]) {
        AIChat *chat = [self chatForEvent:event create:NO];
        NSString *name = ADPString([event objectForKey:@"name"]);
        if (!chat || ![name length]) return;
        AIListContact *contact = [self contactWithUID:name];
        NSString *action = [event objectForKey:@"action"];
        if ([action isEqualToString:@"remove"] || [action isEqualToString:@"left"]) [chat removeObject:contact];
        else {
            [contact setOnline:YES notify:NotifyNever silently:YES];
            [chat addParticipatingListObject:contact notify:YES];
            NSString *alias = ADPString([event objectForKey:@"alias"]);
            if ([alias length]) [chat setAlias:alias forContact:contact];
        }
    } else if ([kind isEqualToString:@"im"] || [kind isEqualToString:@"chatMessage"]) {
        BOOL group = [kind isEqualToString:@"chatMessage"];
        NSUInteger flags = [[event objectForKey:@"flags"] unsignedIntegerValue];
        /* Wire flags: SEND=1, RECV=2, AUTO_RESP=4, REMOTE_SEND=0x10000.
         * Adium already displays local IMs. Other-device sends remain visible. */
        if (!group && (flags & 1) && !(flags & 0x10000)) return;
        BOOL outgoing = (flags & 1) && !(flags & 2);
        NSString *from = ADPString([event objectForKey:@"from"]);
        NSString *peer = !group && outgoing ? ADPString([event objectForKey:@"peer"]) : from;
        if (![peer length]) peer = from;
        if (![peer length]) return;
        AIListContact *contact = [self contactWithUID:peer];
        AIChat *chat = group ? [self chatForEvent:event create:YES] : [adium.chatController chatWithContact:contact];
        if (!chat) return;
        NSString *html = ADPString([event objectForKey:@"message"]);
        NSAttributedString *body = group ? [AIHTMLDecoder decodeHTML:html] :
            [adium.contentController decodedIncomingMessage:html fromContact:contact onAccount:self];
        NSTimeInterval timestamp = [[event objectForKey:@"time"] doubleValue];
        NSDate *date = timestamp > 0 ? [NSDate dateWithTimeIntervalSince1970:timestamp] : [NSDate date];
        AIContentMessage *message = [AIContentMessage messageInChat:chat withSource:outgoing ? (id)self : contact
            destination:outgoing ? (id)contact : self date:date message:body autoreply:(flags & 4) != 0];
        [adium.contentController receiveContentObject:message];
        [chat setValue:nil forProperty:KEY_TYPING notify:NotifyNow];
    }
}
@end









