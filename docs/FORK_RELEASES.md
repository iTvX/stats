# Releases for iTvX/stats

The default branch `master` publishes through `.github/workflows/release.yaml`. Each successful build is signed with Developer ID, notarized by Apple, stapled, verified by Gatekeeper, and uploaded as `Stats.dmg` and `Stats.zip` with `SHA256SUMS` and the project license. The DMG includes an Applications shortcut. Both Apple silicon and Intel slices are required.

Versions start at the main app target's `MARKETING_VERSION`. If the version already exists as a tag on this fork, the workflow increments the highest patch version. This lets every source update publish a version newer than the previous release without editing the project on every commit. Build numbers use a UTC timestamp. Tags are created only after verification passes.

Run a full validation without publishing:

```sh
gh workflow run release.yaml --repo iTvX/stats --ref master -f validate_only=true
```

Run a release manually:

```sh
gh workflow run release.yaml --repo iTvX/stats --ref master -f validate_only=false
```

The dedicated runner uses label `stats-local`. Its service starts in the logged-in user's macOS session. Its private `.env` supplies `SIGN_IDENTITY`, `SIGN_TEAM_ID`, `KEYCHAIN_DB`, `KEYCHAIN_PASSWORD_FILE`, `NOTARY_PROFILE`, and `NOTARY_KEYCHAIN`. These point to the existing Mac Switch signing setup on this Mac. Keep that Keychain and password file available; changing them requires updating both runners' private environment. The password file is read only to unlock the Keychain, and never printed. The runner's job-start hook admits only iTvX's own pushes, manual runs, and same-repository pull requests.

Build logs and notarization receipts remain under ignored `build/`. The workflow does not install or launch the app, reset privacy permissions, change preferences, or modify the live menu bar. Initial installation is manual because upstream builds trust a different signing identity.

Local CI also runs `python3 Kit/scripts/run-performance-tests.py --products build/CI/Build/Products/Release` after building. The core suites cover reader scheduling, chart history and gap handling, selective GPU property reads, and snapshot persistence. They compile the production implementations with isolated fixtures at the storage and remote-delivery boundaries. GPU tests include a read-only IORegistry smoke check when an accelerator is available. The chart tests check history continuity across cadence changes, sleep gaps, resizing and replacement; storage tests count encoding calls and verify retries, concurrent saves, forced saves and history flushes.

With `--products`, the script also tests Mini, Stack and shared-history line charts from the actual built Kit framework. It compiles the production Sensors popup and value types against that framework, replacing only the privileged fan-helper boundary with a test stand-in. These tests check lazy chart allocation, preserved history, row reuse, removal, owner release and fan-control reconstruction when metadata changes. AppKit suites run in temporary, windowless bundles with separate test preference domains that are cleared before and after each suite. They never launch Stats or read its preferences or database. Running without `--products` runs the core suites, including concurrent chart-data access; the release workflow runs those checks before archiving.

The command tests compile a temporary child-process fixture to exercise simultaneous stdout/stderr draining, timeouts, cancellation, output limits, descriptor cleanup, descendant pipes and reader pause/resume. The energy tests use deterministic counters and clocks to verify the 100 ms shared snapshot window, independent consumer baselines, unit conversion, failures, counter resets and wake invalidation. With `--products`, read-only integration checks also run the actual `top -F`/`ps` commands and the shared IOReport backend. The `-F` option omits unused framework totals; Apple's [top source](https://github.com/apple-oss-distributions/top/blob/main/libtop.c) collects per-process physical footprint separately from its framework scan.

Stats queries the GitHub Releases API for iTvX/stats and downloads the signed `Stats.dmg`. Its installer rejects a replacement app signed by a different team. The app, widget, SMC helper, and SMC tool use this fork's signing team. App and widget share the same version/build and application group. Upstream service and donation links are retained where they are unrelated to app distribution.
