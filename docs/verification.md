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

Not yet done: installing from the DMG or ZIP on a clean setup, the icon on a light menu bar background, and delivery through the real HTTPS feed (possible only after publication). No Release, tag, attachment or appcast has been published for this build.

## Legacy feedback notice and beta.1 source note — 2026-11-13

Builds released before the move, including 0.1.0-beta.1, open the legacy repository's Issues page for feedback. That page showed no pointer to this repository, so a four-language notice was opened there, pinned and locked: <https://github.com/mactokyo/ClassicCompanion/issues/1>. Signed out, the legacy Issues page now shows it pinned at the top, and it links to this repository's Issues. The legacy repository has not been archived.

Its issue chooser now points to this repository: `.github/ISSUE_TEMPLATE/config.yml` there disables blank issues and adds a four-language contact link to this repository's Issues. Signed in as the repository owner, New issue opens a dialog with "Blank issue — Maintainers only" and that link; signed out, New issue leads to the GitHub sign-in page. The view of an account with read access only was not checked. This does not block every way of opening an issue there: people with write access can still open blank issues, and other routes such as the API may still work.

The [0.1.0-beta.1 Release notes](https://github.com/xtymac/ClassicCompanion/releases/tag/v0.1.0-beta.1) gained a four-language source note: the tag points to `086a39e`, a release-metadata commit (README only), not the complete source of build 20261110.0137. GitHub's generated source archives for that tag are not the exact source the installer was built from, and `main` holds later source. Only that paragraph changed. The tag, the seven assets and their checksums are unchanged; names, sizes and digests were compared before and after.
