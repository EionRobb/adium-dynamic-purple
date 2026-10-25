/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Link this harness with the four frontend implementations, Cocoa, Adium and
 * AIUtilities only. Never link ADPBackend.m: this implementation records IPC
 * instead of launching a helper. Preferences and contacts live only in memory. */
#import "ADPAccount.h"
#import "ADPService.h"
#import "ADPBackend.h"
#import <Adium/AISharedAdium.h>
#import <Adium/AIStatus.h>
#import <Adium/AIChat.h>
#import <Adium/AIListContact.h>
#import <Adium/AIContentMessage.h>
#import <Adium/AIContentTyping.h>
#import <assert.h>
#import <stdio.h>
#import <AIUtilities/AIKeychain.h>
#import <objc/runtime.h>

/* Replace only AIKeychain's factory in this test process. Secure-option code
 * exercises its actual read/compare/write path without touching login.keychain. */
@interface FrontendKeychain : NSObject {
@public NSMutableDictionary *items;
@public NSUInteger writes;
}
@end
@implementation FrontendKeychain
- (id)init { if ((self = [super init])) items = [[NSMutableDictionary alloc] init]; return self; }
- (NSString *)itemKey:(NSString *)service account:(NSString *)account { return [NSString stringWithFormat:@"%@/%@", service, account]; }
- (NSString *)findGenericPasswordForService:(NSString *)service account:(NSString *)account keychainItem:(void *)item error:(NSError **)error
{ return [items objectForKey:[self itemKey:service account:account]]; }
- (BOOL)deleteGenericPasswordForService:(NSString *)service account:(NSString *)account error:(NSError **)error
{ [items removeObjectForKey:[self itemKey:service account:account]]; return YES; }
- (BOOL)addGenericPassword:(NSString *)password forService:(NSString *)service account:(NSString *)account keychainItem:(void *)item error:(NSError **)error
{ [items setObject:password forKey:[self itemKey:service account:account]]; writes++; return YES; }
@end
static FrontendKeychain *testKeychain;
static id keychainFactory(id receiver, SEL selector, NSError **error) { return testKeychain; }
static NSMutableArray *commands;
static NSMutableSet *registered;
@implementation ADPBackend
+ (ADPBackend *)sharedBackend { static ADPBackend *backend; if (!backend) backend = [[self alloc] init]; return backend; }
- (NSArray *)protocols { return [NSArray array]; }
- (BOOL)start { return YES; }
- (void)stop {}
- (void)sendCommand:(NSDictionary *)command { [commands addObject:[[command copy] autorelease]]; }
- (void)registerAccount:(ADPAccount *)account { [registered addObject:account.internalObjectID]; }
- (void)unregisterAccount:(ADPAccount *)account { [registered removeObject:account.internalObjectID]; }
- (void)report:(NSString *)message { fprintf(stderr, "%s\n", [message UTF8String]); }
@end

