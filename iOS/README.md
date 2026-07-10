# Azure Pipelines Monitor — iOS

A native SwiftUI iPhone app that shows the latest run status of every pipeline
in one or more Azure DevOps projects, and lets you queue runs and act on
environment approvals. It's the iOS companion to the macOS menu-bar app in the
parent folder and reuses the same Azure DevOps REST logic.

- ✅ succeeded · ❌ failed · ✋ waiting for approval · 🔄 running/queued
- Tap a pipeline to open its run in Azure DevOps
- Swipe or long-press a row for **Run Pipeline…**, **Approve…**, **Reject…**
- Background local notifications on run transitions (started / completed /
  approval required / resumed)

## Requirements

- Xcode (full, not just Command Line Tools) — the build uses the SDK under
  `/Applications/Xcode.app`.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) to
  generate the `.xcodeproj` from `project.yml`.

## Build & run

```sh
cd iOS
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodegen generate
open AzurePipelinesMonitor.xcodeproj
```

In Xcode:

1. Select the **AzurePipelinesMonitor** target → **Signing & Capabilities** →
   pick your personal team (your Apple ID under *Automatically manage signing*).
2. Choose your iPhone (or a Simulator) as the run destination and press **Run**.
3. On the device, trust the developer profile:
   **Settings → General → VPN & Device Management** → your Apple ID → Trust.
4. Allow notifications when prompted on first launch.

> A **free personal team** re-signs with a 7-day provisioning profile, so
> re-run from Xcode about once a week to keep it installed. Free teams can't use
> APNs push — v1 uses local notifications only.

Headless simulator build (compile check):

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project AzurePipelinesMonitor.xcodeproj -scheme AzurePipelinesMonitor \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```

## First-time setup (in the app)

Open **Settings** (gear icon) and enter:

- **Organization** — the part after `https://dev.azure.com/` in your URLs.
- **Projects** — add one or more project names.
- **Personal Access Token** — create it in Azure DevOps
  (User settings → Personal access tokens → New Token). Scope **Build → Read**
  to monitor; **Build → Read & execute** to also run pipelines and approve.
  It's stored in the iOS Keychain, never in plain files.

Pull to refresh, or tap the refresh button. **Send Test Notification** in
Settings verifies notification delivery.

## Notifications & background refresh

The app registers a `BGAppRefreshTask`
(`com.axial.azurepipelinesmonitor.refresh`). When iOS runs it, the app polls
Azure DevOps, diffs against the last known state, and posts local notifications
for any transitions. **iOS controls the timing** — it throttles background
refresh and won't match a fixed interval, so notifications are best-effort.
Timely, guaranteed delivery would require an APNs backend (out of scope for v1).

To exercise the background task in a debug run, background the app and run this
in the Xcode console (paused at a breakpoint):

```
e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"com.axial.azurepipelinesmonitor.refresh"]
```

## Apple Watch app

A companion watchOS app (`AzurePipelinesMonitorWatch/`) shows the same pipeline
list and lets you **approve/reject** environment checks from your wrist. It's
embedded in the iOS app and shares the Core networking/models/Keychain code.

**Credentials sync automatically.** The Watch never asks for a PAT — the iPhone
pushes organization, projects, and the token to the Watch over WatchConnectivity
(`PhoneConnectivity` → `WatchConnectivityReceiver`, `updateApplicationContext`),
and the Watch stores the token in its own Keychain. Configure once on the phone
(and re-open the phone app after changing settings to push updates); the Watch
fetches Azure DevOps itself, so it works on Wi-Fi/cellular without the phone
nearby. Until the first sync arrives the Watch shows "Open Azure Pipelines on
your iPhone to sync."

Build/run: the watch app builds with the **AzurePipelinesMonitorWatch** scheme;
in Xcode pick your paired Apple Watch (or a Watch simulator) as the destination.
Installing the iOS app to your iPhone also installs the Watch app if the phone is
paired. Approvals from the Watch need the PAT's **Build → Read & execute** scope,
same as the phone.

## Troubleshooting

**Saving the token fails / "Keychain unavailable" (OSStatus -34018).** The app
must be **code-signed with a keychain entitlement**, which only happens when you
build through Xcode with a signing team selected. A raw `xcodebuild
CODE_SIGNING_ALLOWED=NO` install (or any unsigned build) has no entitlements, so
every Keychain call returns `errSecMissingEntitlement (-34018)`. Fix: open the
project in Xcode, pick your team under **Signing & Capabilities**, and Run — the
Keychain then works in both the Simulator and on device. The app already ships a
`keychain-access-groups` entitlement (`AzurePipelinesMonitor.entitlements`) for
its own bundle id, which is always permitted (even on a free personal team) and
needs no App Store Connect setup.

## App icon

Reuses the shared artwork from `../Icon` (blue squircle, white rocket, green
check badge). The 1024² master is copied into
`AzurePipelinesMonitor/Assets.xcassets/AppIcon.appiconset`. To refresh it after
editing `../Icon/MakeIcon.swift`, regenerate the iconset and copy
`icon_512x512@2x.png` over `AppIcon-1024.png`.

## Layout

```
iOS/
  project.yml                     # XcodeGen spec
  AzurePipelinesMonitor/
    App.swift                     # @main; registers BG task + notifications
    Core/                         # (★ = also compiled into the Watch app)
      Models.swift                # ★ Azure DevOps + display models, date helpers
      PipelineStateUI.swift       # ★ per-state SwiftUI color
      Keychain.swift              # ★ PAT storage (Keychain)
      AppConfig.swift             # ★ org/projects/toggles in UserDefaults
      AzureDevOpsClient.swift     # ★ async REST: fetch / run / approve / reject
      ConnectivityKeys.swift      # ★ WatchConnectivity payload keys
      PhoneConnectivity.swift     # iPhone→Watch sync sender
      NotificationService.swift   # transition diffing + local notifications
      BackgroundRefresh.swift     # BGAppRefreshTask register/schedule/handle
    ViewModels/
      PipelinesViewModel.swift
    Views/
      PipelineListView.swift      # grouped list, summary bar, pull-to-refresh
      PipelineRowView.swift
      PipelineDetailView.swift
      SummaryBar.swift
      PipelineActionSheet.swift   # shared Run/Approve/Reject sheet
      RunPipelineSheet.swift
      ApprovalDecisionSheet.swift
      SettingsView.swift
    Assets.xcassets/
  AzurePipelinesMonitorWatch/     # watchOS app (shares the ★ Core files)
    WatchApp.swift
    WatchConnectivityReceiver.swift  # receives + stores synced credentials
    WatchPipelinesViewModel.swift
    Views/
      WatchPipelineListView.swift    # summary + grouped list
      WatchPipelineDetailView.swift
      WatchApprovalView.swift        # approve/reject with optional comment
    Assets.xcassets/
```
