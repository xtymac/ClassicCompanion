# Contributing

Use this source repository for code issues and pull requests. Use [the distribution repository](https://github.com/mactokyo/ClassicCompanion/issues) for installation and end-user feedback. Do not post account credentials or conversation content.

For a code change, describe the problem, keep the diff focused, add meaningful regression coverage and run `swift test` plus `CC_SIGNING_MODE=adhoc scripts/build-app.sh debug` on macOS. Report OS/toolchain versions and any untested behavior. Tests briefly open windows; run them in a logged-in desktop session and avoid typing while they run.

Keep the four language tables and relevant README files consistent. Never include credentials, signing keys, build outputs, personal screenshots or private development records. Changes to the website adapter must retain navigation and message-origin checks.

Contributions are submitted under Apache-2.0 (see LICENSE, section 5). Include third-party attribution and license information when adding third-party code. Package.swift currently declares no external package dependencies.
