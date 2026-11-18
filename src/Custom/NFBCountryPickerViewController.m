//
//  NFBCountryPickerViewController.m
//  NeoFreeBird (custom tweaks)
//

#import "Custom/NFBCountryPickerViewController.h"
#import "Core/BHTBundle.h"
#import "Custom/NFBCountryStore.h"
#import "ThemeColor/Palette.h"

typedef NS_ENUM(NSInteger, NFBPickerSection) {
    NFBPickerSectionSelected = 0,
    NFBPickerSectionRegions,
    NFBPickerSectionCountries,
    NFBPickerSectionCount,
};

@interface NFBCountryPickerViewController () <UISearchResultsUpdating>
@property (nonatomic, strong) NSMutableSet<NSString*>* selection;
@property (nonatomic, copy) NSArray<NSString*>* selectedKeys;
@property (nonatomic, copy) NSArray<NFBCountryRegion*>* visibleRegions;
@property (nonatomic, copy) NSArray<NSString*>* visibleCountries;
@property (nonatomic, strong) UISearchController* search;
@end

@implementation NFBCountryPickerViewController

static NSString* L(NSString* key) {
    return [[BHTBundle sharedBundle] localizedStringForKey:key];
}

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = L(@"BLOCKED_COUNTRIES_TITLE");
    self.view.backgroundColor = [Palette currentBackgroundColor];
    self.tableView.backgroundColor = [Palette currentBackgroundColor];
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"cell"];

    self.selection = [[NFBCountryStore sharedStore].blockedKeys mutableCopy];

    self.search = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.search.searchResultsUpdater = self;
    self.search.obscuresBackgroundDuringPresentation = NO;
    self.search.searchBar.placeholder = L(@"BLOCKED_COUNTRIES_SEARCH");
    self.navigationItem.searchController = self.search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:L(@"BLOCKED_COUNTRIES_CLEAR")
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(clearAll)];
    [self reloadVisible];
}

- (void)reloadVisible {
    NFBCountryStore* store = [NFBCountryStore sharedStore];
    NSString* query = [self.search.searchBar.text
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].lowercaseString;

    BOOL (^matches)(NSString*) = ^BOOL(NSString* text) {
        return query.length == 0 ||
               [text rangeOfString:query options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch].location !=
                   NSNotFound;
    };

    NSMutableArray* regions = [NSMutableArray array];
    for (NFBCountryRegion* region in store.regions) {
        if (matches(region.name)) [regions addObject:region];
    }
    NSMutableArray* countries = [NSMutableArray array];
    for (NSString* country in store.countries) {
        if (matches(country) || matches([store displayNameForKey:country])) [countries addObject:country];
    }
    self.visibleRegions = regions;
    self.visibleCountries = countries;
    self.selectedKeys = [self.selection.allObjects sortedArrayUsingSelector:@selector(compare:)];
    [self.tableView reloadData];
}

- (void)updateSearchResultsForSearchController:(UISearchController*)searchController {
    [self reloadVisible];
}

- (void)commit {
    [NFBCountryStore sharedStore].blockedKeys = [self.selection copy];
}

- (void)clearAll {
    [self.selection removeAllObjects];
    [self commit];
    [self reloadVisible];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView*)tableView {
    return NFBPickerSectionCount;
}

- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case NFBPickerSectionSelected: return self.selectedKeys.count;
        case NFBPickerSectionRegions: return self.visibleRegions.count;
        default: return self.visibleCountries.count;
    }
}

- (NSString*)tableView:(UITableView*)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case NFBPickerSectionSelected: return self.selectedKeys.count ? L(@"BLOCKED_COUNTRIES_SELECTED") : nil;
        case NFBPickerSectionRegions: return self.visibleRegions.count ? L(@"BLOCKED_COUNTRIES_REGIONS") : nil;
        default: return self.visibleCountries.count ? L(@"BLOCKED_COUNTRIES_COUNTRIES") : nil;
    }
}

- (NSString*)tableView:(UITableView*)tableView titleForFooterInSection:(NSInteger)section {
    if (section != NFBPickerSectionCountries) return nil;
    NFBCountryStore* store = [NFBCountryStore sharedStore];
    return [NSString stringWithFormat:L(@"BLOCKED_COUNTRIES_FOOTER"), (unsigned long)store.cachedAccountCount];
}

- (NSString*)keyForIndexPath:(NSIndexPath*)indexPath {
    switch (indexPath.section) {
        case NFBPickerSectionSelected: return self.selectedKeys[indexPath.row];
        case NFBPickerSectionRegions: return self.visibleRegions[indexPath.row].key;
        default: return self.visibleCountries[indexPath.row];
    }
}

- (UITableViewCell*)tableView:(UITableView*)tableView cellForRowAtIndexPath:(NSIndexPath*)indexPath {
    UITableViewCell* cell = [tableView dequeueReusableCellWithIdentifier:@"cell" forIndexPath:indexPath];
    NFBCountryStore* store = [NFBCountryStore sharedStore];
    NSString* key = [self keyForIndexPath:indexPath];
    NSString* flag = [store flagForCountry:key];
    NSString* name = [store displayNameForKey:key];

    if (indexPath.section == NFBPickerSectionRegions) {
        NFBCountryRegion* region = self.visibleRegions[indexPath.row];
        name = [NSString stringWithFormat:@"%@  (%lu)", region.name, (unsigned long)region.members.count];
    }
    cell.textLabel.text = flag.length ? [NSString stringWithFormat:@"%@  %@", flag, name] : name;
    cell.textLabel.textColor = UIColor.labelColor;
    cell.accessoryType = [self.selection containsObject:key] ? UITableViewCellAccessoryCheckmark
                                                             : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString* key = [self keyForIndexPath:indexPath];
    if ([self.selection containsObject:key]) {
        [self.selection removeObject:key];
    } else {
        [self.selection addObject:key];
    }
    [self commit];
    [self reloadVisible];
}

@end
