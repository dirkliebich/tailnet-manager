# Contributing to Tailnet Manager

If something in your tailnet is hard to understand or manage, tell us what
you were trying to do and where the app got in your way. Small pull requests
are welcome. For a change that affects permissions or how edits are applied,
an issue describing the intended behavior gives everyone a place to discuss it.

## Build

The Xcode project is checked in. If you add, move, or remove source files,
update `project.yml` as needed and regenerate the project with XcodeGen.

```sh
xcodegen generate
```

Build both targets when changing shared code. XcodeGen is only needed for
project regeneration.

```sh
xcodebuild -project TailnetManager.xcodeproj -scheme TailnetManager \
  -destination 'platform=macOS' build

xcodebuild -project TailnetManager.xcodeproj -scheme TailnetManager \
  -destination 'generic/platform=iOS Simulator' build
```

## Find your way around

- `TailnetManager/Views/` contains the SwiftUI screens and shared components.
- `TailnetManager/Core/AppState.swift` and its extensions connect the screens to tailnet data and actions. `TailscaleAPI.swift` handles API calls and `KeychainStore.swift` stores the token.
- `PolicyAnalyzer.swift` reads HuJSON and resolves access. `PolicyEditor.swift` edits policy, and `ChangePlan.swift` assembles changes for review.
- `ServiceScanner.swift`, `ServiceInventory.swift`, and `ServiceSources.swift` handle macOS server scans and turn their output into inventory rows.

## Ideas for a first contribution

- Add a synthetic policy example for a grant or SSH rule the access map explains poorly.
- Improve VoiceOver labels or keyboard navigation in a table or review sheet.
- Add a sample inventory that lets developers try out the macOS views without connecting to live servers.

Include what changed, how you checked it, and which platform you used. For
policy or account changes, exercise the preview and apply flow in a test
tailnet. Use synthetic data in fixtures and reports. Keep credentials,
private policy files, hostnames, and user data out of issues and pull requests.
