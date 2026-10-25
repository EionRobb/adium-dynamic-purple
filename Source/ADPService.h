/* SPDX-License-Identifier: GPL-3.0-or-later */
#import <Adium/AIService.h>
@interface ADPService : AIService {
    NSDictionary *descriptor;
    NSString *identifier;
    NSString *displayName;
}
- (id)initWithProtocol:(NSDictionary *)protocol;
- (NSDictionary *)protocolDescriptor;
@end
