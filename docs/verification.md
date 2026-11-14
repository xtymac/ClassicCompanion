# Public export verification

Verified on 2026-11-11 in the standalone public-source directory using Apple silicon, macOS 27.2, Xcode 27.2 and Swift 6.4.2.

| Check | Result |
| --- | --- |
| `swift test` | Passed: 283 XCTest and 40 Swift Testing tests, zero failures |
| `CC_SIGNING_MODE=adhoc scripts/build-app.sh debug` | Passed; build 20261111.1614, bundle signature verification passed |
| Shell script syntax | All included `.sh` scripts passed `zsh -n` |
| Documentation | Relative Markdown links checked; four language READMEs included |
| Source integrity | Sources and Tests match the previously validated recovery implementation byte-for-byte |

The build emitted existing concurrency/toolchain warnings during tests and a strip-before-resigning warning during packaging; these did not fail the checks. No warnings were suppressed for this publication.

This run did not repeat live website/network acceptance, Wi-Fi-off or reboot/login-item testing, or create a notarized release. Those limitations remain in the review guide. Existing published installers have not changed.

## Publication preparation

- New Git history containing only the curated tree; no private commits or branches imported.
- Excluded internal developer/review records, design history, posters, screenshots, clipboard files, build products and local tooling caches.
- Included required icon resources; source and included assets use Apache-2.0. Branding is documented separately without adding copyright restrictions.
- Replaced hard-coded signing name/team/profile defaults with explicit maintainer configuration.
- Checked tracked text for common token/private-key patterns, local home paths and maintainer signing identifiers; no remaining matches. Reviewed external references and package dependencies. This is a publication hygiene review, not an independent security or intellectual-property audit.

For the exact tree under review, record `git rev-parse HEAD` with any feedback.

## Repository consolidation — 2026-11-11

The public source repository was transferred to `xtymac/ClassicCompanion`. It now hosts source, Issues and Releases together. The old source URL redirects here; the legacy distribution repository retains a migration notice and its original files.

After updating feedback links, the complete suite passed again (283 XCTest + 40 Swift Testing, zero failures) and ad-hoc debug build 20261111.2345 passed. The seven beta release assets were copied unchanged and verified byte-for-byte after downloading them from the new repository. The DMG is still build 20261110.0137, not this debug build; it does not include the newer source fix. The beta tag retains the original distribution commit, so its auto-generated source archives are the legacy distribution tree, not the current app implementation. Use main for current source.

Finalized posters are displayed from the retained legacy repository without modifying their files. No private repository contents or history were changed or imported during this migration.

## In-app updates port — 2026-11-13

Ported from the private backup as focused commits: the lightning-bolt menu bar icon, the New Chat draft fix with its page tests, Sparkle 2 in-app updates (consent before download, beta channel, EdDSA-signed appcast tooling) and Sparkle's MIT license notice in the app bundle. The feed address is `https://raw.githubusercontent.com/xtymac/ClassicCompanion/main/appcast.xml`; nothing has been published there yet. The isolated upgrade-test tooling and internal acceptance records were not ported.

| Check | Result |
| --- | --- |
| `swift test --skip 'ChromeTests\|PageTests\|WindowExperienceTests'` | Passed: 206 XCTest and 40 Swift Testing tests, zero failures |
| PageTests, ChromeTests, WindowExperienceTests | Passed in this tree on 2026-11-13 at `c8a65e3`: ChromeTests 13, PageTests 42, WindowExperienceTests 47, zero failures (WindowExperienceTests rerun alone after an interrupted first attempt; the cause of that interruption was not confirmed) |
| `CC_SIGNING_MODE=adhoc scripts/build-app.sh debug` | Passed (build 20261113.1716): Sparkle 2.10.1 embedded, `codesign --verify --deep --strict` passed, SUFeedURL and feedback links point to this repository, Sparkle license notice present |
| Shell script syntax | All `.sh` scripts passed `zsh -n` |
| Publication hygiene | Added lines scanned for home paths, signing identifiers, personal contacts, key and token patterns; only the release EdDSA public key and an all-zero test key appear |

