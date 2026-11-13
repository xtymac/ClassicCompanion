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
| PageTests, ChromeTests, WindowExperienceTests | Not rerun in this tree (they open windows). The ported adapter and PageTests files are byte-identical to the private versions that passed |
| `CC_SIGNING_MODE=adhoc scripts/build-app.sh debug` | Passed (build 20261113.1716): Sparkle 2.10.1 embedded, `codesign --verify --deep --strict` passed, SUFeedURL and feedback links point to this repository, Sparkle license notice present |
| Shell script syntax | All `.sh` scripts passed `zsh -n` |
| Publication hygiene | Added lines scanned for home paths, signing identifiers, personal contacts, key and token patterns; only the release EdDSA public key and an all-zero test key appear |

No signed or notarized build of this tree exists yet, and no update has been delivered through the real feed.
