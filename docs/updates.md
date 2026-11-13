# In-app updates (Sparkle 2)

Classic Companion uses [Sparkle](https://sparkle-project.org) 2 for in-app updates. Downloading, EdDSA signature verification, replacing the app and relaunching are all done by Sparkle; this project does not reimplement them.

- Sparkle **2.10.1** is pinned with `exact:` in `Package.swift`. SwiftPM downloads the official XCFramework using the checksum published in Sparkle's package; `generate_appcast` and `sign_update` come from the same download (`.build/artifacts/sparkle/Sparkle/bin/`). Upgrading Sparkle also means updating `CC_SPARKLE_VERSION` in `scripts/update-config.sh` and repeating the packaging checks and an isolated upgrade test.
- 0.1.0-beta.1 (build 20261110.0137) has **no** updater. The first version with in-app updates is 0.1.0-beta.2; beta.1 users install it once by hand (see "First migration").
- Status: not yet released. No appcast has been published at the feed address below.

## Code and scripts

| File | Purpose |
| --- | --- |
| `Sources/ClassicCompanion/Updates/UpdateConfiguration.swift` | Reads feed, public key and channel from Info.plist; if any is missing the updater is not started (`swift run`, unit tests) |
| `Sources/ClassicCompanion/Updates/UpdateController.swift` | `SPUUpdater` created in code, channel filtering, gentle reminders, cancelling a started install before a normal quit |
| `Sources/ClassicCompanion/Updates/ConfirmingUserDriver.swift` | Forwards everything to Sparkle's `SPUStandardUserDriver`, inserting only the consent step before download and handling "ready to install" according to that consent |
| `Sources/ClassicCompanion/Updates/UpdateReadyPrompt.swift` | The consent window before download (and the install confirmation in Sparkle's installing stage); follows the app language |
| `App/AppDelegate.swift`, `UI/SettingsPanes.swift` | Check for Updates… menu item, the "new version" status-menu item, Settings → General → Updates |
| `scripts/update-config.sh` | Feed URL, download base, public key, Keychain location, check interval and channel rule (public values only) |
| `scripts/sparkle-embed.sh` | Embeds Sparkle.framework, fixes rpaths, signs inside-out and checks the result |
| `scripts/sparkle-key.sh` | Generates the EdDSA key, prints its public key, self-tests, verifies or imports a backup; the private key stays in Keychain and is never displayed |
| `scripts/build-app.sh`, `scripts/verify-release.sh` | Write the update configuration and embed the framework; release checks include the "更新：" items |
| `scripts/prepare-appcast.sh` | Generates and checks the appcast for a notarized release directory (does not upload) |
| `docs/release-notes/` | Update notes embedded in the appcast (HTML, one section per language) |

The isolated upgrade-test tooling (a separate test copy with its own bundle identifier, a local feed server and a test key) is not part of this repository and never enters a release build.

## What users see

- **Check for Updates…** in the app menu, below About. It opens Sparkle's standard windows: checking → up to date / new version (version and notes) / error.
- **Settings → General → Updates**: "Check for updates automatically", with the note that downloading, installing and relaunching always ask first. The switch reads and writes Sparkle's `automaticallyChecksForUpdates` directly, so Sparkle's first-run question, the setting and Sparkle itself always agree. Builds without update configuration (`swift run`) show the switch disabled.
- **First question**: Sparkle's standard flow: not on the first launch, asked once on the second launch. `Info.plist` does not preset `SUEnableAutomaticChecks`.
- **Scheduled checks (daily, `SUScheduledCheckInterval` = 86400) never pop up or take focus.** Sparkle's gentle-reminder API is used: a "new version" marker next to Check for Updates…, an item at the top of the status-bar menu and a line in Settings. No Dock badge is used; the update code never touches `NSApp.dockTile`. Sparkle's update window opens only when the user clicks one of these.
- **No automatic download or install**: `SUAllowsAutomaticUpdates = NO`.
- **Consent before download; after consent the app installs and relaunches on its own.** After the user chooses Install Update in Sparkle's window, Classic Companion shows its own consent window (in the app language). At this point nothing has been downloaded and no installer is running.
  - **Download and Install** (Return): Sparkle downloads, verifies the EdDSA signature before extraction (`SUVerifyUpdateBeforeExtraction`), installs and relaunches without asking again. The button is disabled for 1 second after the window appears so a held or repeated Return from Sparkle's window does not confirm it.
  - **Later** (Esc, ⌘., or closing the window): replies "dismiss" to Sparkle. Nothing is downloaded or installed.
  - Quitting, crashing or being force-quit while the consent window is open installs nothing.
  - Quitting during the download interrupts it and nothing is installed. A normal quit (⌘Q, log out, shut down) after the download, while Sparkle is verifying and extracting, cancels that install first (waiting up to 10 seconds for Sparkle to end the session).
  - The window explains that the app will relaunch without asking again, and asks the user to let a reply finish, stop Read Aloud and finish or copy what they are typing before confirming. The app never decides on its own that it is safe to restart.
- **Why consent comes before download**: Sparkle 2 starts its installer (`Autoupdate`) as soon as the download finishes and extraction begins. From then on, if the app ends on its own — including a crash or force quit, which the app cannot intercept — Sparkle installs the update (`SPUUserDriver.h`, `showReadyToInstallAndRelaunch:`). Sparkle has no official "download without starting the installer" API, so consent is asked before download. Sparkle itself is not modified.
  - Ready to install: with consent the driver replies Install; without consent (which should not happen) it replies Skip, which cancels only this install. Sparkle's own "ready to install" window is not shown.
  - Sparkle's installing stage (the installer is waiting, for example because the app could not quit): an "Install and Relaunch" confirmation is shown; "Later" replies Skip.
- **Errors** (no update, network failure, download failure, bad signature) use Sparkle's standard messages; the current version keeps running. Diagnostics log only the error domain and code, never URLs, paths or error text.

## Languages

- The app's own text (menu items, the Updates group, the "new version" marker, status-menu items, the consent window, accessibility labels) is in the four `Localizable.strings` files and follows the **language chosen in the app**.
- **Sparkle's own windows** use Sparkle's bundled translations and follow the **macOS language** (system language or the per-app language in System Settings), not the language chosen in the app. Sparkle chooses its translation from the process's `AppleLanguages`; changing that would also change the ChatGPT page language, so it is not done. The trial notes state this.
- **Update notes** are one HTML fragment in the appcast with a section per language (`lang="en" / "zh-Hans" / "zh-Hant" / "ja"`), so every user sees their language regardless of the macOS language.

## Configuration (Info.plist, written by build-app.sh)

| Key | Release value | Notes |
| --- | --- | --- |
| `SUFeedURL` | `https://raw.githubusercontent.com/xtymac/ClassicCompanion/main/appcast.xml` | `CC_UPDATE_FEED_CONFIRMED=1` in `update-config.sh`. Not yet published |
| `SUPublicEDKey` | `tyx3/N3E3Ziih0psrKFGJDcEKFS0v1dlwF2RiyWPjCM=` | Release EdDSA public key. The app contains only the public key |
| `CCUpdateChannel` | `beta` (version has a `-` suffix) / `stable` | App-specific key, see "Channels" |
| `SUScheduledCheckInterval` | 86400 | Daily |
| `SUAllowsAutomaticUpdates` | NO | No automatic download and install |
| `SUVerifyUpdateBeforeExtraction` | YES | Verify the archive signature before extracting |
| `SURequireSignedFeed` | YES | The appcast and notes must also be EdDSA-signed |

- Release builds require an HTTPS feed and have **no** App Transport Security exceptions. `build-app.sh` rejects non-HTTPS and local addresses; `verify-release.sh` also checks for test addresses, test names and ATS exceptions. The code contains no feed URL, key or test switch, and clears any leftover `SUFeedURL` user default at launch.
- **Version comparison**: Sparkle compares `sparkle:version` = `CFBundleVersion`, the build number `YYYYMMDD.HHMM`, segment by segment. The UI shows `CFBundleShortVersionString`.
- **Minimum system and architecture**: `generate_appcast` reads `LSMinimumSystemVersion` (15.0) and the executable architecture from the archive and writes `sparkle:minimumSystemVersion` and `sparkle:hardwareRequirements` = `arm64`; `prepare-appcast.sh` checks both.

### Channels

- There is one appcast. Beta entries carry `<sparkle:channel>beta</sparkle:channel>`; stable entries carry no channel.
- The app answers Sparkle's `allowedChannels` by its own channel: beta builds allow `beta` (and still receive the default channel); stable builds allow no extra channel, so **future stable users never receive betas**.
- The channel is decided at build time from the version string (a pre-release suffix such as `-beta.2` or `-rc.1` means beta). `build-app.sh`, `prepare-appcast.sh` and the app (`UpdateConfiguration.Channel.forVersion`) use the same rule; `UpdateTests` checks they agree. GitHub's Pre-release flag is not used for filtering.
- At run time the app treats itself as beta only when `CCUpdateChannel = beta` **and** `CFBundleShortVersionString` is itself a pre-release; any mismatch is treated as stable and logged.

## Packaging and signing

`build-app.sh` (via `scripts/sparkle-embed.sh`):

1. Keeps only `/usr/lib/swift` and `@executable_path/../Frameworks` as rpaths.
2. Copies `Sparkle.framework` from the official XCFramework into `Contents/Frameworks/` with `ditto`, removes `XPCServices` (the app is not sandboxed, so Sparkle does not need them) and thins `Sparkle`, `Autoupdate` and `Updater.app` to arm64.
3. Signs inside-out as Sparkle documents, without `--deep`: `Autoupdate` → `Updater.app` → `Sparkle.framework` → app. Developer ID builds use the hardened runtime and secure timestamps. No existing security setting is disabled.
4. Checks structure, architecture, linkage, rpaths and every signature layer, then runs `codesign --verify --deep --strict`.
5. Copies Sparkle's MIT license notice unchanged to `Contents/Resources/Licenses/Sparkle-LICENSE.txt`; `verify-release.sh` checks it is present.

`package-release.sh` is unchanged; its ZIP is the Sparkle update archive. `verify-release.sh --final` additionally requires `CC_UPDATE_FEED_CONFIRMED=1` and a private key in Keychain that matches the app's public key.

Three signatures are verified separately and cannot replace each other:

| | Proves | Verified by |
| --- | --- | --- |
| Developer ID code signature | App and framework come from the signing team and are unmodified | `codesign`, `verify-release.sh` |
| Apple notarization | Apple scanned it; Gatekeeper allows the first manual install | `package-release.sh --notarize`, `stapler validate`, `spctl` |
| Sparkle EdDSA | The archive, appcast and notes come from the private-key holder | `generate_appcast` / `sign_update`; the app verifies with `SUPublicEDKey`; `prepare-appcast.sh` re-checks |

## Key custody

- The Ed25519 private keys (base64 of the 32-byte seed, the same format as Sparkle's `generate_keys -x`) exist only as generic-password items in the maintainer's **login Keychain**:
  - service `ClassicCompanion Sparkle EdDSA`, account `production`: release updates. Its public key is in `scripts/update-config.sh` and Info.plist.
  - same service, account `update-test`: isolated upgrade tests only. Its public key is written only into test copies and it must never sign a public appcast (`prepare-appcast.sh` reads only `production`).
- `scripts/sparkle-key.sh generate` creates the key in memory with openssl and passes it to `security` on standard input; the key is never written to a file, command-line argument, environment variable, log or repository.
- Use: `prepare-appcast.sh` pipes `security find-generic-password … -w` into `generate_appcast --ed-key-file -`. `scripts/sparkle-key.sh selftest production` signs a temporary file with Sparkle's `sign_update` and verifies it independently with openssl and the public key.

### Backup and recovery

Keychain is the only copy until the maintainer makes an independent backup: erasing the Mac, recreating the login Keychain or moving to a new Mac loses it.

1. In Keychain Access, open `ClassicCompanion Sparkle EdDSA (production)` (not `update-test`) and show the password: a 44-character base64 string.
2. Store it in a password manager entry, noting the service, account and public key. An offline encrypted copy is optional. Never put it in Git, chat, email, notes, screenshots, unencrypted files or plain cloud storage; clear clipboard history if the clipboard was used.
3. Run `scripts/sparkle-key.sh verify-backup production` in a terminal and paste the backup into the hidden prompt. Only the output "一致" (match) confirms the backup. The script compares derived public keys only, never shows or stores the private key, and refuses piped input.
4. To restore: `scripts/sparkle-key.sh import production`. It imports only if the backup's public key equals the app's `SUPublicEDKey` and refuses to overwrite an existing item. Then run `selftest production`.

### If the private key is lost or leaked

According to Sparkle's documentation ("Rotating signing keys" and "Signing feeds"), a Developer ID-signed app can rotate either its Apple signing certificate or its EdDSA key in one update, not both; with `SUVerifyUpdateBeforeExtraction` the rotating update must be a Developer ID-signed DMG. With a signed feed, after `SUSignedFeedFailureExpirationInterval` (default 20 days) of failed feed validation Sparkle will offer updates again without release notes. This project keeps that default but has **not** rehearsed key rotation: `prepare-appcast.sh` currently produces ZIP appcasts only. During those 20 days installed copies receive no updates, and users who never check will need a manual download. Back up the key so this path is not needed.

If the key leaks, assume an attacker who can also replace the feed or downloads could ship an update the app accepts: rotate immediately with a Developer ID-signed DMG update, stop using the old key and review access to the appcast and Release hosting.

## Release order

1. Set `VERSION` in `build-app.sh` (betas use a suffix such as `0.1.0-beta.N`), then `scripts/build-app.sh release`.
2. `scripts/package-release.sh --notarize <build-number>`: signing, notarization, stapling, DMG and ZIP, checksums.
3. `scripts/verify-release.sh --final <release-dir>`: Developer ID, notarization, Gatekeeper, icon, notes, update configuration, confirmed feed, private key present.
4. Real-use regression checks, including first launch after download and upgrading from the previous version in an isolated copy.
5. Write `docs/release-notes/<version>.html` (four languages), then `scripts/prepare-appcast.sh <release-dir> docs/release-notes/<version>.html` → `<release-dir>/appcast/appcast.xml`. Start from the published appcast (its signature is verified first) and add only this version; existing entries and signatures are kept. Nothing is uploaded.
6. Publish the GitHub Release `v<version>` in `xtymac/ClassicCompanion` with the files from `upload/` unchanged. Betas may be marked Pre-release, but channels do not depend on it.
7. Confirm the download URL works and matches: download the ZIP and compare `shasum -a 256` with `upload/SHA256SUMS`.
8. **Last**, commit `appcast.xml` unchanged to the feed path on `main` (never hand-edit it; regenerate instead), then download the live appcast and compare it with the local file.

Draft releases, unnotarized packages and anything from test copies or test feeds must never enter the public appcast. `prepare-appcast.sh` in release mode requires `verify-release.sh --final` to pass; `--dry-run` leaves no appcast signed with the release key.

## First migration (0.1.0-beta.1 → 0.1.0-beta.2)

0.1.0-beta.1 has no updater and will not learn about new versions. Its users install 0.1.0-beta.2 once from the DMG, replacing the app in Applications; sign-in and settings are kept because the bundle identifier is unchanged. Later versions can then be installed from within the app.

## Known limitations

- Upgrading through the real HTTPS feed and GitHub downloads can only be tested after publication; until then upgrades have been tested only with isolated copies and a local feed.
- Sparkle's windows follow the macOS language, not the app language.
- Key rotation has not been rehearsed (see above).
- `raw.githubusercontent.com` is unreachable in some regions and is cached for several minutes; a feed address compiled into released builds is hard to change later, so any future move must first ship a build that points to the new address while the old one stays available.
