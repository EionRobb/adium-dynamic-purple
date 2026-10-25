/* SPDX-License-Identifier: GPL-3.0-or-later */
#import "ADPService.h"
#import "ADPAccount.h"
#import "ADPAccountView.h"
#import "ADPJoinChatView.h"
#import <Adium/AISharedAdium.h>
#import <Adium/AIStatusControllerProtocol.h>
@implementation ADPService
- (id)initWithProtocol:(NSDictionary *)protocol
{
    /* AIService.init registers self and calls these getters synchronously. */
    descriptor = [protocol copy];
    identifier = [[protocol objectForKey:@"id"] copy];
    displayName = [([protocol objectForKey:@"name"] ?: identifier) copy];
    return [super init];
}
- (void)dealloc { [descriptor release]; [identifier release]; [displayName release]; [super dealloc]; }
- (NSDictionary *)protocolDescriptor { return descriptor; }
- (Class)accountClass { return [ADPAccount class]; }
- (AIAccountViewController *)accountViewController { return [ADPAccountView accountViewController]; }
- (NSString *)serviceCodeUniqueID { return [@"dynamic-purple:" stringByAppendingString:identifier]; }
- (NSString *)serviceID { return [@"DynamicPurple:" stringByAppendingString:identifier]; }
- (NSString *)serviceClass { return [self serviceID]; }
- (NSString *)shortDescription { return displayName; }
- (NSString *)longDescription { return [displayName stringByAppendingString:@" (system libpurple)"]; }
- (AIServiceImportance)serviceImportance { return AIServiceSecondary; }
/* Adium requests independent NSImages for normal/flipped variants. Let its
 * service icon cache own the results, rather than sharing an NSImage here. */
- (NSDictionary *)iconForType:(AIServiceIconType)type
{
    NSArray *sizes = type == AIServiceIconLarge ?
        [NSArray arrayWithObjects:@48, @64, @96, @128, @256, @512, @32, @24, @22, @16, @0, nil] :
        [NSArray arrayWithObjects:@16, @22, @24, @32, @48, @64, @96, @128, @256, @512, @0, nil];
    for (NSNumber *size in sizes)
        for (NSDictionary *icon in [descriptor objectForKey:@"icons"])
            if ([[icon objectForKey:@"size"] isEqual:size]) {
                NSString *path = [icon objectForKey:@"path"];
                if (![path isKindOfClass:[NSString class]] || ![path isAbsolutePath]) continue;
                NSImage *image = [[[NSImage alloc] initWithContentsOfFile:path] autorelease];
                if (image && [image isValid]) return [NSDictionary dictionaryWithObjectsAndKeys:image, @"image", path, @"path", nil];
            }
    return nil;
}
- (NSImage *)defaultServiceIconOfType:(AIServiceIconType)type
{
    NSImage *image = [[self iconForType:type] objectForKey:@"image"];
    if (!image) image = [[[NSImage imageNamed:NSImageNameNetwork] copy] autorelease];
    CGFloat dimension = type == AIServiceIconLarge ? 32 : 16;
    [image setSize:NSMakeSize(dimension, dimension)];
    return image;
}
- (NSString *)pathForDefaultServiceIconOfType:(AIServiceIconType)type
{
    return [[self iconForType:type] objectForKey:@"path"];
}
- (BOOL)caseSensitive { return YES; }
- (BOOL)isHidden { return NO; }
- (BOOL)supportsProxySettings { return NO; }
- (BOOL)canRegisterNewAccounts { return NO; }
- (BOOL)canCreateGroupChats { return [[descriptor objectForKey:@"chat"] boolValue]; }
- (DCJoinChatViewController *)joinChatView { return [ADPJoinChatView joinChatView]; }
- (BOOL)supportsPassword { return ![[descriptor objectForKey:@"noPassword"] boolValue]; }
- (BOOL)requiresPassword { return [self supportsPassword] && ![[descriptor objectForKey:@"passwordOptional"] boolValue]; }
- (NSString *)UIDPlaceholder { return @"username"; }
- (void)registerStatuses
{
    NSArray *names = [NSArray arrayWithObjects:STATUS_NAME_AVAILABLE, STATUS_NAME_AWAY, STATUS_NAME_DND, STATUS_NAME_INVISIBLE, nil];
    AIStatusType types[] = {AIAvailableStatusType, AIAwayStatusType, AIAwayStatusType, AIInvisibleStatusType};
    for (NSUInteger i = 0; i < [names count]; ++i) {
        NSString *name = [names objectAtIndex:i];
        [adium.statusController registerStatus:name withDescription:[adium.statusController localizedDescriptionForCoreStatusName:name]
            ofType:types[i] forService:self];
    }
}
@end
