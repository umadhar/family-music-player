# Kids Music Player

A lightweight, child-friendly, local-first Android music player built on Flutter.

## MVP scope

This repository contains the Phase 1 Android app. It supports:

- importing local MP3 and M4A files from Android storage
- library browsing with search
- playback controls, queueing, shuffle and repeat toggles
- playlists and a favorites collection
- local SQLite persistence for song and playlist metadata
- a cheerful Material 3 design for children and families

The application is intentionally local-first and does not require internet access after songs are imported.

## Repository structure

- `apps/mobile` — Flutter Android application
- `services/api` — future backend documentation placeholder
- `apps-admin` — future admin UI placeholder
- `docs/` — architecture, roadmap, and security documentation
- `.github/workflows/android-apk.yml` — GitHub Actions workflow for the debug APK

## Prerequisites

- Flutter 3.41.9 or newer stable
- Android Studio or a compatible Android SDK
- A connected Android device or emulator

## Install Flutter

Follow the official guide at https://docs.flutter.dev/get-started/install.

Once installed, confirm the toolchain:

```bash
flutter --version
```

## Run locally

```bash
cd apps/mobile
flutter pub get
flutter run
```

## Formatting, analysis, and tests

```bash
cd apps/mobile
flutter format lib test
flutter analyze
flutter test
```

## Build APK locally

```bash
cd apps/mobile
flutter build apk --debug
```

The APK will be generated under `build/app/outputs/flutter-apk`.

## Trigger the GitHub Actions build

Push changes to the repository branch or open a pull request affecting `apps/mobile/**` and `.github/workflows/android-apk.yml`. You can also run the workflow manually from the GitHub Actions tab using the "Run workflow" button.

## Notes

- The GitHub workflow is set up for CI on GitHub but was not executed in this local environment.
- Background playback and notification controls are partially documented but not fully implemented under the MVP budget. The app attempts reliable playback while the app is active and keeps the player state in memory for the session.
- The app copies imported files into an app-managed local directory and stores references to those files, avoiding a dependency on a permanently accessible file-picker URI.
