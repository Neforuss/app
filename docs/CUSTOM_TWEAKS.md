# Custom tweaks

Eight additions on top of NeoFreeBird. Most of the code lives in `src/Custom/`. Existing files were only edited where a feature extends code that is already there.

All settings live in NeoFreeBird's own settings. Open them by holding the X/Twitter icon at the top of the home feed.

| # | Tweak | Settings page → row | Default |
|---|---|---|---|
| 1 | Hide accounts by country (X-Posed) | Timelines → Hide accounts by country, then Blocked countries | off |
| 2 | Never autoplay GIFs | Media → Never autoplay GIFs | off |
| 3 | Open on Following | Timelines → Open on Following | off |
| 4 | Permanent topic mutes | Timelines → Permanent topic mutes, then Muted topics | off |
| 5 | Remove infinite scroll | Timelines → Remove infinite scroll | off |
| 6 | Square corners | Profiles → Sharp-cornered profile pictures; Media → Square media corners | off |
| 7 | Download photos | Media → Download videos → Download photos | on |
| 8 | Copy All profile details | Profiles → Copy profile details (existing), then "Copy all" in the sheet | n/a |

## How each one works

**1. Hide accounts by country.**
- Country data comes from X's "About this account" (`AboutAccountQuery`), the same query X-Posed and NeoFreeBird's location labels use.
- Each author is looked up once, paced to 2 requests in flight 350 ms apart. X's 429 cooldown is honoured and persisted. Results are cached on disk for 60 days, or 6 hours when X reports no location.
- Posts show until the author's country is known, then disappear (X-Posed's default).
- Matching follows X-Posed, including its two region modes. Tapping a region offers:
  - **Region label only** (X-Posed's default): hides only accounts X labels with the region itself, such as "Europe".
  - **Region label and all its countries**: also hides every account based in one of its member countries.
- Filtering applies to feeds and search, and to replies in a conversation. The post you opened, profiles, notifications and user lists (followers, following, who to follow) are never filtered, and neither are your own posts.
- Removing a country takes effect on the next refresh: posts already hidden are not put back mid-scroll.
- Code: `NFBCountryStore`, `NFBCountryPickerViewController`, `CustomTimeline.x`.

**X-Posed sync** has three layers:
1. `tools/xposed-sync/sync.mjs` imports X-Posed's real `constants.js`, `region-geography.js` and `region-membership.js` with Node. It writes `BHTwitter.bundle/xposed_sync.json`, plus `tests/fixtures/xposed_vectors.json`: answers computed by X-Posed's own `canonicalCountry()` and `matchingBlockedRegions()`.
2. `.github/workflows/xposed-sync.yml` runs that script weekly. When X-Posed's data changed (not just its commit), it updates a single `xposed-sync` branch, opens a PR if none is open, and dispatches the checks on that branch. One-time setup: enable scheduled workflows in the fork's Actions tab, and turn on Settings → Actions → General → "Allow GitHub Actions to create and approve pull requests".
3. The app refreshes the `AboutAccountQuery` ID from X-Posed's `constants.js` at most once a day. It also does so immediately after a 400/404, so an ID rotation needs no rebuild.

The lookups use the web session that NeoFreeBird's location labels already rely on (`currentWebCredentials()` in `WebCreateTweet.x`). If that session doesn't exist, lookups wait and retry.

**2. Never autoplay GIFs.** Hooks `T1AccountAutoplayPolicy -autoplayableIsEligibleForAutoplayWithAutoplayable:environment:` and answers NO for GIFs. GIFs are identified through the player source's `isGIF`, the media entity (`mediaType == 2`), or as a last resort the player view's class name. Videos are untouched. Code: `CustomMedia.x`.

**3. Open on Following.** The first time the home feed appears after launch, it selects the Following tab of `TFNScrollingSegmentedViewController`:
- It picks the tab by title, falling back to the second built-in tab.
- It uses the tab's own tap path, so X loads the tab normally.
- On the older Objective-C home container, it answers `_t1_lastSelectedTimelineViewController` with the Following timeline.

Tabs you pick later are left alone. Code: `CustomMedia.x`.

**4. Permanent topic mutes.** Topics get on the list in three ways:
1. X's own "less of this topic" GraphQL calls: any operation naming Topic plus Snooze, NotInterested, StopRecommending, Mute, Dismiss or Hide, recorded only once X answers 2xx. Reversals never count, even though they use the same words (`TopicDeleteNotInterestedMutation`, Undo, Unmute, Remove…). Topic IDs are read from the request.
2. The "Not interested in this topic" and "Stop recommending" post actions (`T1StatusViewMarkTopicNotInterestedEventHandler`, `T1StatusViewTopicStopRecommendingEventHandler`). An Undo removes the mute again, both the toast's Undo (`T1StatusViewTopicStopRecommendingUndoEventHandler`) and X's reversal calls such as `TopicDeleteNotInterestedMutation`. It only removes a mute made in the last 2 minutes, so an older permanent mute of the same topic is never lost to an Undo.
3. Typing a topic name on the Muted topics screen.

Muted topics are removed in two places: from GraphQL responses (any timeline entry that references the topic by ID or name), and from timeline sections (the post's topic banner or social context). Topic names seen in responses are remembered, so topics captured by ID alone get a readable name. Code: `NFBMutedTopics`, `NFBMutedTopicsViewController`, `CustomTimeline.x`.

**5. Remove infinite scroll.** Strips bottom cursors (`cursor-bottom-…` entries, `cursor_type: Bottom`, and `TimelineReplaceEntry` instructions that target them) from the `HomeTimeline` and `HomeLatestTimeline` responses. The feed then ends. Top cursors are kept, so pull-to-refresh still loads new posts. Code: `CustomTimeline.x`.

**6. Square corners.**
- Avatars: "Sharp" builds on the existing Square option and sets the corner radius to 0 (`Avatars.x`).
- Media: the timeline layout radius (`+[T1StatusViewAttachmentLayoutSpec photoVideoCornerRadiusForOptions:]`) goes to 0, and so do the layers of the multi-photo grid (`TweetMediaAttachments.MultiMediaView`) and the inline media container after each layout.
- Only views that fill the picture or media are squared. Overlays (GIF, ALT and duration pills, the play button, verified badges) keep their shape.
- Turning either option off restores the original radii without a relaunch.

**7. Download photos.** Download media now appears on photo posts too:
- One photo downloads straight away, at full resolution (`name=orig`).
- Several items give a sheet: "Download all photos (N)" or "Download all media (N)", then one row per photo or video in post order. Videos keep their usual quality picker.
- Batch downloads run in parallel, then go to Photos when Direct save is on, or to one share sheet otherwise. If some files fail, you're told how many, and the rest are still delivered.

Code: `DownloadInlineButton.m`, `MediaDownloads.x`.

**8. Copy All.** The first row of the Copy profile details sheet copies:

```
Name: wint
Username: @dril
Bio:
welcome to my shit
https://patreon.com/dril
...
Location: LA
Website: https://linktr.ee/drilreal
Profile URL: https://x.com/dril
User ID: 16298441
Date joined: September 15, 2008
```

Links are expanded from the profile's URL entities, so you get the full address, never `t.co` or a "…"-truncated one. Empty fields are left out. The single-field buttons now copy the same expanded values. Code: `Profile.x`, with formatting in `NFBCustomLogic.m`.

## Robustness

- Every hook into an X class is installed only when that class and selector exist at runtime. A rename in a future X build switches that feature off; it doesn't crash the app.
- Model fields are read through `NFBRuntime.h`, which checks each method's return type before calling it.
- Device logs carry the prefix `[NFB custom]`: which hooks were unavailable, which topic actions were captured, how many entries were filtered, rate-limit windows, and query-ID changes. Filter Console.app (or `idevicesyslog`) on that prefix.

## Building and testing

The logic tests run anywhere with Xcode's command-line tools, from the repo root:

```bash
clang -fobjc-arc -framework Foundation -Isrc src/Custom/NFBCustomLogic.m tests/CustomLogicTests.m -o /tmp/custom_logic_tests && /tmp/custom_logic_tests
```

Other commands:
- **Strings check:** `python3 tools/xposed-sync/check_strings.py`
- **Re-sync X-Posed data:** `node tools/xposed-sync/sync.mjs <path to an x-account-location-device checkout>`. Add `--check` to only report drift.
- **Full build:** `.github/workflows/custom-checks.yml` builds the rootless `.deb` on every push (no IPA needed). For an installable IPA, use the existing Build Tweak workflow with your decrypted IPA URL, as in the main README.

## Device acceptance tests

Run these on a pinned X version, then again after the next X update.

1. Block two countries, and Europe in "label only" mode (a German account must stay visible). Follow or search a few accounts known to be based there, checking each against X-Posed in a desktop browser. Their posts disappear from Following and For You within a few seconds of first showing. Accounts from other countries stay. 15 minutes of scrolling produces no rate-limit message in the logs.
2. With video autoplay on and "Never autoplay GIFs" on, videos play and GIFs stay still until tapped.
3. Force-quit 5 times, including once after leaving the app on For You. It opens on Following each time.
4. Snooze (or mark Not interested) a topic on a For You post. It appears under Muted topics. 48 hours later its posts are still gone. Unmute it, refresh, and they can return.
   Also open a post with replies from a blocked country. The opened post stays, and the blocked replies disappear. If none disappear, check the log line `conversation entry IDs:`: reply detection expects IDs containing `conversationthread`.
5. Scroll Following to the bottom. It stops, with no spinner. Pull to refresh still loads new posts.
6. With both square options on, avatars and media have 90-degree corners in the timeline, a thread, a quote and the multi-photo grid. Turning them off restores the rounding.
7. A 4-photo post: "Download all photos (4)" saves 4 full-size images. A photo + video post: "Download all media (2)" saves both.
8. On @dril, Copy all, then paste into Notes. Every link opens the right page, and every line matches the single-field copy buttons.

## Known limits

- **Hook names and the dump:** they come from `NeoFreeBird/classdump`, dumped September 2025. The Swift home container and the 2026 Snooze UI aren't in that dump. Tab selection works through the shared segmented controller, and snooze capture matches operation names generically. Check the `[NFB custom]` logs on a new X version.
- **"Snooze Topics":** if X's snooze call carries no topic ID in its URL or body, it won't be captured. Topics can still be muted from the post menu or by name. The log line `topic action <name> carried topic IDs (...)` shows what was seen.
- **Strings:** new strings exist in English only. Other languages show the raw key until translated, the same as the existing partial translations (`./check_localization.py <lang>` lists them).
- **Settings export:** the blocked-countries list and muted topics aren't part of NeoFreeBird's settings export.
- **Undoing a hide:** unblocking a country or unmuting a topic shows those posts again on the next refresh, not instantly. Re-filtering only ever removes posts, so it can never bring back one that X itself removed.
- **Region modes:** the iOS picker offers X-Posed's "label only" and "label + all countries" modes per region, but not its hand-picked subset of a region's countries. Pick those countries individually instead.
