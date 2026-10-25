/* SPDX-License-Identifier: GPL-3.0-or-later */
#import <Adium/AIPlugin.h>
#import "ADPBackend.h"
#import "ADPService.h"
@interface ADPPlugin : AIPlugin
@end
@implementation ADPPlugin
- (void)installPlugin
{
    ADPBackend *backend = [ADPBackend sharedBackend];
    [backend report:[NSString stringWithFormat:@"Bridge %@ installed: isolated system libpurple backend", [self pluginVersion]]];
    [backend start];
    /* Register services before Adium restores account objects. */
    for (NSDictionary *descriptor in [backend protocols]) {
        [[[ADPService alloc] initWithProtocol:descriptor] autorelease];
        [backend report:[NSString stringWithFormat:@"Registered %@ (%@) from %@", [descriptor objectForKey:@"name"],
            [descriptor objectForKey:@"id"], [descriptor objectForKey:@"path"] ?: @"cached protocol metadata"]];
    }
}
- (void)uninstallPlugin { [[ADPBackend sharedBackend] stop]; }
- (NSString *)pluginAuthor { return @"Adium Dynamic Purple contributors"; }
- (NSString *)pluginDescription { return @"System libpurple protocols as Adium services, using an isolated backend process."; }
- (NSString *)pluginVersion { return [[[NSBundle bundleForClass:[self class]] infoDictionary] objectForKey:@"CFBundleShortVersionString"]; }
- (NSString *)pluginURL { return @"https://github.com/EionRobb/adium-dynamic-purple"; }
@end
