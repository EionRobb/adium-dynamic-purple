/* SPDX-License-Identifier: GPL-3.0-or-later */
#import "ADPAccountView.h"
#import "ADPAccount.h"


@implementation ADPAccountView
- (void)dealloc { [protocolView release]; [controls release]; [super dealloc]; }
- (void)configureForAccount:(AIAccount *)inAccount
{
    [super configureForAccount:inAccount];
    [protocolView release]; protocolView = nil;
    [controls release]; controls = [[NSMutableDictionary alloc] init];
}
- (NSView *)optionsView
{
    if (protocolView) return protocolView;
    protocolView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 480, 280)];
    [protocolView setHasVerticalScroller:YES];
    NSArray *options = [[(ADPAccount *)account protocolDescriptor] objectForKey:@"options"];
    CGFloat height = MAX(280, 40 + [options count] * 38);
    NSView *document = [[[NSView alloc] initWithFrame:NSMakeRect(0, 0, 455, height)] autorelease];
    [protocolView setDocumentView:document];
    CGFloat y = height - 36;
    for (NSDictionary *option in options) {
        NSString *key = [option objectForKey:@"key"];
        NSString *title = [option objectForKey:@"label"] ?: key;
        id value = [(ADPAccount *)account protocolOptionValue:option];
        NSControl *control = nil;
        NSString *type = [option objectForKey:@"type"];
        if ([type isEqualToString:@"bool"]) {
            NSButton *button = [[[NSButton alloc] initWithFrame:NSMakeRect(12, y, 425, 28)] autorelease];
            [button setButtonType:NSSwitchButton]; [button setTitle:title];
            [button setState:value ? [value boolValue] : [[option objectForKey:@"default"] boolValue]];
            control = button;
        } else {
            NSTextField *label = [[[NSTextField alloc] initWithFrame:NSMakeRect(12, y, 200, 24)] autorelease];
            [label setEditable:NO]; [label setBezeled:NO]; [label setDrawsBackground:NO]; [label setStringValue:title];
            [document addSubview:label];
            if ([type isEqualToString:@"list"]) {
                NSPopUpButton *popup = [[[NSPopUpButton alloc] initWithFrame:NSMakeRect(215, y, 220, 28)] autorelease];
                NSString *selected = value ?: @"";
                for (NSDictionary *pair in [option objectForKey:@"values"]) {
                    [popup addItemWithTitle:@""];
                    [[popup lastItem] setTitle:[pair objectForKey:@"label"]];
                    [[popup lastItem] setRepresentedObject:[pair objectForKey:@"value"]];
                    if ([selected isEqual:[[popup lastItem] representedObject]]) [popup selectItem:[popup lastItem]];
                }
                control = popup;
            } else if ([type isEqualToString:@"string"] || [type isEqualToString:@"int"]) {
                Class fieldClass = [type isEqualToString:@"string"] && [[option objectForKey:@"masked"] boolValue] ? [NSSecureTextField class] : [NSTextField class];
                NSTextField *field = [[[fieldClass alloc] initWithFrame:NSMakeRect(215, y, 220, 24)] autorelease];
                if (!value || value == [NSNull null]) value = @"";
                [field setStringValue:[value description]];
                if ([type isEqualToString:@"int"]) {
                    NSNumberFormatter *formatter = [[[NSNumberFormatter alloc] init] autorelease];
                    [formatter setAllowsFloats:NO]; [field setFormatter:formatter];
                }
                control = field;
            }
        }
        if (control) {
            [controls setObject:control forKey:key];
            [document addSubview:control];
        }
        y -= 38;
    }
    return protocolView;
}
- (void)saveConfiguration
{
    [super saveConfiguration];
    if (!protocolView) return;
    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    for (NSString *key in controls) {
        NSControl *control = [controls objectForKey:key];
        id value;
        if ([control isKindOfClass:[NSPopUpButton class]]) value = [[(NSPopUpButton *)control selectedItem] representedObject];
        else if ([control isKindOfClass:[NSButton class]]) value = [NSNumber numberWithBool:[(NSButton *)control state] == NSOnState];
        else value = [control stringValue];
        if (value) [values setObject:value forKey:key];
    }
    [(ADPAccount *)account setProtocolOptionValues:values];
}
@end



