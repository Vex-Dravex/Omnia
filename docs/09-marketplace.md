# 09 — Marketplace

Lets the user browse and install Windows/Linux apps that then behave like ordinary Mac apps — without Omnia hosting or redistributing any binaries. The marketplace is a **curated index over existing package catalogs**, not a binary host.

## Catalogs fronted

| Guest OS | Catalog | Why |
|---|---|---|
| Linux | **Flathub** | Already the de facto app store for Linux desktop apps; sandboxed by design (fits a guest that should stay clean); has a queryable API and per-app metadata/icons Omnia can reuse directly. |
| Windows | **winget** (Windows Package Manager, Microsoft-maintained community repo) | Same rationale — an existing, actively maintained catalog with a manifest format and a CLI (`winget`) already present on Windows 11, so the guest side needs no new package-manager infrastructure. |

Omnia does not mirror install artifacts; it stores a **curated index** (a versioned static JSON file, `catalog/index.json`, served from a GitHub Pages/Release asset initially — a real backend service is a post-v1 concern, not required to ship the marketplace) that maps a friendly Omnia listing (name, description, category, screenshot, Omnia-specific compatibility notes) to the underlying catalog's package ID (Flatpak app ID or winget package ID).

## Install flow

1. User browses/searches the marketplace UI (Omnia.app), which reads `catalog/index.json` (cached locally, refreshed periodically).
2. User clicks Install on a listing.
3. Omnia.app calls `vmd` → `EnsureRunning` for the relevant guest (resumes if suspended, same path as any app launch).
4. `omnia-agent` in that guest runs the real install: `flatpak install flathub <app-id>` (Linux) or `winget install --id <package-id> --silent` (Windows), streaming progress back over vsock for the UI's progress bar.
5. On success, the app is automatically exported (wrapper generated per [05-app-integration.md](05-app-integration.md)) — installing from the marketplace is expected to result in an immediately-usable Mac app, not an extra manual export step, since the user already explicitly chose to install it.
6. Listing shows "Installed" state thereafter; uninstall from the marketplace UI runs the inverse (`flatpak uninstall` / `winget uninstall`) and removes the wrapper.

## Curation, not App-Review

Omnia is not gatekeeping what can run — `omnia ls-apps`/export ([05](05-app-integration.md)) already lets users export anything installed by other means (manually inside a desktop-mode session, [04](04-presentation-rail.md)). The marketplace's curation is purely about **listing quality**: verifying an app installs cleanly and works reasonably under RAIL before featuring it, maintaining accurate metadata, flagging known-incompatible apps (e.g., ones requiring GPU passthrough Omnia doesn't provide). The index format should include a `compatibilityNotes` field for this from day one.

## Index schema (`catalog/index.json`, v1)

```json
{
  "version": 1,
  "apps": [
    {
      "id": "org.gimp.GIMP",
      "name": "GIMP",
      "os": "linux",
      "sourceCatalog": "flathub",
      "sourcePackageId": "org.gimp.GIMP",
      "category": "Graphics & Design",
      "description": "...",
      "iconUrl": "...",
      "screenshotUrls": ["..."],
      "compatibilityNotes": null
    },
    {
      "id": "Mozilla.Firefox",
      "name": "Firefox",
      "os": "windows",
      "sourceCatalog": "winget",
      "sourcePackageId": "Mozilla.Firefox",
      "category": "Internet",
      "description": "...",
      "iconUrl": "...",
      "screenshotUrls": [],
      "compatibilityNotes": null
    }
  ]
}
```

## Explicitly not in scope for v1

- Omnia-run review/rating system, paid listings, or any backend beyond a static generated index.
- Any catalog beyond Flathub and winget (e.g. apt/AUR, Microsoft Store UWP) — can be added later by extending `sourceCatalog` and the corresponding `omnia-agent` install handler without changing the schema.