No signed or notarized build of this tree exists yet, and no update has been delivered through the real feed.

## Release candidate 0.1.0-beta.2 (build 20261113.1719) — 2026-11-13

Built from `c8a65e3` in a clean checkout of this repository. Main development and future releases are now made here; the legacy download repository and the former private repository are still being retired and have not been archived or deleted.

| Check | Result |
| --- | --- |
| Developer ID signing, hardened runtime, secure timestamp | Passed |
| Apple notarization (app and DMG) | Both Accepted with no issues; tickets stapled |
| `scripts/verify-release.sh --final` | 76 of 76 checks passed, including Gatekeeper, the HTTPS feed address, the release public key, the beta channel and the bundled Sparkle license notice |
| `scripts/prepare-appcast.sh` | Dry run and local appcast both passed 11 checks; the appcast has not been published |
| Production update-signing key backup | Verified on 2026-11-13 |

Isolated upgrade test (2026-11-13): a test copy with the same code and resources, served by a local test feed, showed that cancelling, quitting, force quitting or crashing before consent downloaded and installed nothing, and that the consented upgrade from an earlier test build reached 1719 with sign-in, the restored chat, settings and the shortcut kept. A local test feed is not the real HTTPS feed. The menu bar icon was checked in Dark and Light appearance, but the menu bar background stayed dark in both on the test Mac, so the icon on a light menu bar is unverified.

Not yet done: installing from the DMG or ZIP on a clean setup, the icon on a light menu bar background, and delivery through the real HTTPS feed (possible only after publication). At that point no Release, tag, attachment or appcast had been published for this build; see the release section below.

## Legacy feedback notice and beta.1 source note — 2026-11-13

Builds released before the move, including 0.1.0-beta.1, open the legacy repository's Issues page for feedback. That page showed no pointer to this repository, so a four-language notice was opened there, pinned and locked: <https://github.com/mactokyo/ClassicCompanion/issues/1>. Signed out, the legacy Issues page now shows it pinned at the top, and it links to this repository's Issues. At that point the legacy repository had not been archived; see the next section.

Its issue chooser now points to this repository: `.github/ISSUE_TEMPLATE/config.yml` there disables blank issues and adds a four-language contact link to this repository's Issues. Signed in as the repository owner, New issue opens a dialog with "Blank issue — Maintainers only" and that link; signed out, New issue leads to the GitHub sign-in page. The view of an account with read access only was not checked. This does not block every way of opening an issue there: people with write access can still open blank issues, and other routes such as the API may still work.

