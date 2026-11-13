# Public source repository

- This is `xtymac/ClassicCompanion`, the Apache-2.0 public source repository.
- Keep private development history, screenshots, credentials and unpublished design assets out of this repository.
- Preserve the separate private backup and legacy download repository; never push private history here. This repository now hosts both public source and Releases.
- Validate completed code changes with appropriate tests and an ad-hoc debug build, then commit and push completed work as requested by the maintainer. Do not include unrelated work.
- Keep four-language documentation and resource tables consistent. Maintain LICENSE, NOTICE and branding attribution.
- This checkout is the main development directory. Releases are built, notarized and their appcast prepared from here with the maintainer's own `CC_TEAM_ID`, `CC_SIGNING_IDENTITY` and `CC_NOTARY_PROFILE`; never commit those values, the Sparkle private key or release outputs.
- Internal acceptance records and the isolated upgrade-test tooling stay in the private backup and are not copied here. Port reviewed changes as focused commits.
- Do not move or overwrite existing tags or Releases, and publish `appcast.xml` only after the Release assets are live and verified (docs/updates.md, "Release order").
