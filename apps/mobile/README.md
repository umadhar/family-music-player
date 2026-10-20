# Tiny Tunes

Tiny Tunes is a local music player built with Flutter. Audio is played by a
single `just_audio` player wrapped by `audio_service`; the audio handler
publishes the active queue, track metadata, and playback state to Android's
media notification and lock screen. The app's existing SQLite library,
playlists, favorites, search, and copied local-file imports remain unchanged.
Songs can be removed from the library through the per-song menu after
confirmation. Removal clears that song's favorite state and playlist links,
updates the active playback queue, and never deletes the audio file.

Track IDs in the media queue use the SQLite song ID. The track title and artist
come from the library, with a filename/title and `Local track` fallback for
missing metadata. Queue navigation uses `just_audio` shuffle and loop modes.
Unavailable local files are skipped when a queue starts, and playback errors
are surfaced in the app.

## Android setup and verification

Install the debug build on a physical Android phone and import a few local audio
files. Android displays the playback notification after playback starts.

1. Start playback and confirm the media notification appears.
2. Lock the screen and use play/pause from the lock-screen controls.
3. Use next and previous from the notification and lock screen.
4. Confirm title, artist, and play/pause state update as tracks change.
5. Let a track finish; confirm the queue advances, and that the final track
   stops cleanly unless repeat is enabled.
6. Pause, resume from the notification, then return to the app and confirm the
   mini-player agrees with playback.
7. Confirm the library, playlists, favorites, search, and imported files still
   work.

The Android service and media-button receiver are declared in the main manifest.
The media playback foreground-service and wake-lock permissions are configured
there; no notification runtime permission is required for the media session.