@interface FrontendRegistry : NSObject {
@public
    NSMutableDictionary *services;
    NSMutableDictionary *preferences;
    NSMutableDictionary *contacts;
    NSMutableDictionary *chats;
    NSMutableArray *received;
    NSMutableDictionary *passwords;
    NSUInteger passwordWrites;
}
@end
@implementation FrontendRegistry
- (id)init
{
    if ((self = [super init])) {
        passwords = [[NSMutableDictionary alloc] init];
        services = [[NSMutableDictionary alloc] init]; preferences = [[NSMutableDictionary alloc] init];
        contacts = [[NSMutableDictionary alloc] init]; chats = [[NSMutableDictionary alloc] init]; received = [[NSMutableArray alloc] init];
    }
    return self;
}
- (NSString *)passwordForAccount:(AIAccount *)account { return [passwords objectForKey:account.internalObjectID]; }
- (void)setPassword:(NSString *)value forAccount:(AIAccount *)account { [passwords setObject:value forKey:account.internalObjectID]; passwordWrites++; }
- (id)accountController { return self; }
- (id)statusController { return self; }
- (id)preferenceController { return self; }
- (id)contactController { return self; }
- (id)contentController { return self; }
- (id)chatController { return self; }
- (id)interfaceController { return nil; }
- (id)debugController { return nil; }
- (NSArray *)accounts { return [NSArray array]; }
- (NSArray *)openChats { return [NSArray array]; }
- (NSArray *)allContacts { return [contacts allValues]; }
- (id)contactEnumerator { return [[contacts allValues] objectEnumerator]; }
- (id)bookmarkEnumerator { return nil; }
- (id)groupEnumerator { return nil; }
- (void)sortListObject:(id)object {}
- (void)accountDidStopTrackingContact:(AIListContact *)contact {}
- (void)sortContactList {}
- (void)registerService:(AIService *)service { [services setObject:service forKey:service.serviceCodeUniqueID]; }
- (NSString *)localizedDescriptionForCoreStatusName:(NSString *)name { return name; }
- (NSString *)defaultStatusNameForType:(AIStatusType)type { return @"Available"; }
- (AIStatus *)offlineStatusState { return [AIStatus statusOfType:AIOfflineStatusType]; }
- (AIStatus *)defaultInitialStatusState { return [AIStatus statusOfType:AIAvailableStatusType]; }
- (AIStatus *)activeStatusState { return [self defaultInitialStatusState]; }
- (void)registerStatus:(NSString *)name withDescription:(NSString *)description ofType:(AIStatusType)type forService:(AIService *)service {}
- (void)registerDefaults:(id)defaults forGroup:(id)group object:(id)object {}
- (id)preferenceForKey:(NSString *)key group:(NSString *)group { return nil; }
- (void)registerPreferenceObserver:(id)observer forGroup:(id)group {}
- (void)unregisterPreferenceObserver:(id)observer {}
- (NSString *)preferenceID:(NSString *)key group:(NSString *)group object:(AIListObject *)object
{ return [NSString stringWithFormat:@"%@/%@/%@", object.internalObjectID, group, key]; }
- (id)preferenceForKey:(NSString *)key group:(NSString *)group objectIgnoringInheritance:(AIListObject *)object
{ return [preferences objectForKey:[self preferenceID:key group:group object:object]]; }
- (id)preferenceForKey:(NSString *)key group:(NSString *)group object:(AIListObject *)object
{ return [self preferenceForKey:key group:group objectIgnoringInheritance:object]; }
- (void)setPreference:(id)value forKey:(NSString *)key group:(NSString *)group object:(AIListObject *)object
{
    NSString *identifier = [self preferenceID:key group:group object:object];
    if (value) [preferences setObject:value forKey:identifier]; else [preferences removeObjectForKey:identifier];
}
- (AIListContact *)contactWithService:(AIService *)service account:(AIAccount *)account UID:(NSString *)uid
{
    NSString *key = [NSString stringWithFormat:@"%@/%@", account.internalObjectID, uid];
    AIListContact *contact = [contacts objectForKey:key];
    if (!contact) { contact = [[[AIListContact alloc] initWithUID:uid account:account service:service] autorelease]; [contacts setObject:contact forKey:key]; }
    return contact;
}
- (AIChat *)chatWithContact:(AIListContact *)contact
{
    NSString *key = contact.internalUniqueObjectID;
    AIChat *chat = [chats objectForKey:key];
    if (!chat) { chat = [AIChat chatForAccount:contact.account]; chat.listObject = contact; [chats setObject:chat forKey:key]; }
    return chat;
}
- (AIChat *)chatWithName:(NSString *)name identifier:(id)identifier onAccount:(AIAccount *)account chatCreationInfo:(NSDictionary *)info
{
    AIChat *chat = [AIChat chatForAccount:account]; chat.name = name; chat.identifier = identifier;
    chat.chatCreationDictionary = info; [chats setObject:chat forKey:[identifier description]]; return chat;
}
- (void)chat:(AIChat *)chat addedListContacts:(NSArray *)objects notify:(BOOL)notify {}
- (void)chat:(AIChat *)chat removedListContact:(AIListContact *)contact {}
- (void)chatStatusChanged:(AIChat *)chat modifiedStatusKeys:(NSSet *)keys silent:(BOOL)silent {}
- (AIChat *)existingChatWithContact:(AIListContact *)contact { return [chats objectForKey:contact.internalUniqueObjectID]; }
- (NSAttributedString *)decodedIncomingMessage:(NSString *)message fromContact:(AIListContact *)contact onAccount:(AIAccount *)account
{ return [[[NSAttributedString alloc] initWithString:message] autorelease]; }
- (void)filterAttributedString:(NSAttributedString *)string usingFilterType:(NSInteger)type direction:(NSInteger)direction filterContext:(id)filterContext notifyingTarget:(id)target selector:(SEL)selector context:(id)context
{ [target performSelector:selector withObject:string withObject:context]; }
- (void)receiveContentObject:(id)object { [received addObject:object]; }
@end

