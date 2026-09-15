# Security policy

## Supported source versions

Security fixes are applied to the current `main` branch. At the first public release this corresponds to macOS 2.0.0 and Windows 1.0.4 Preview source, including any post-release hardening commits.

## Reporting a vulnerability

Please use this repository's GitHub private vulnerability-reporting form instead of opening a public issue. Include:

- affected platform and operating-system version;
- the smallest reproducible wallpaper package or steps;
- expected and observed behavior;
- whether the issue can read, overwrite or execute files outside the app library.

Do not include private video files, unredacted local paths, credentials or signing material. If private reporting is unavailable, open a minimal issue asking the maintainer for a private contact channel without publishing exploit details.

## Untrusted media

Treat wallpaper packages as untrusted files. Only import packages from people you trust, keep the operating system current, and avoid running unsigned third-party builds. The project validates package paths and sizes, but media decoders and operating-system frameworks remain part of the attack surface.
