//
//  TimelinesSettingsViewController.m
//  NeoFreeBird
//
//  Created by nyaathea
//

#import "Settings/Pages/TimelinesSettingsViewController.h"
#import "Custom/NFBCountryPickerViewController.h"
#import "Custom/NFBCountryStore.h"
#import "Custom/NFBMutedTopics.h"
#import "Custom/NFBMutedTopicsViewController.h"
#import "Headers/TWHeaders.h"

extern void applyHideCustomTimelinesSetting(void);

@implementation TimelinesSettingsViewController

- (NSString*)pageKey {
    return @"timelines";
}

// The country and topic rows show a summary as their subtitle; refresh it
// when coming back from their screens.
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

- (void)switchChanged:(UISwitch*)sender {
    [super switchChanged:sender];
    NSString* key = objc_getAssociatedObject(sender, @"prefKey");
    if ([key isEqualToString:@"hide_custom_timelines"]) {
        applyHideCustomTimelinesSetting();
    } else if ([key isEqualToString:@"block_countries"]) {
        if (sender.isOn) [[NFBCountryStore sharedStore] refreshQueryIDForce:NO];
        // An empty handle list re-filters every visible timeline.
        [[NSNotificationCenter defaultCenter] postNotificationName:NFBCountryStoreDidUpdateNotification
                                                            object:nil
                                                          userInfo:@{@"screenNames": @[]}];
    } else if ([key isEqualToString:@"permanent_topic_mutes"]) {
        [[NSNotificationCenter defaultCenter] postNotificationName:NFBMutedTopicsDidChangeNotification object:nil];
    }
}

- (void)showBlockedCountries:(NSDictionary*)sender {
    [self.navigationController pushViewController:[NFBCountryPickerViewController new] animated:YES];
}

- (void)showMutedTopics:(NSDictionary*)sender {
    [self.navigationController pushViewController:[NFBMutedTopicsViewController new] animated:YES];
}

@end
