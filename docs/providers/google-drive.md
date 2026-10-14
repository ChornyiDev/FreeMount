# Google Drive

Connects a Google account to Finder. Each connection exposes either **My Drive**
(with a virtual **Shared with me** folder) or one **Shared Drive**.

## Sign-in

- Browser OAuth 2.0 desktop flow with PKCE. The callback is accepted only on a
  short-lived listener at `http://127.0.0.1:<port>/oauth2/callback`.
- Requested scope: `https://www.googleapis.com/auth/drive` (full Drive access,
  needed to read and write arbitrary files).
- You must supply your own OAuth client (type **Desktop app**). See
  [building.md](../building.md).
- Tokens are stored only in the shared Keychain. Connecting the same account again
  reuses the existing connection instead of creating a duplicate.

## Connection types

| Type | Behavior |
|---|---|
| My Drive | Your files. A virtual **Shared with me** folder lists items others shared with you. |
| Shared Drive | Pick one drive from those visible to the account; the connection is rooted there (rclone `team_drive`). |

Shared Drive discovery uses the local rclone daemon. If the account has none, the
form says so.

## Behavior and limits

- Listing, on-demand download and writeback go through the shared rclone backend
  and File Provider pipeline ([architecture.md](../architecture.md)).
- Changes made to files outside FreeMount appear after Finder refreshes the folder.
- Revoking access in your Google account settings requires reconnecting.

## References

- [Google OAuth for desktop apps](https://developers.google.com/identity/protocols/oauth2/native-app)
- [rclone Google Drive backend](https://rclone.org/drive/)
