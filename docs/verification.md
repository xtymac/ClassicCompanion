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
| `scripts/verify-release.sh --final` | 76 of 76 checks passed at packaging, including Gatekeeper, the HTTPS feed address, the release public key, the beta channel and the bundled Sparkle license notice; 72 of 76 after the trial-notes addition described below |
| `scripts/prepare-appcast.sh --dry-run` | 13 of 13 checks passed against the live beta.2 appcast; no appcast was kept or published |
| Gatekeeper with a simulated download | A copy of the final DMG marked as downloaded by a browser was accepted (Notarized Developer ID), its ticket was valid, the app inside was accepted, and `syspolicy_check distribution` passed |

In-app update from 0.1.0-beta.2, isolated test (2026-11-14). The test copy was made from the published beta.2 app, with its own bundle ID, its own test data, a local test feed and a test update-signing key. The update it installed was the beta.3 candidate app, given the same changes. Sparkle checked the feed and update signatures as usual. Nothing was downloaded until the consent dialog was confirmed. After confirming, the update was downloaded, its signature checked, and the app installed and restarted as 0.1.0-beta.3 (20261114.1404); its code and resources match the candidate DMG byte for byte once signatures are removed. Sign-in, the restored chat, an unsent draft, all existing settings and the shortcut were kept, and the new option showed Keep Last Mode. After the update a Full window hidden with the shortcut came back as Full; Always Quick Window was saved and survived a quit and reopen; checking again reported the copy up to date. Sign-in, the draft, the update check and both confirmations were done by the user; the other steps were tool-driven. The reading position was not kept across the update restart: the app restores the chat address, not the scroll position, and a plain quit and reopen afterwards landed at the same position, so this applies to any restart, not only to updates. A local test feed is not the real HTTPS feed, so updating existing beta.2 installations through the live feed is still unverified.

Install from the final DMG (2026-11-14, on the test Mac, replacing its 0.1.0-beta.2 installation, which was kept for rollback). The app was copied from the final DMG to Applications in the Finder and opened. It was 0.1.0-beta.3 (20261114.1404) with the same code signature hash as the app in the DMG, passed `codesign --deep --strict` and Gatekeeper (Notarized Developer ID), and ran from Applications as a single instance; opening the copy inside the DMG as well handed over to the running app and quit. It reopened the previous chat without going to a sign-in page, and the shortcuts, page zoom, app language, restored chat and automatic update check setting were unchanged. With tool-driven input, the show/hide shortcut brought the Quick window back as Quick and the Full window back as Full without reloading the page, and Settings showed Keep Last Mode. Check for Updates against the live feed, which still offers 0.1.0-beta.2, reported the app up to date with a valid feed signature; this shows that the build reads the live HTTPS feed, not that updating from beta.2 through it works. The previous app was observed not running when the replacement started; this records only what was seen at that moment, not whether anything had been in progress or left unsaved before. For sign-in after the replacement there is only indirect evidence (same data, restored chat, no sign-in redirect); sign-in and any draft left in the previous app are waiting for a manual check by the user. The macOS confirmation shown on first opening a downloaded copy did not appear, because the local DMG carries no download mark.

Not verified: updating existing installations through the live HTTPS feed (possible only after publication), the first-opening confirmation, installing from the ZIP, a clean setup, macOS 15 and macOS 26, and physical key presses on this build.

Trial notes after the checks (2026-11-14): one paragraph was added to each of the four trial notes (`docs/trial-notes*.md` and the `TrialNotes.*.md` files kept next to the candidate DMG): after an update, or a quit and reopen, the app goes back to the last chat but not to the scroll position; hiding and showing the window keeps the reading position; in the isolated update, sign-in, an unsent draft and settings were kept. The app was not rebuilt or re-signed, so the trial notes shown inside build 20261114.1404 do not have this paragraph. The attached files differ from the copies inside the app by that one paragraph in each language, so `scripts/verify-release.sh --final` now fails exactly those four comparisons (72 of 76 pass; everything else is unchanged). `SHA256SUMS` was regenerated; the DMG and ZIP checksums did not change.
