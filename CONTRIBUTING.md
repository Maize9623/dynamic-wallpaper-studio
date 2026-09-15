# Contributing

Thank you for helping improve Dynamic Wallpaper Studio.

## Before opening an issue

1. Search existing issues and test the latest `main` branch when practical.
2. State the platform, OS build, display layout, video codec/resolution and exact reproduction steps.
3. Remove personal file paths from screenshots and logs.
4. Do not attach copyrighted media unless you have permission to redistribute it. A short synthetic or CC0 sample is preferred.

Use the private process in [SECURITY.md](SECURITY.md) for vulnerabilities.

## Pull requests

1. Create a focused branch and keep unrelated formatting out of the change.
2. Preserve aspect ratio, local-only behavior and per-display operation.
3. Build the affected platform locally.
4. Explain user-visible behavior, compatibility risks and manual test coverage in the pull request.
5. Add third-party code or assets only with a compatible license and a notice in `THIRD_PARTY_NOTICES.md`.

By submitting a contribution, you agree that it can be distributed under GPL-3.0-or-later.

## Build checks

```bash
./macos/scripts/build.sh
```

```powershell
./windows/scripts/fetch-dependencies.ps1
./windows/scripts/build.ps1
```

Continuous integration checks that both source trees compile. It deliberately does not publish unsigned application bundles or redistribute downloaded media tools.