The [0.1.0-beta.1 Release notes](https://github.com/xtymac/ClassicCompanion/releases/tag/v0.1.0-beta.1) gained a four-language source note: the tag points to `086a39e`, a release-metadata commit (README only), not the complete source of build 20261110.0137. GitHub's generated source archives for that tag are not the exact source the installer was built from, and `main` holds later source. Only that paragraph changed. The tag, the seven assets and their checksums are unchanged; names, sizes and digests were compared before and after.

## Release 0.1.0-beta.2 (build 20261113.1719) — 2026-11-13

Published as a pre-release: <https://github.com/xtymac/ClassicCompanion/releases/tag/v0.1.0-beta.2>. The tag `v0.1.0-beta.2` points to `c8a65e3f556cb139ec77ca860f59f39769f11d90`, the commit the build was made from; later commits on `main` change documentation and the update feed only. The Release is not marked Latest, and the 0.1.0-beta.1 Release, tag and assets are unchanged.

The seven assets are the frozen files from the release candidate above, not rebuilt: the DMG, the ZIP, four trial notes and `SHA256SUMS`. On publication day `scripts/verify-release.sh --final` passed 76 of 76 checks again, and the assets uploaded to the draft were downloaded and compared byte-for-byte before it was published.

| Check (signed out, no authorization header) | Result |
| --- | --- |
| Release page | Loads, shows the pre-release and lists all seven files |
| Downloads | All seven files downloaded; size and SHA-256 match the release candidate files, and the files are byte-for-byte identical |
| `SHA256SUMS` | `shasum -a 256 -c` passes for the six files; the downloaded `SHA256SUMS` is identical to the release candidate's |
| Downloaded DMG | Stapled notarization ticket valid; Gatekeeper accepted it as Notarized Developer ID |
| App inside the downloaded DMG | Ticket valid; Gatekeeper accepted; `codesign --verify --deep --strict` passed; version 0.1.0-beta.2, build 20261113.1719, feed address below |

Update feed: <https://raw.githubusercontent.com/xtymac/ClassicCompanion/main/appcast.xml>, added in commit `cdc0e952a7e45b8f733bcb6091d79790fec75b93` after the downloads above passed. The file is the appcast generated and checked with `scripts/prepare-appcast.sh` for this build and was committed unchanged. Its single entry is in the beta channel: version 0.1.0-beta.2, build 20261113.1719, minimum macOS 15.0, arm64, enclosure URL equal to the published ZIP's download address, length 2747704 bytes (the ZIP's size). Using only the public key in the app, the feed signature and the ZIP's update signature both verified, and both failed as expected on altered input. Signed out, the feed address returned HTTP 200 with content byte-for-byte identical to the committed file; before the commit it returned 404, so no earlier feed was replaced.

Check for Updates with the real feed (2026-11-13): an existing installation was upgraded by hand from the DMG downloaded above, keeping the previous app as a rollback copy. It runs 0.1.0-beta.2 (build 20261113.1719) from Applications as a single instance, with the same code signature hash as the app in the public DMG. Its settings, shortcuts and language choice were unchanged, and it reopened the last chat without a sign-in redirect; the user then confirmed by eye that sign-in was kept, and turned on automatic update checks. Choosing Check for Updates… in the app menu showed "You’re up to date!" ("Classic Companion 0.1.0-beta.2 is currently the newest version available."); Sparkle logged that the appcast's EdDSA signature is correct, and no update error was reported. This verifies only the check against the real feed; installing a later version through it has not been verified.

Not verified: receiving an update through this feed (possible only when a later version is published), installing from the DMG or ZIP on a clean setup, macOS 15 and macOS 26, and the menu bar icon on a light menu bar background.

## Legacy download repository archived — 2026-11-14

Before archiving, the state of `mactokyo/ClassicCompanion` was backed up, its README was replaced with a four-language move notice (0.1.0-beta.2 is out with in-app updates; 0.1.0-beta.1 users install it once by hand; downloads, feedback and source are here; the legacy repository keeps only the 0.1.0-beta.1 download and the notice), and pinned issue #1 was updated with the same information. All links in both were checked signed out before the repository was archived.

Signed out after archiving, the repository page and its Issues page show GitHub's archived, read-only banner; the repository page shows the move notice, and the Issues page lists pinned issue #1 with no New issue button. `/issues/new` returns 404 and the issue chooser leads to the sign-in page; the signed-in view was not checked. The 0.1.0-beta.1 Release, tag and assets are unchanged, its DMG still downloads, and issue #1 is still pinned and locked. The former private repository has not been archived or deleted.

## Wake window mode (0.1.0-beta.3 candidate, build 20261114.0227) — 2026-11-14

Settings → General has a new option, Window Mode When Shown, used only by the show/hide shortcut: Keep Last Mode (the default, also for existing users, with no time limit) or Always Quick Window (the previous behavior). Clicking the Dock icon, ⌘Tab, reopening the app and restoring a minimized window keep the current mode as before, and the app still starts in the Quick window. The settings window's content area (below the title bar and toolbar) went from 480 to 550 pt high; see the size note below. The version in `scripts/build-app.sh` is now 0.1.0-beta.3. Nothing was released: no Release, tag, upload or appcast change. The candidate is ad-hoc signed and not notarized.

| Check | Result |
| --- | --- |
| `swift test --skip 'ChromeTests\|PageTests\|WindowExperienceTests'` | Passed: 214 XCTest and 40 Swift Testing tests, zero failures |
| ChromeTests, PageTests, WindowExperienceTests | Passed on the committed source: 13, 42 and 52 tests (five new wake-mode window tests among them), zero failures |
| `CC_SIGNING_MODE=adhoc scripts/build-app.sh release` | Passed: build 20261114.0227 |
| Shell script syntax | All `.sh` scripts passed `zsh -n` |
| Publication hygiene | Added lines scanned for home paths, signing identifiers, personal contacts, key and token patterns; none found |

The 120-second hide check below passed, but it records one observed case only. That the mode is kept with no time limit rests separately on the code, which takes no time input, and on its unit tests.

Isolated-copy check (2026-11-14): a copy with its own bundle ID and test data only (not signed in to ChatGPT). Every key press and click was synthesized by tools; none was a physical key press, and passing these tool-driven checks does not count as a physical-key check. Two problems were found and fixed before this commit. In build 20261114.0034, changing the app language while Settings was open left the selected option in English. The first fix, build 20261114.0218, rebuilt the pop-up menu, after which Tab no longer reached it. Build 20261114.0227 passes both checks. Between 0034 and 0227 only that pop-up menu changed, so the window checks run on 0034 still apply.

- Keep Last Mode (0034): the Quick and Full windows each came back in the same mode, position and size, without reloading the page, after hiding with the shortcut, ⌘W, the top close button, the red close button and Esc in the page. It did the same after 120 seconds hidden with another app in front, and when the shortcut was pressed during a Quick/Full switch, it woke in the mode just chosen.
- Same screen and another screen (0034): hidden and shown again on the same screen, the Full window kept its position and size. Hidden on the built-in display while the pointer was on another display, it woke as a Full window on the display with the pointer, at its earlier position there and the same size (1280×900). The page did not reload; whether it was laid out again was not checked. A target screen too small for the window, where it would have to shrink, was not tested.
- Dock icon, ⌘Tab, reopening the app, and ⌘M followed by the shortcut or by reopening (0034): the Full window came back as Full.
- Always Quick Window (0227): woke in the Quick window at its remembered position; changing the option did not move the open window; switching back to Keep Last Mode brought the Full window back as Full.
- Restart (0227): the choice survived two restarts, other settings were unchanged, and launch was still in the Quick window.
- Four languages (0227): label, note and both options correct in Simplified Chinese, Traditional Chinese, Japanese and English, including after switching the language with Settings open.
- Keyboard (0227): Tab reaches the option; Space, ↓ and Return change it; Tab and Shift-Tab move through the page.
- Settings window (0227): 500×630 pt on the screen used, which is the whole window (see below); the other connected screens are tall enough for it too, so its content did not need to scroll there.

In every wake above, the page was confirmed not to reload; whether it was laid out again was not checked.

Settings window size. The 550 pt in the code (`SettingsWindowLayout.contentHeight`, applied with `setContentSize`) is the height of the content area only, below the title bar and the toolbar. The 500×630 pt measured on the screen used is the whole window frame, read through Accessibility, including the title bar and the toolbar. The width is 500 pt for both the content area and the window. On screen, the title bar and toolbar therefore take 630 − 550 = 80 pt. To check that the content area really is 550 pt, a screenshot of the real window (build 0034, same settings layout) was compared with an off-screen render of the same page. In both, the top edge of the first settings group is 530 pt above the bottom of the window, so both content areas are the same 550 pt. The off-screen window is 638 pt because before a window is shown, AppKit gives its title bar and toolbar 88 pt. On a screen too short for 550 pt, the content height is limited using the title-bar-and-toolbar height measured when the window is fitted, which on first opening is before it is shown; this was not checked on a real short screen. Shorter screens, where only the content area shrinks and scrolls, are covered by unit tests only. The layout was not changed for this note.

Checked by the user by hand (2026-11-14, on the same isolated copy of build 0227, signed in to ChatGPT; reported by the user, not observed by tools):

- With physical key presses, Keep Last Mode and Always Quick Window behaved correctly.
- In a signed-in test chat, after hiding and showing the window again, the reading position and an unsent draft were as before. This covers hiding and showing only, not quitting, restarting or updating the app.

Not verified: real VoiceOver speech, a real network disconnect, whether the page is laid out again after waking, scrolling of the settings window on a short screen, and waking on another screen where the window has to shrink. Build 0227 was the candidate these checks were made on; the release candidate is built from the same source with the trial notes updated (see below).

## Release candidate 0.1.0-beta.3 (build 20261114.1404) — 2026-11-14

Built from `816276a` in a clean checkout of this repository. Since build 0227 only `docs/` changed (trial notes, update notes, this record); `Sources/`, `Tests/`, `scripts/` and `Package.swift` are the same as for 0227. Nothing was released: no Release, tag, upload or appcast change. The live update feed still offers 0.1.0-beta.2.

| Check | Result |
| --- | --- |
| Developer ID signing, hardened runtime, secure timestamp | Passed |
| Apple notarization (app and DMG) | Both Accepted with no issues; tickets stapled |
| `scripts/verify-release.sh --final` | 76 of 76 checks passed at packaging, including Gatekeeper, the HTTPS feed address, the release public key, the beta channel and the bundled Sparkle license notice; 72 of 76 after the trial-notes addition described below; 76 of 76 again after the attached notes were restored |
| `scripts/prepare-appcast.sh --dry-run` | 13 of 13 checks passed against the live beta.2 appcast; no appcast was kept or published |
| Gatekeeper with a simulated download | A copy of the final DMG marked as downloaded by a browser was accepted (Notarized Developer ID), its ticket was valid, the app inside was accepted, and `syspolicy_check distribution` passed |

In-app update from 0.1.0-beta.2, isolated test (2026-11-14). The test copy was made from the published beta.2 app, with its own bundle ID, its own test data, a local test feed and a test update-signing key. The update it installed was the beta.3 candidate app, given the same changes. Sparkle checked the feed and update signatures as usual. Nothing was downloaded until the consent dialog was confirmed. After confirming, the update was downloaded, its signature checked, and the app installed and restarted as 0.1.0-beta.3 (20261114.1404); its code and resources match the candidate DMG byte for byte once signatures are removed. Sign-in, the restored chat, an unsent draft, all existing settings and the shortcut were kept, and the new option showed Keep Last Mode. After the update a Full window hidden with the shortcut came back as Full; Always Quick Window was saved and survived a quit and reopen; checking again reported the copy up to date. Sign-in, the draft, the update check and both confirmations were done by the user; the other steps were tool-driven. Scope of "kept": one isolated copy on one Mac, updated once. Sign-in was checked by tools finding no sign-in buttons on the page. The draft was one unsent draft the user typed in a test chat, compared by length and a content fingerprint without reading the text. The settings were all of the copy's settings from before the update, compared one by one, including non-default app language, page zoom, both shortcuts and automatic update checks. The live update feed, other Macs, drafts in several chats and text being typed when an update starts were not covered. The reading position was not kept across the update restart: the app restores the chat address, not the scroll position, and a plain quit and reopen afterwards landed at the same position, so this applies to any restart, not only to updates. A local test feed is not the real HTTPS feed, so updating existing beta.2 installations through the live feed is still unverified.

Install from the final DMG (2026-11-14, on the test Mac, replacing its 0.1.0-beta.2 installation, which was kept for rollback). The app was copied from the final DMG to Applications in the Finder and opened. It was 0.1.0-beta.3 (20261114.1404) with the same code signature hash as the app in the DMG, passed `codesign --deep --strict` and Gatekeeper (Notarized Developer ID), and ran from Applications as a single instance; opening the copy inside the DMG as well handed over to the running app and quit. It reopened the previous chat without going to a sign-in page, and the shortcuts, page zoom, app language, restored chat and automatic update check setting were unchanged. With tool-driven input, the show/hide shortcut brought the Quick window back as Quick and the Full window back as Full without reloading the page, and Settings showed Keep Last Mode. Check for Updates against the live feed, which still offers 0.1.0-beta.2, reported the app up to date with a valid feed signature; this shows that the build reads the live HTTPS feed, not that updating from beta.2 through it works. The previous app was observed not running when the replacement started; this records only what was seen at that moment, not whether anything had been in progress or left unsaved before. For sign-in after the replacement there is only indirect evidence (same data, restored chat, no sign-in redirect); sign-in and any draft left in the previous app are waiting for a manual check by the user. The macOS confirmation shown on first opening a downloaded copy did not appear, because the local DMG carries no download mark.

Not verified: updating existing installations through the live HTTPS feed (possible only after publication), the first-opening confirmation, installing from the ZIP, a clean setup, macOS 15 and macOS 26, and physical key presses on this build.

Trial notes after the checks (2026-11-14): one paragraph was added to each of the four trial notes (`docs/trial-notes*.md` and the `TrialNotes.*.md` files kept next to the candidate DMG): after an update, or a quit and reopen, the app goes back to the last chat but not to the scroll position; hiding and showing the window keeps the reading position; in the isolated update, sign-in, an unsent draft and settings were kept. The app was not rebuilt or re-signed, so the trial notes shown inside build 20261114.1404 do not have this paragraph. The attached files differ from the copies inside the app by that one paragraph in each language, so `scripts/verify-release.sh --final` now fails exactly those four comparisons (72 of 76 pass; everything else is unchanged). `SHA256SUMS` was regenerated; the DMG and ZIP checksums did not change.

Attached notes restored (2026-11-14): the four attached `TrialNotes.*.md` files were restored from the copies kept before the edit, so they again equal the trial notes inside build 20261114.1404 (made from `816276a`). `SHA256SUMS` was regenerated and is byte-identical to the one made at packaging, and `scripts/verify-release.sh --final`, with its checks unchanged, passes 76 of 76 again. The 72 of 76 result above is kept as history. Until the next build, the note that updates and ordinary restarts don't restore the scroll position is carried by the release text and this record only.

The paragraph in `docs/trial-notes*.md` since `b9457bb` is text for the next version. It is not the packaging source of build 20261114.1404, whose trial notes come from `816276a`; don't regenerate or replace 1404's attached notes from the current `docs/`. The paragraph goes into the app and the attached notes together in the next build.

## Launch colours and covers (builds 20261114.2343 and 20261115.0209, not release candidates) — 2026-11-15

Two commits: `fb7e005` keeps the launch colours until the page first finishes loading, and `6a3f817` keeps the cover (the launch screen or the "Can't connect" notice) until the page has loaded after a retry or a slow first load. This records development progress. It is not a release approval, and it does not show that the flicker is fully solved.

Nothing was released. There was no notarization, Release, tag, upload or appcast change. Build 20261114.1404 and its packages are unchanged and stay frozen, and the installed app was not replaced. Builds 20261114.2343 (`fb7e005`) and 20261115.0209 (`6a3f817`) are Developer ID signed with the hardened runtime and a secure timestamp, and they are not notarized. Their version string is still 0.1.0-beta.3, which has not been published.

**Launch colours (`fb7e005`, build 20261114.2343).** Before this change, on a cold launch of build 20261114.1404 with macOS in Dark mode and the signed-out ChatGPT home page, a dark launch screen turned light and then faded back to the dark page. The app's log showed WebKit reporting a light page colour before the ChatGPT page committed. That this light colour is the blank web view's, and that it caused the 1404 flicker, is an inference from the code and the log timing; it has not been proved.

| Check | Result |
| --- | --- |
| `swift test --filter LaunchColourTests` | Passed: 13 tests, no windows opened |
| `swift test --skip 'ChromeTests\|PageTests\|WindowExperienceTests'` | Passed: 227 XCTest and 40 Swift Testing tests, zero failures |
| ChromeTests, PageTests, WindowExperienceTests | Passed: 107 tests, zero failures |
| Mutation check | Each of the four parts of the change was removed in turn. Each time, tests failed (7, 3, 1 and 2), and the source was restored byte for byte |
| `scripts/build-app.sh release` (Developer ID) | Passed: build 20261114.2343 |

The real WebKit cold load in the test run did not report a light colour during the hold. That test therefore shows only that no light colour was shown. The temporary light colour itself is covered by tests that set the page colour directly.

Isolated-copy check, 2026-11-14:
- **Setup.** The copy had its own bundle ID and test data and was not signed in. The system appearance was Dark and was not changed. Each launch was recorded frame by frame, and the brightness of the launch screen, the page area and the top bar was measured (mean brightness from 0 to 1; "light" means above 0.6). Conditions matched the 1404 reproduction.
- **Before (1404).** With no saved page colour or a saved dark colour, 6 of 6 cold launches went from the dark launch screen to a light one and back to dark.
- **After (2343).** There were 9 cold launches, 3 each with no saved colour, a saved light colour and a saved dark colour. The first 3 ran before the screen locked. The other 6 ran after it was unlocked and idle again, under the same conditions.
  - With no saved colour or a saved dark colour (6 launches), no frame of the launch screen, the page area or the top bar was brighter than 0.6.
  - With a saved light colour, which is out of date in Dark mode, each launch switched from light to dark once, as before the change.
- **Log.** In all 9 launches, WebKit reported a light page colour 145 to 274 ms before the page committed. It was held and not saved. The dark colour was adopted 177 to 193 ms after the load finished, and the one-second fallback was not used. Afterwards the saved colour was the page's dark colour every time.
- **Black first frame.** The first recorded frame was entirely black in 4 of the 9 launches, in 3 of 8 launches of 1404, and in 3 of the 4 normal launches of build 20261115.0209 below. The cause is unknown and is not attributed. That it happened before and after the changes does not show it is unrelated to the app.
- **After loading.** With tool-driven input, the copy's own menu reloaded the page 3 times after the first load. Each reload committed and finished, and there were no light frames in the 1,853 frames recorded. New Chat was also chosen 3 times, but the page was already a new chat and no navigation happened. New Chat is therefore not verified.

**Blank white after a failed or slow first load (found 2026-11-15).** These paths were checked on test variants: build 20261114.2347 (the source of `fb7e005`) and build 20261115.0030 (the source of 1404, `816276a`), each with the same test-only patch, which is not in this repository. The patch sends the app's web traffic through a local proxy, so the connection could be cut and restored without turning off the Mac's network. Each run started from empty website data. These variants are not a real network disconnect on the official binary.
- **Path A: the first load fails, then an automatic retry succeeds (3 runs each).** On both variants the page area went blank white after the "Can't connect" notice hid at the commit. It stayed white until the page painted, 41 to 64 ms after the load finished: about 0.2 s on the 1404 source and 0.24 to 0.31 s with `fb7e005`. On the 1404 source, the notice and the top bar were already light during the failure, and white was saved as the page colour. With `fb7e005` they stayed dark, so the white showed as dark → white → dark.
- **Path B: the first load is slower than the 10-second launch-screen limit; the proxy held the connection for 12 s (3 runs each).** On the 1404 source the launch screen turned white about 0.4 s after the window appeared and stayed white for about 11 s in all, and white was saved. With `fb7e005` the launch screen stayed dark for the 10 seconds, then the page area was blank white for about 1.0 to 1.1 s.
- Only that 1404 also shows the blank white is established. That the cause is the same is not claimed.

**Covers (`6a3f817`, build 20261115.0209).**
- After a commit, the "Can't connect" notice stays, showing its last state, until the load finishes. It then fades out over 0.2 s, like the launch screen. If the load has not finished 1 s after the commit, the notice is hidden as before.
- At the 10-second limit, the launch screen ends as before only if the page has committed. Otherwise it stays until the load finishes or fails, until 1 s after a commit, or until 30 s after it appeared. Before this change, it always ended at 10 s.
- This is still a timing rule (the load has finished, then a 0.2 s fade), not a signal that the page has painted.

| Check | Result |
| --- | --- |
| `swift test --skip 'ChromeTests\|PageTests\|WindowExperienceTests'` | Passed: 242 XCTest and 40 Swift Testing tests, zero failures, including the 14 new PageRevealTests (no windows opened) |
| ChromeTests, PageTests, WindowExperienceTests | Passed: 107 tests, zero failures |
| Mutation check | Ten parts of the change were removed one at a time. Each time, 1 to 4 tests failed, and the source was restored byte for byte |
| `scripts/build-app.sh release` (Developer ID) | Passed: build 20261115.0209 |

Isolated-copy check, 2026-11-15. All input was tool-driven, and no physical key or mouse input was recorded during the runs. Each copy had its own bundle ID and test data, was not signed in, and ran with macOS in Dark mode.
- **Paths A and B, 3 runs each, alternating with `fb7e005`.** The proxy test variants were build 20261114.2347 (`fb7e005`) and build 20261115.0210 (`6a3f817` with the same test-only patch). Each run started from empty website data. **These runs are not an acceptance of the official binary with a real network disconnect.**
  - **A.** Before the change, all 3 runs showed blank white for about 0.2 to 0.35 s. After it, the blank white did not appear in any of the 3 runs: no frame of the page area was brighter than 0.6. The notice stayed until the load finished, 195 to 232 ms after the commit, and then faded to the dark page.
  - **B.** Before the change, all 3 runs showed blank white for about 0.9 to 1.3 s after the limit. After it, the blank white did not appear in any of the 3 runs: no frame of the page area was brighter than 0.6. The launch screen stayed past the limit and ended when the load finished, 11.4 to 11.7 s after the window appeared.
  - In 2 of these 6 runs, the first frame of the fade was a little lighter than the cover across the whole page area for one frame (20 and 24 against 14, on a 0–255 scale).
- **Normal launch on build 20261115.0209.** There were 4 cold launches (no saved colour, dark, dark, no saved colour). Then another launch with a saved dark colour was followed by 3 reloads from the copy's menu. Website data was empty only for the first launch, as in the 2343 series. Every launch screen ended when the load finished, 594 to 692 ms after it started.
  - In 3 of the 4 launches, the brightest frame of the page area during the fade was 0.10 to 0.15. That is the same range as the 2343 series (0.07 to 0.18).
  - **In one launch with no saved colour, the fading launch screen turned light grey for about 60 ms (peak 0.66, a pixel value of 169 of 255) before the dark page appeared.** The dark page appeared about 100 ms after the load finished; in the other three launches it had appeared by about 40 to 60 ms (frames are about 20 ms apart). Neither the cause nor whether this is a regression has been determined.
  - Apart from moving into helper functions, the fade code of the normal launch did not change. That is a lead for the investigation, not grounds for ruling out a regression. A limited comparison of builds 20261114.2343 and 20261115.0209 is planned.
  - All 3 reloads committed and finished. No frame of the page area was brighter than 0.081, and no two adjacent frames differed by more than 0.05.
- **Fallbacks not reached.** In these runs, neither the 1-second fallback after a commit (for the notice or the launch screen) nor the 30-second cap was reached. They are covered by unit tests only.

Known limits:
- These changes do not show that the flicker is fully solved. Both are timing rules. When the page paints late, the fade can still show a lighter colour, as in the launch above.
- If the page commits but has not finished loading after one second, the cover goes away. Blank white can then show until the page paints.
- If the real page colour is reported more than one second after the load finishes, the one-second colour fallback adopts whatever colour is current then, which may still be a temporary one.
- If the real colour is reported before the load finishes, it is adopted only after the one-second fallback. In one launch after loading, this happened. With an out-of-date saved colour, the top bar then changes about one second later than before `fb7e005`. It is a single switch, not a flicker.
- If the page never finishes loading, the launch colours stay until a later load finishes.
- In path A, the notice keeps showing that it is reconnecting for about 0.2 s after the page has connected. In path B, a slow first load now keeps the launch screen beyond 10 seconds, up to 30 seconds.

Not verified:
- Light system appearance
- A ChatGPT theme that differs from the system
- Signed-in chats
- Hiding and showing the window
- New Chat
- A real network disconnect on the official builds 20261114.2343 and 20261115.0209
- The 1-second fallback after a commit and the 30-second cap in a real run
- Physical key presses
