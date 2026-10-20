# Security notes

This app is designed for family use and keeps the first release local-first. It does not use a backend service or external credentials.

## Phase 1 safeguards

- no hard-coded credentials or secrets in the Flutter app
- no direct MySQL access from Android code
- no production endpoints or tokens committed to the repository
- local-only file storage and metadata management
- no unnecessary Android permissions beyond file import and playback requirements

## Future online uploads

Any future cloud upload workflow must use a backend API. The API should validate uploaded files, enforce access controls, and keep database access server-side. The client should never have direct access to server-side database credentials.

## File handling

- retain only the metadata needed for local playback
- avoid storing unnecessary personal information
- copy file-picker inputs into app-managed storage rather than depending on a potentially temporary URI
