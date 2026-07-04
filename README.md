# Azure Pipelines Monitor

A native macOS menu bar app that shows the latest run status of every pipeline
in one or more Azure DevOps projects.

The menu bar shows the same emoji used inside the dropdown:

- ✅ — all pipelines' latest runs succeeded
- ❌ with a count — that many pipelines are failing
- ✋ with a count — that many runs are paused waiting for an environment
  approval
- 🔄 — nothing failing, at least one run in progress or queued
- ⚠️ — configuration or authentication problem (details in the dropdown)

Clicking a pipeline in the dropdown opens that run in Azure DevOps.

## Running pipelines from the app

Every pipeline in the dropdown has a submenu with **Run Pipeline…** (queues a
new run after a confirmation dialog) and **Open Latest Run in Azure DevOps**.
The branch field is pre-filled with the last run's branch (cleared to empty =
pipeline's default branch; PR merge refs are not pre-filled). Requires the PAT to have the
**Build → Read & execute** scope. Success or failure is reported as a
notification.

## Approving from the app

A pipeline showing ✋ has a submenu with **Approve…** and **Reject…** — each
shows a confirmation dialog with an optional comment before submitting via
the Approvals REST API. Requirements:

- The PAT needs the **Build → Read & execute** scope (Read alone can only
  *detect* approvals). To upgrade: create a new PAT with that scope, then
  update the Keychain entry:

  ```sh
  security add-generic-password -U -s AzurePipelinesMonitor -a pat -w
  ```

- The PAT's owner must be one of the configured approvers for the
  environment; the approval is recorded in their name.

Covers YAML environment approvals (the `Checkpoint.Approval` timeline record
id is the approval id). Classic Release pipeline approvals use a different
API and are not supported.

## Notifications

The app posts desktop notifications on pipeline transitions (allow them when
macOS asks on first launch; clicking a notification opens the run):

- 🚀 build started
- ✅ / ❌ / ⚠️ / ⏹ build completed (succeeded, failed, partially succeeded,
  canceled)
- ✋ approval required — detected via the build timeline's
  `Checkpoint.Approval` records, so it covers YAML environment approvals with
  no extra PAT scope
- ▶️ build approved & resumed

Notifications fire only on *changes* observed between polls, so launching the
app never replays existing state. Disable categories in the config with
`"notifyOnStart": false`, `"notifyOnComplete": false`, or
`"notifyOnApproval": false`.

Use **Send Test Notification** in the menu to verify delivery end to end (it
also re-requests permission if it was never granted). Authorization results
and delivery failures are logged to `~/Library/Logs/AzurePipelinesMonitor.log`;
check System Settings → Notifications → Azure Pipelines Monitor if tests
don't appear.

## Setup

1. **Create a PAT**: in Azure DevOps go to User settings → Personal access
   tokens → New Token. Scope: **Build → Read** only. Copy the token.

2. **Store it in the Keychain** (you'll be prompted for the token so it never
   lands in shell history):

   ```sh
   security add-generic-password -s AzurePipelinesMonitor -a pat -w
   ```

3. **Edit the config** at `~/.config/AzurePipelinesMonitor/config.json`
   (or use "Open Config File" in the app's menu):

   ```json
   {
     "organization": "your-org-name",
     "projects": ["Project One", "Project Two"],
     "refreshSeconds": 60
   }
   ```

   `organization` is the part after `https://dev.azure.com/` in your URLs.

4. Choose **Refresh** (⌘R) from the app's menu — it re-reads the config, no
   relaunch needed. The first Keychain read pops a permission dialog; choose
   **Always Allow**.

Optional keys: `keychainService` / `keychainAccount` override the Keychain
lookup (defaults: `AzurePipelinesMonitor` / `pat`).

## Desktop widget

A companion WidgetKit widget (small/medium/large) lives in `Widget/` and is
installed as `/Applications/AzurePipelinesWidget.app`. To add it: right-click
the desktop → **Edit Widgets** → search "Azure Pipelines" (or add it from
Notification Center).

The widget doesn't talk to Azure DevOps itself. The menu bar app writes a
snapshot to `~/Library/Application Support/AzurePipelinesMonitor/status.json`
after every poll (and mirrors it into the widget's sandbox container), and the
widget renders that file, reloading on WidgetKit's schedule (~5 min). If the
menu bar app stops running, the widget shows an orange stale indicator once
the snapshot is older than 10 minutes. The host app window is just a
placeholder — close it; the widget keeps working.

Rebuild with `Widget/build.sh` (requires full Xcode; uses `DEVELOPER_DIR` so
no `xcode-select` switch is needed). It builds from a local temp copy because
codesign rejects OneDrive's extended attributes ("detritus" errors).

For macOS to discover the widget, three things proved mandatory (all matching
what Xcode's widget template does): the ExtensionKit layout
(`Contents/Extensions` + `EXAppExtensionAttributes`, not the legacy
`PlugIns`/`NSExtension` style), the App Sandbox entitlement on the extension,
and `CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO` so ad-hoc signing doesn't add a
debug `get-task-allow` entitlement. If the widget ever vanishes from the
gallery after a rebuild, relaunch the host app once and run
`killall chronod`; verify registration with
`pluginkit -m -A -i com.axial.azurepipelineswidget.widget`.

## Start at login

System Settings → General → Login Items → add
`/Applications/AzurePipelinesMonitor.app`.

## App icon

Both apps share an icon (blue squircle, white rocket, green check badge)
generated programmatically by `Icon/MakeIcon.swift`. To tweak it, edit the
drawing code and regenerate:

```sh
cd Icon && swift MakeIcon.swift . && iconutil -c icns AppIcon.iconset -o AppIcon.icns
cp AppIcon.icns ../Widget/HostApp/AppIcon.icns   # widget host keeps its own copy
```

then rebuild both apps. If Finder shows a stale icon afterwards, `touch` the
.app bundles or relaunch Finder.

## Rebuilding

```sh
./build.sh
```

Compiles `Sources/main.swift`, ad-hoc signs the bundle, and installs to
`/Applications`. After a rebuild the Keychain permission dialog will appear
once more (the ad-hoc signature changes).
