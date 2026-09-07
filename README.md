# KeplerCrew

Autonomous engineering cockpit by aichargelabs. This repository hosts the
KeplerCrew client installers. A valid license key is required — downloads are
license-gated; the installer scripts themselves are public.

## Install

### Windows (PowerShell)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "iex (irm https://get.keplercrew.com/install.ps1)"
```

The installer prompts for your license key (input hidden). To run unattended:

```powershell
$env:KEPLER_LICENSE_KEY = "<your license key>"
powershell -NoProfile -ExecutionPolicy Bypass -Command "iex (irm https://get.keplercrew.com/install.ps1)"
```

### macOS / Linux

```sh
curl -fsSL https://get.keplercrew.com/install.sh | sh
```

## Updating

Re-run the same install command to update in place:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "iex (irm https://get.keplercrew.com/install.ps1)"
```

On macOS/Linux, re-run the installer to update in place:

```sh
curl -fsSL https://get.keplercrew.com/install.sh | sh
```

The installer reuses the stored license key from the previous install. To force a
reinstall even when already on the latest version, set `KEPLER_FORCE=1`.

## Options (environment variables)

| Variable | Effect |
| --- | --- |
| `KEPLER_LICENSE_KEY` | License key (skips the prompt; stored key is reused on update) |
| `KEPLER_VERSION` | Pin a version, e.g. `1.0.0` (default: latest) |
| `KEPLER_DRY_RUN=1` | Resolve and print the release without downloading |
| `KEPLER_INSTALL_DIR` | Install directory (default: `%LOCALAPPDATA%\Programs\KeplerCrew` on Windows, `~/.local/share/keplercrew` on Unix) |
| `KEPLER_NO_LAUNCH=1` | Install without launching |
| `KEPLER_FORCE=1` | Reinstall even when already on the resolved version |

## What the installer does

- Validates your license key before downloading anything.
- Downloads the latest bundle your license is entitled to, over HTTPS.
- Verifies the SHA256 checksum against the release metadata.
- Extracts to a per-user directory — no administrator access required.
- Stores your license key locally with user-only file permissions.
- Does not install telemetry.

## Getting a license

KeplerCrew is licensed software. For a trial or purchase, contact
support@aichargelabs.com or visit [keplercrew.com](https://keplercrew.com).

## Uninstall

### Windows (PowerShell)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "iex (irm https://get.keplercrew.com/uninstall.ps1)"
```

### macOS / Linux

```sh
curl -fsSL https://get.keplercrew.com/uninstall.sh | sh
```

The uninstaller stops the app, **frees your license seat** so the same key can be
activated on another machine, removes the `kepler` command from your PATH, and
deletes the install directory. Your projects and history in
`%USERPROFILE%\.kepler-trial` (`~/.kepler-trial` on macOS/Linux) are **kept** — a
later reinstall picks them up again.

Do not simply delete the install folder: the license seat stays activated on a
machine that no longer exists, and the next install with that key can be refused.
If that has already happened, email support@aichargelabs.com to release it.

| Variable | Effect |
| --- | --- |
| `KEPLER_PURGE=1` | Also delete your local data (projects, cycles, logs) |
| `KEPLER_KEEP_LICENSE=1` | Keep the seat activated (reinstalling on this same machine) |
| `KEPLER_YES=1` | Skip the confirmation prompt (unattended) |
| `KEPLER_INSTALL_DIR` | Uninstall from a non-default install directory |

KeplerCrew is developed by aichargelabs.