static NSDictionary *event(NSString *kind, ADPAccount *account, NSDictionary *values)
{
    NSMutableDictionary *result = [NSMutableDictionary dictionaryWithDictionary:values ?: [NSDictionary dictionary]];
    [result setObject:kind forKey:@"event"]; [result setObject:account.internalObjectID forKey:@"account"]; return result;
}
static NSDictionary *lastCommand(NSString *name)
{
    NSDictionary *last = [commands lastObject]; assert([[last objectForKey:@"command"] isEqual:name]); return last;
}
int main(void)
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    testKeychain = [[FrontendKeychain alloc] init];
    method_setImplementation(class_getClassMethod([AIKeychain class], @selector(defaultKeychain_error:)), (IMP)keychainFactory);
    commands = [[NSMutableArray alloc] init]; registered = [[NSMutableSet alloc] init];
    FrontendRegistry *registry = [[FrontendRegistry alloc] init]; setSharedAdium((id)registry);
    NSDictionary *option = [NSDictionary dictionaryWithObjectsAndKeys:@"port", @"key", @"Port", @"label", @"int", @"type", [NSNumber numberWithInt:443], @"default", nil];
    NSDictionary *secureOption = [NSDictionary dictionaryWithObjectsAndKeys:@"token", @"key", @"Token", @"label", @"string", @"type", [NSNumber numberWithBool:YES], @"masked", nil];
    NSDictionary *alpha = [NSDictionary dictionaryWithObjectsAndKeys:@"prpl-CaseAlpha", @"id", @"Alpha", @"name",
        [NSArray arrayWithObjects:option, secureOption, nil], @"options", [NSNumber numberWithBool:YES], @"noPassword", nil];
    NSDictionary *beta = [NSDictionary dictionaryWithObjectsAndKeys:@"prpl-beta", @"id", @"Beta", @"name", [NSArray array], @"options", nil];
    ADPService *a = [[[ADPService alloc] initWithProtocol:alpha] autorelease];
    ADPService *b = [[[ADPService alloc] initWithProtocol:beta] autorelease];
    assert([registry->services count] == 2);
    assert([[a serviceCodeUniqueID] isEqual:@"dynamic-purple:prpl-CaseAlpha"]);
    assert([[a serviceID] isEqual:@"DynamicPurple:prpl-CaseAlpha"]);
    assert(![[a serviceID] isEqual:[b serviceID]]);
    assert([a accountClass] == [ADPAccount class] && [b accountClass] == [ADPAccount class]);
    assert(!a.supportsPassword && b.requiresPassword);
    ADPAccount *account = [a accountWithUID:@"TestUser" internalObjectID:@"frontend-test-A"];
    ADPAccount *other = [b accountWithUID:@"TestUser" internalObjectID:@"frontend-test-B"];
    assert([account isKindOfClass:[AIAccount class]]);
    assert([[account protocolOptionValue:option] intValue] == 443);
    [account setProtocolOptionValues:[NSDictionary dictionaryWithObject:[NSNumber numberWithInt:8443] forKey:@"port"]];
    assert([[account protocolOptionValue:option] intValue] == 8443);
    assert([[account preferenceForKey:@"ProtocolDescriptor" group:@"DynamicPurple"] isEqual:alpha]);
    [account setPasswordTemporarily:@"fixture-only-password"];
    [account connect];
    NSDictionary *connect = lastCommand(@"connect");
    assert([[connect objectForKey:@"protocol"] isEqual:@"prpl-CaseAlpha"]);
    assert([[connect objectForKey:@"account"] isEqual:@"frontend-test-A"]);
    assert([[[connect objectForKey:@"options"] objectForKey:@"port"] intValue] == 8443);
    assert([registered containsObject:account.internalObjectID]);
    assert([[connect objectForKey:@"password"] isEqual:@"fixture-only-password"]);
    NSDictionary *initialPassword = event(@"accountUpdated", account, [NSDictionary dictionaryWithObject:
        [connect objectForKey:@"password"] forKey:@"password"]);
    [account handleBackendEvent:initialPassword]; [account handleBackendEvent:initialPassword];
    assert(registry->passwordWrites == 0);
    assert(![registry passwordForAccount:account]);
    NSUInteger count = [commands count]; [account connect]; assert([commands count] == count);
    [account handleBackendEvent:event(@"connected", other, nil)]; assert(!account.online);
    [account handleBackendEvent:event(@"connected", account, nil)]; assert(account.online);
    [account setStatusState:[AIStatus statusOfType:AIInvisibleStatusType] usingStatusMessage:[[[NSAttributedString alloc] initWithString:@"private"] autorelease]];
    assert([[lastCommand(@"status") objectForKey:@"status"] isEqual:@"invisible"]);
    assert([[lastCommand(@"status") objectForKey:@"statusMessage"] isEqual:@"private"]);
    [account handleBackendEvent:event(@"accountUpdated", account, [NSDictionary dictionaryWithObject:
        [NSDictionary dictionaryWithObject:[NSNumber numberWithInt:9443] forKey:@"port"] forKey:@"options"])];
    assert([[account protocolOptionValue:option] intValue] == 9443);
    NSDictionary *secureUpdate = event(@"accountUpdated", account, [NSDictionary dictionaryWithObject:[NSDictionary dictionaryWithObject:@"fixture-secure-option" forKey:@"token"] forKey:@"options"]);
    [account handleBackendEvent:secureUpdate]; [account handleBackendEvent:secureUpdate];
    assert(testKeychain->writes == 1);
    assert([[account protocolOptionValue:secureOption] isEqual:@"fixture-secure-option"]);
    assert(![[account preferenceForKey:@"ProtocolOptions" group:@"DynamicPurple"] objectForKey:@"token"]);
    NSDictionary *tokenUpdate =event(@"accountUpdated", account, [NSDictionary dictionaryWithObject:@"fixture-refresh-token" forKey:@"password"]);
    [account handleBackendEvent:tokenUpdate]; [account handleBackendEvent:tokenUpdate];
    assert(registry->passwordWrites == 1);
    assert([[account passwordWhileConnected] isEqual:@"fixture-refresh-token"]);
    NSDictionary *field = [NSDictionary dictionaryWithObjectsAndKeys:@"channel", @"key", @"Channel", @"label", @"fixture-secret-default", @"default", nil];
    [account handleBackendEvent:event(@"chatInfo", account, [NSDictionary dictionaryWithObject:[NSArray arrayWithObject:field] forKey:@"fields"])];
    assert([[[account protocolDescriptor] objectForKey:@"chatFields"] count] == 1);
    assert(![[account preferenceForKey:@"ProtocolDescriptor" group:@"DynamicPurple"] objectForKey:@"chatFields"]);
    assert(![[other protocolDescriptor] objectForKey:@"chatFields"]);
    AIListContact *contact = [registry contactWithService:a account:account UID:@"Friend"];
    AIChat *chat = [registry chatWithContact:contact];
    AIContentMessage *message = [AIContentMessage messageInChat:chat withSource:account destination:contact date:nil
        message:[[[NSAttributedString alloc] initWithString:@"hello"] autorelease] autoreply:NO];
    message.encodedMessage = @"hello";
    assert([account sendMessageObject:message]);
    assert([[lastCommand(@"sendIM") objectForKey:@"to"] isEqual:@"Friend"]);
    assert([[lastCommand(@"sendIM") objectForKey:@"account"] isEqual:@"frontend-test-A"]);
    [account sendTypingObject:[AIContentTyping typingContentInChat:chat withSource:account destination:contact typingState:AITyping]];
    assert([[lastCommand(@"typing") objectForKey:@"state"] integerValue] == AITyping);
    [account handleBackendEvent:event(@"im", account, [NSDictionary dictionaryWithObjectsAndKeys:@"Friend", @"from", @"reply", @"message",
        [NSNumber numberWithInt:2], @"flags", [NSNumber numberWithInt:1234567890], @"time", nil])];
    AIContentMessage *reply = [registry->received lastObject];
    assert([reply isKindOfClass:[AIContentMessage class]] && reply.source == contact && reply.destination == account);
    assert([reply.messageString isEqual:@"reply"]);
    assert([reply.date timeIntervalSince1970] == 1234567890);
    NSUInteger receivedBeforeEcho = [registry->received count];
    [account handleBackendEvent:event(@"im", account, [NSDictionary dictionaryWithObjectsAndKeys:
        @"TestUser", @"from", @"Friend", @"peer", @"hello", @"message", [NSNumber numberWithInt:1], @"flags", nil])];
    assert([registry->received count] == receivedBeforeEcho);
    [account handleBackendEvent:event(@"im", account, [NSDictionary dictionaryWithObjectsAndKeys:
        @"TestUser", @"from", @"Friend", @"peer", @"other-device send", @"message", [NSNumber numberWithInt:0x10001], @"flags", nil])];
    assert([registry->received count] == receivedBeforeEcho + 1);
    AIContentMessage *remoteSend = [registry->received lastObject];
    assert(remoteSend.source == account && remoteSend.destination == contact && remoteSend.chat == chat);
    assert([remoteSend.messageString isEqual:@"other-device send"]);
    assert(![account shouldDisplayOutgoingMUCMessages]);
    [account handleBackendEvent:event(@"chatMessage", account, [NSDictionary dictionaryWithObjectsAndKeys:
        [NSNumber numberWithInt:7], @"chat", @"TestUser", @"from", @"room echo", @"message", [NSNumber numberWithInt:1], @"flags", nil])];
    AIContentMessage *roomEcho = [registry->received lastObject];
    assert([registry->received count] == receivedBeforeEcho + 2 && roomEcho.chat.isGroupChat);
    AIContentMessage *roomSend = [AIContentMessage messageInChat:roomEcho.chat withSource:account destination:contact date:nil
        message:[[[NSAttributedString alloc] initWithString:@"room send"] autorelease] autoreply:NO];
    roomSend.encodedMessage = @"room send"; roomSend.displayContent = YES;
    assert([account sendMessageObject:roomSend] && !roomSend.displayContent);
    assert([[lastCommand(@"sendChat") objectForKey:@"chat"] intValue] == 7);
    NSDictionary *opaque =[NSDictionary dictionaryWithObjectsAndKeys:@"cursor-123", @"last_message_id",
        [NSNumber numberWithBool:YES], @"guild_muted", [NSNumber numberWithLongLong:1234567890123LL], @"guild_cursor",
        [NSArray arrayWithObject:@"reject"], @"not_scalar", [NSNumber numberWithDouble:1.5], @"not_integer", nil];
    NSUInteger stateWrites = testKeychain->writes;
    NSDictionary *opaqueUpdate = event(@"accountUpdated", account, [NSDictionary dictionaryWithObject:opaque forKey:@"options"]);
    [account handleBackendEvent:opaqueUpdate]; [account handleBackendEvent:opaqueUpdate];
    assert(testKeychain->writes == stateWrites + 1);
    NSDictionary *plainOptions = [account preferenceForKey:@"ProtocolOptions" group:@"DynamicPurple"];
    assert(![plainOptions objectForKey:@"last_message_id"] && ![plainOptions objectForKey:@"guild_cursor"]);
    NSString *stateName = @"Adium DynamicPurple state/prpl-CaseAlpha/frontend-test-A";
    NSString *xml = [testKeychain->items objectForKey:stateName];
    assert([xml length]);
    NSMutableDictionary *storedState = [NSMutableDictionary dictionaryWithDictionary:
        [NSPropertyListSerialization propertyListFromData:[xml dataUsingEncoding:NSUTF8StringEncoding]
            mutabilityOption:NSPropertyListImmutable format:NULL errorDescription:NULL]];
    assert([[storedState objectForKey:@"last_message_id"] isEqual:@"cursor-123"]);
    assert([[storedState objectForKey:@"guild_muted"] boolValue]);
    assert([[storedState objectForKey:@"guild_cursor"] longLongValue] == 1234567890123LL);
    assert(![storedState objectForKey:@"not_scalar"] && ![storedState objectForKey:@"not_integer"]);
    /* Simulate opaque state from an older schema. Declared UI settings win. */
    [storedState setObject:[NSNumber numberWithInt:1] forKey:@"port"];
    NSData *seed = [NSPropertyListSerialization dataFromPropertyList:storedState format:NSPropertyListXMLFormat_v1_0 errorDescription:NULL];
    [testKeychain->items setObject:[[[NSString alloc] initWithData:seed encoding:NSUTF8StringEncoding] autorelease] forKey:stateName];
    [account disconnect]; lastCommand(@"disconnect");
    [account handleBackendEvent:event(@"disconnected", account, nil)]; assert(!account.online);
    count = [commands count]; assert(![account sendMessageObject:message]); assert([commands count] == count);
    ADPAccount *restored = [a accountWithUID:@"TestUser" internalObjectID:@"frontend-test-A"];
    [restored connect];
    NSDictionary *reconnectOptions = [lastCommand(@"connect") objectForKey:@"options"];
    assert([[reconnectOptions objectForKey:@"last_message_id"] isEqual:@"cursor-123"]);
    assert([[reconnectOptions objectForKey:@"guild_cursor"] longLongValue] == 1234567890123LL);
    assert([[reconnectOptions objectForKey:@"guild_muted"] boolValue]);
    assert([[reconnectOptions objectForKey:@"port"] intValue] == 9443);
    assert(![reconnectOptions objectForKey:@"not_scalar"]);
    /* Partial updates retain the previously stored cursor and deduplicate. */
    NSDictionary *partial = event(@"accountUpdated", restored, [NSDictionary dictionaryWithObject:
        [NSDictionary dictionaryWithObject:@"next" forKey:@"new_setting"] forKey:@"options"]);
    [restored handleBackendEvent:partial]; stateWrites = testKeychain->writes;
    [restored handleBackendEvent:partial]; assert(testKeychain->writes == stateWrites);
    [restored disconnect]; [restored handleBackendEvent:event(@"disconnected", restored, nil)];
    [restored connect]; reconnectOptions = [lastCommand(@"connect") objectForKey:@"options"];
    assert([[reconnectOptions objectForKey:@"last_message_id"] isEqual:@"cursor-123"]);
    assert([[reconnectOptions objectForKey:@"new_setting"] isEqual:@"next"]);
    [restored disconnect]; [restored handleBackendEvent:event(@"disconnected", restored, nil)];
    NSDictionary *complete = event(@"accountUpdated", restored, [NSDictionary dictionaryWithObjectsAndKeys:
        [NSNumber numberWithBool:YES], @"optionsComplete", [NSDictionary dictionaryWithObjectsAndKeys:
            @"", @"token", [NSNumber numberWithInt:443], @"port", @"retained", @"only_current_setting", nil], @"options", nil]);
    [restored handleBackendEvent:complete]; stateWrites = testKeychain->writes;
    [restored handleBackendEvent:complete]; assert(testKeychain->writes == stateWrites);
    assert([[restored protocolOptionValue:secureOption] isEqual:@""]);
    [restored connect]; reconnectOptions = [lastCommand(@"connect") objectForKey:@"options"];
    assert([[reconnectOptions objectForKey:@"token"] isEqual:@""]);
    assert([[reconnectOptions objectForKey:@"port"] intValue] == 443);
    assert([[reconnectOptions objectForKey:@"only_current_setting"] isEqual:@"retained"]);
    assert(![reconnectOptions objectForKey:@"last_message_id"] && ![reconnectOptions objectForKey:@"guild_cursor"]);
    assert(![reconnectOptions objectForKey:@"guild_muted"] && ![reconnectOptions objectForKey:@"new_setting"]);
    [restored disconnect]; [restored handleBackendEvent:event(@"disconnected", restored, nil)];
    NSDictionary *emptyComplete = event(@"accountUpdated", restored, [NSDictionary dictionaryWithObjectsAndKeys:
        [NSNumber numberWithBool:YES], @"optionsComplete", [NSDictionary dictionaryWithObjectsAndKeys:
            @"", @"token", [NSNumber numberWithInt:443], @"port", nil], @"options", nil]);
    [restored handleBackendEvent:emptyComplete]; assert(![testKeychain->items objectForKey:stateName]);
    /* Deletion also clears state added after a full snapshot. */
    [restored handleBackendEvent:partial]; assert([testKeychain->items objectForKey:stateName]);
    [restored willBeDeleted]; assert(![testKeychain->items objectForKey:stateName]);
    /* Cancel while connecting must still send disconnect after super clears isConnecting. */
    [other connect]; [other disconnect]; lastCommand(@"disconnect");
    [other handleBackendEvent:event(@"connected", other, nil)]; lastCommand(@"disconnect"); assert(!other.online);
    [other handleBackendEvent:event(@"disconnected", other, nil)];
    /* Service images use the metadata path, choose sizes, skip corrupt files,
     * and remain independent when Adium flips one cached variant. */
    NSString *iconDirectory = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]];
    [[NSFileManager defaultManager] createDirectoryAtPath:iconDirectory withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *smallPath = [iconDirectory stringByAppendingPathComponent:@"16.png"];
    NSString *largePath = [iconDirectory stringByAppendingPathComponent:@"48.png"];
    NSString *brokenPath = [iconDirectory stringByAppendingPathComponent:@"broken.png"];
    NSBitmapImageRep *pixels = [[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:1 pixelsHigh:1
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0] autorelease];
    memset([pixels bitmapData], 255, [pixels bytesPerRow]);
    NSData *png = [pixels representationUsingType:NSPNGFileType properties:[NSDictionary dictionary]];
    assert([png writeToFile:smallPath atomically:YES] && [png writeToFile:largePath atomically:YES]);
    [@"not a png" writeToFile:brokenPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    NSArray *icons = [NSArray arrayWithObjects:
        [NSDictionary dictionaryWithObjectsAndKeys:brokenPath, @"path", @16, @"size", nil],
        [NSDictionary dictionaryWithObjectsAndKeys:smallPath, @"path", @16, @"size", nil],
        [NSDictionary dictionaryWithObjectsAndKeys:largePath, @"path", @48, @"size", nil], nil];
    ADPService *iconService = [[[ADPService alloc] initWithProtocol:[NSDictionary dictionaryWithObjectsAndKeys:
        @"prpl-icon-test", @"id", @"Icons", @"name", icons, @"icons", nil]] autorelease];
    assert([[iconService pathForDefaultServiceIconOfType:AIServiceIconSmall] isEqual:smallPath]);
    assert([[iconService pathForDefaultServiceIconOfType:AIServiceIconList] isEqual:smallPath]);
    assert([[iconService pathForDefaultServiceIconOfType:AIServiceIconLarge] isEqual:largePath]);
    NSImage *one = [iconService defaultServiceIconOfType:AIServiceIconSmall];
    NSImage *two = [iconService defaultServiceIconOfType:AIServiceIconSmall];
    assert(one && two && one != two && [one isValid] && one.size.width == 16);
    [one setFlipped:YES]; assert(![two isFlipped]);
    [[NSFileManager defaultManager] removeItemAtPath:smallPath error:NULL];
    assert([[iconService pathForDefaultServiceIconOfType:AIServiceIconSmall] isEqual:largePath]);
    [[NSFileManager defaultManager] removeItemAtPath:largePath error:NULL];
    assert(![iconService pathForDefaultServiceIconOfType:AIServiceIconSmall]);
    assert([iconService defaultServiceIconOfType:AIServiceIconSmall]);
    [[NSFileManager defaultManager] removeItemAtPath:iconDirectory error:NULL];
    puts("PASS: frontend routing, messaging, secure options/passwords, state reconnect; protocol icons, sizes and fallback");
    /* Real Adium objects schedule deferred observers; process exit owns cleanup.
     * Deliberately avoid draining those callbacks into an absent application. */
    (void)pool;
    return 0;
}











