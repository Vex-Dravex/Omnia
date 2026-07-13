# M6 — Marketplace

**Goal:** browse, install, and auto-export Windows/Linux apps from Flathub and winget through Omnia.app's UI, per [docs/09-marketplace.md](../docs/09-marketplace.md). Assumes M1–M5 complete (both guest runtimes, export pipeline, and lifecycle management all working).

**Read first:** [docs/09-marketplace.md](../docs/09-marketplace.md) in full, and re-skim [docs/05-app-integration.md](../docs/05-app-integration.md) for the export step this milestone triggers automatically.

## Scope

In scope:
- `catalog/index.json` schema (defined in [docs/09](../docs/09-marketplace.md)) and an initial hand-curated set of ~20–30 apps (mix of Linux/Flathub and Windows/winget) as a starting catalog — enough to make the marketplace usably real, not exhaustive.
- Catalog fetch/cache logic in Omnia.app (fetch from a GitHub Pages/Release URL, cache locally, periodic refresh — no backend service to build).
- Marketplace UI (SwiftUI): browse/search/category list, listing detail view, Install button with progress.
- `InstallApp`/`UninstallApp` RPCs (already defined in [agent.proto](../docs/protocols/agent.proto)) implemented in both `omnia-agent` builds: Linux side runs `flatpak install flathub <id>`, Windows side runs `winget install --id <id> --silent`, both streaming progress back.
- Auto-export-on-install: successful install triggers the same wrapper-generation path from [docs/05](../docs/05-app-integration.md) automatically.
- Uninstall flow: marketplace UI uninstall button → `UninstallApp` RPC → wrapper removal.

Out of scope: any paid/rating/review system, any catalog beyond Flathub+winget, a dynamic backend service (static JSON is sufficient for v1 per [docs/09](../docs/09-marketplace.md)).

## Tasks

1. Write `catalog/index.json` with the initial curated app set; host it (GitHub Pages from this repo, or a Release asset — pick one, document in this milestone's PR).
2. Build catalog fetch/cache in Omnia.app; handle offline gracefully (show cached listings, disable install with a clear message).
3. Build the marketplace browse/search/detail UI.
4. Implement `InstallApp` in the Linux `omnia-agent` (`flatpak install`, streaming `InstallProgress`).
5. Implement `InstallApp` in the Windows `omnia-agent` (`winget install --silent`, streaming `InstallProgress`; note winget's own progress reporting granularity and map it to `InstallProgress.fraction_complete` as best-effort).
6. Wire successful install completion to automatic wrapper export (reuse M2's export code path, don't duplicate).
7. Implement `UninstallApp` on both guest agents and wire the marketplace UI's uninstall action to it + wrapper removal.
8. Add `compatibilityNotes` display in the UI for any catalog entries that have them set.

## Acceptance criteria

- Installing an app from the marketplace (e.g. a Flathub app not previously present in the guest) results, with no further user action, in a working exported `.app` on the Mac desktop — matching M2's export-quality bar.
- Install progress is visibly reflected in the UI (not just a spinner) for both catalog types.
- Uninstalling from the marketplace removes both the guest-side package and the Mac-side wrapper.
- Re-launching Omnia.app after an install correctly shows the app as "Installed" in the marketplace (state persisted/re-derived from `ListApps`, not just an in-session flag).
- Catalog works offline-cached after first fetch (verify by disabling network and reopening the marketplace tab).

## Test strategy

Integration tests against real `flatpak`/`winget` invocations in the guest (choose 2–3 small, fast-installing apps from the curated catalog specifically for CI use, distinct from the "showcase" apps used for manual demo purposes) asserting the full install→export→uninstall cycle via `omnia ls-apps` and filesystem checks on the wrapper bundle. Catalog fetch/cache logic gets standard unit tests (mocked network responses, cache-hit/miss/offline paths).
