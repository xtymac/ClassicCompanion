# Local builds and distribution signing

For local development, use `CC_SIGNING_MODE=adhoc scripts/build-app.sh debug`. This requires no signing identity or notarization profile. Quit an installed copy before launching because the bundle identifier and WebKit data are shared.

For your own Developer ID release, configure `CC_TEAM_ID` and `CC_SIGNING_IDENTITY` in your shell. For notarization, configure `CC_NOTARY_PROFILE` to the name of your own Keychain profile. Store secrets in Keychain, never in the repository or shell scripts.

```sh
scripts/build-app.sh release
scripts/package-release.sh --notarize <build-number>
scripts/verify-release.sh --final ../ChatGPT-Classic-Companion-releases/trial-<version>-<build-number>
```

These commands require your own valid Apple credentials. Notarization submits the app and DMG to Apple; it does not publish to GitHub. Only the `upload/` outputs are distribution candidates; `local-only/` contains source snapshots, debug symbols and notarization logs. Signing and notarization do not replace functional acceptance testing. No signed distribution has been generated for this source publication.
