# macOS compatibility investigation — 0.5.3

## Evidence and scope

- YTray `053bdbb` replaces the trapping AppKit window-number conversion with an exact, optional Quartz conversion. YConnect PR #12 (`f164c18`) independently records eight macOS 26.5.2 crash reports at that conversion, with the observed value `4294967296`. This release includes that existing fix and its boundary regression.
- YTray `79dee7a` / `3ef2d03` restore foreground/reopen behavior and suppress expected SwiftUI page-task cancellation. YConnect already retains its application delegate for the event loop and shows a widget for manual launches; those behaviors are preserved.
- YConnect still lost the manager surface after closing it, and menu commands did not explicitly restore a minimized manager. Existing manager instances now reopen, and all manager presentation paths deminiaturize them.
- Service-item launches and `--background` are treated as background starts, while explicit show flags take precedence.
- YConnect's model-catalog refresh is owned by SwiftUI `.task` on the widget and client pages. Its network layer previously erased cancellation identity by wrapping it as a generic transport error. Cancellation now propagates unchanged, the refresh suppresses it, and a post-await cancellation check prevents stale results replacing the catalog. Real network failures remain visible.

## Verification

Local checks use isolated fixture credentials and application directories. Unit tests cover Quartz bounds, login/service/background policy, URLSession and Swift task cancellation, cancellation during an in-flight request, late successful responses, and real network failures.

CI retains macOS 14 build/test/render/package checks, and adds macOS 26 arm64 and Intel builds/tests. Both Tahoe runners download the exact universal DMG produced by the primary job, verify its signature, exercise Launch Services and direct startup, require a visible presentation checkpoint and surviving process, and send a real Finder-style reopen to the same process. Window smokes require an actually closed/minimized manager before accepting restoration. On release runs this is the signed/notarized payload, and publication waits for these jobs.

`script/test-macos-startup.py` is for disposable CI accounts only: it exercises normal startup, login registration and real application data paths. It uses no customer credentials. Local desktop validation uses isolated smoke modes instead.
