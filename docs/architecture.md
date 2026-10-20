# Architecture overview

## Phase 1: local-only player

The current application is intentionally local-first and runs entirely on the Android device.

### Components

- Flutter mobile client in `apps/mobile`
- SQLite database for library, songs, playlists, favorites
- Android local file storage for copied audio imports
- `just_audio` for playback and queue management

### Data flow

1. The user imports an audio file through the Android file picker.
2. The app copies the file into an app-managed directory under the app documents area.
3. Metadata is persisted in SQLite so the library survives app restarts.
4. Playback uses the stored local path with `just_audio`.

## Phase 2: online music management (documentation only)

Planned architecture for the future:

- Android client: existing Flutter app
- Web admin: React + TypeScript
- Backend: Python FastAPI
- Metadata database: MySQL on an existing Linux VPS
- Audio storage: private server-side directory outside the public source tree
- Transport: HTTPS API with authenticated requests

Important boundaries:

- The Android app must never directly connect to MySQL.
- The backend should own validation, user access controls, and file storage.
- Clients may browse server metadata, stream tracks, and optionally cache selected songs for offline playback.
