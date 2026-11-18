//
//  NFBMutedTopicsViewController.m
//  NeoFreeBird (custom tweaks)
//

#import "Custom/NFBMutedTopicsViewController.h"
#import "Core/BHTBundle.h"
#import "Custom/NFBMutedTopics.h"
#import "ThemeColor/Palette.h"

@implementation NFBMutedTopicsViewController

static NSString* L(NSString* key) {
    return [[BHTBundle sharedBundle] localizedStringForKey:key];
}

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = L(@"MUTED_TOPICS_TITLE");
    self.view.backgroundColor = [Palette currentBackgroundColor];
    self.tableView.backgroundColor = [Palette currentBackgroundColor];
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"cell"];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                      target:self
                                                      action:@selector(addTopic)];
    [[NSNotificationCenter defaultCenter] addObserver:self.tableView
                                             selector:@selector(reloadData)
                                                 name:NFBMutedTopicsDidChangeNotification
                                               object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self.tableView];
}

- (void)addTopic {
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:L(@"MUTED_TOPICS_ADD_TITLE")
                                                                   message:L(@"MUTED_TOPICS_ADD_MESSAGE")
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField* field) {
        field.autocapitalizationType = UITextAutocapitalizationTypeWords;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:L(@"MUTED_TOPICS_CANCEL")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    __weak UIAlertController* weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:L(@"MUTED_TOPICS_MUTE")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction* action) {
                                                NSString* name = weakAlert.textFields.firstObject.text;
                                                [[NFBMutedTopics shared] muteTopicID:nil name:name];
                                            }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section {
    return [NFBMutedTopics shared].topics.count;
}

- (NSString*)tableView:(UITableView*)tableView titleForFooterInSection:(NSInteger)section {
    return L(@"MUTED_TOPICS_FOOTER");
}

- (UITableViewCell*)tableView:(UITableView*)tableView cellForRowAtIndexPath:(NSIndexPath*)indexPath {
    UITableViewCell* cell = [tableView dequeueReusableCellWithIdentifier:@"cell" forIndexPath:indexPath];
    NSDictionary* topic = [NFBMutedTopics shared].topics[indexPath.row];
    NSString* name = topic[@"name"];
    NSString* topicID = topic[@"id"];
    cell.textLabel.text = name.length ? name
                                      : [NSString stringWithFormat:L(@"MUTED_TOPICS_UNNAMED"), topicID ?: @""];
    cell.textLabel.textColor = UIColor.labelColor;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}

- (UISwipeActionsConfiguration*)tableView:(UITableView*)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath*)indexPath {
    // Capture the topic itself, not the row: the list may change before the
    // action fires.
    NSDictionary* topic = [NFBMutedTopics shared].topics[indexPath.row];
    NSString* topicID = topic[@"id"];
    NSString* name = topic[@"name"];
    UIContextualAction* unmute =
        [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                title:L(@"MUTED_TOPICS_UNMUTE")
                                              handler:^(UIContextualAction* action, UIView* view,
                                                        void (^done)(BOOL)) {
                                                  [[NFBMutedTopics shared] unmuteTopicID:topicID name:name];
                                                  done(YES);
                                              }];
    return [UISwipeActionsConfiguration configurationWithActions:@[unmute]];
}

@end
