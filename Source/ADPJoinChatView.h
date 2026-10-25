/* SPDX-License-Identifier: GPL-3.0-or-later */
#import <Adium/DCJoinChatViewController.h>
@interface ADPJoinChatView : DCJoinChatViewController <NSTextFieldDelegate> {
    NSMutableDictionary *fields;
    NSMutableSet *required;
    BOOL available;
}
@end
