# 05 — App Integration (Export / Wrappers)

This is the mechanism behind "only apps I choose show up in Finder." Nothing from a guest is visible to macOS until the user explicitly exports it.

## Export picker

Omnia.app's "Apps" tab calls `omnia-agent` (via `vmd`) to enumerate installed guest apps:
- **Windows:** Start Menu shortcuts (`.lnk` targets) plus Programs-and-Features entries, deduplicated; icon extracted from the target `.exe`.
- **Linux:** installed Flatpak apps' `.desktop` entries; icon from the Flatpak's exported icon theme data.

Each entry shows: name, icon, guest OS, source (installed manually vs. via marketplace [09](09-marketplace.md)), and an Export toggle. Toggling on triggers wrapper generation (below). Toggling off deletes the wrapper bundle — the guest app itself is untouched, only its macOS presence is removed.

## Wrapper bundle

An exported app becomes a real `.app` bundle at `~/Applications/Omnia/<AppName>.app`:

```
<AppName>.app/
  Contents/
    Info.plist        — CFBundleIdentifier: com.omnia.app.<slug>, CFBundleIconFile, LSApplicationCategoryType
    MacOS/
      <AppName>        — universal small Swift binary, statically links OmniaRAILKit
    Resources/
      AppIcon.icns     — converted from the extracted guest icon (via `sips`/Core Graphics at generation time)
    Info/
      omnia-app.json   — {guestId, guestOS, remoteApplicationProgram, exportedAt, sourceMarketplaceId?}
```

- The `MacOS/<AppName>` binary is a **stub** built once (as part of the Omnia.app distribution, in `Resources/AppWrapperTemplate`) and copied per export — it is not recompiled per app. At launch it reads `omnia-app.json` next to it to know which guest and which `RemoteApplicationProgram`/app-id to request, then follows the flow in [04-presentation-rail.md](04-presentation-rail.md) steps 1–2.
- Because it's a signed, real `.app` with a proper bundle identifier, Spotlight indexes it, Launchpad shows it, Dock/Cmd+Tab treat it like any other app, and `LSApplicationCategoryType` lets it sort correctly in Launchpad categories. Deleting the bundle (Trash, or the Export toggle) fully removes it from all of those surfaces — no separate "uninstall" step, since the wrapper is not the actual app, just a launcher pointing at the guest.
- Wrapper generation and icon conversion happen in Omnia.app (not `vmd`), since it's a one-shot UI-triggered action, not something that needs to survive the app quitting.

## Naming / collision handling

- Slug derived from the app name (lowercased, non-alphanumeric stripped) is used for `CFBundleIdentifier` uniqueness; if a collision occurs (rare — e.g. two different guest apps named "Notes"), append the guest OS (`com.omnia.app.notes-windows`).
- If the user renames the `.app` in Finder, that's cosmetic only (Finder display name) — `omnia-app.json`'s `guestId` is the source of truth, not the filename.

## Instant-mode apps (M7)

For an app running via Wine/Rosetta instead of a VM ([03](03-windows-runtime.md)), the wrapper's `omnia-app.json` has `mode: "instant"` and the stub binary launches the app directly inside its Wine prefix instead of opening a RAIL session — same bundle format, different launch path, so the export picker UI and Finder/Launchpad behavior are unchanged between modes.

## Explicitly not in scope for this doc

- The marketplace install flow that produces new guest apps to export — [09-marketplace.md](09-marketplace.md).
- RAIL session mechanics once the wrapper is running — [04-presentation-rail.md](04-presentation-rail.md).
