# Privacy notice

Dynamic Wallpaper Studio is designed to work locally.

## What the application does not do

- It does not require an account.
- It does not upload videos, thumbnails or wallpaper packages.
- It does not include telemetry, analytics or advertising SDKs.
- It does not sell or share user data.

The Windows dependency download script accesses the documented upstream FFmpeg and mpv download URLs only when you run it. The running wallpaper application itself does not require those downloads after setup.

## Local data

The applications can store a library index, copied or converted videos, generated posters, preferences and diagnostics on the computer. Exact paths can differ between installed and portable builds.

- macOS stores its managed library under the user's Application Support container identified by the app bundle identifier.
- Windows installed mode stores data under the user's local application-data directory. Portable mode stores `Data` next to the executable.

Removing an application does not necessarily remove its library. Review and delete the corresponding local data directory separately if that is your intent.

## Diagnostic logs

Windows diagnostics can contain operating-system information, display geometry, process details, exception stacks and complete source-video paths. Before attaching a log to a public issue, inspect it and redact usernames, directory names and other personal information.

The project does not automatically transmit these logs.
