# SFTP, WebDAV, SMB and FTP/FTPS

These providers use the official pinned rclone backend through the shared
`GenericRcloneFileProviderBackend`. Listing, download, writeback, metadata checks,
read-only policy and cancellation all follow the common pipeline described in
[architecture.md](../architecture.md). Secrets are stored only in Keychain; before
saving, each form lists the exact root Finder will use. A failed or stale test
cannot enable Save, and preparation errors never fall back to plaintext.

Live Finder validation on real servers is pending for SMB and FTP/FTPS.

## WebDAV

- Supports Basic password authentication and bearer tokens. Passwords are
  obscured for rclone before storage.
- **Digest-only servers are not supported** by the pinned runtime. A credential-free
  HEAD probe rejects a confirmed Digest-only endpoint before listing.
- Bearer mode omits username and password: rclone prefers Basic whenever `user`
  or `pass` is present.
- A successful listing does not prove read/write access to individual files.

## SMB

- One share per connection plus an optional relative subfolder; the first root
  segment is the share (`Family` + `Photos/2026` becomes `Family/Photos/2026`).
- Default port 445, optional NTLM domain (default `WORKGROUP`). Guest mode uses
  `guest` with an empty password. Kerberos and SMB1-only servers are not supported.
- Traversal segments and backslash paths are rejected; the server root cannot be
  exposed. The form can discover shares through a directories-only RC list.

## FTP / FTPS

- Modes: FTP (port 21), FTPS explicit (21), FTPS implicit (990). TLS verification
  is on by default; an explicit toggle maps to `no_check_certificate` in FTPS only.
  Plain FTP shows an encryption warning.
- Anonymous login uses `anonymous`/`anonymous`.
- A blank remote folder is the account home; absolute roots keep the leading slash.

## SFTP

Uses the same generic backend with password or SSH key authentication. Local keys
can be discovered from `~/.ssh` (see `SSHKeyDiscoveryService`).

### Tunnels and proxies

The form's *SSH Tunnel & Proxy* section builds an `ssh` command for rclone
(`SSHTunnelConfiguration`), so the server never needs a publicly exposed port 22:

| Mode | Use |
|---|---|
| Direct | Plain connection to host and port |
| Cloudflare | `ProxyCommand` through `cloudflared access ssh` (requires `cloudflared` installed) |
| Jump host | OpenSSH `-J` / ProxyJump through a bastion |
| Custom ProxyCommand | Any command, e.g. `ncat --proxy-type socks5 127.0.0.1:9050 %h %p` |

The proxy tools run on your Mac with your permissions; FreeMount does not bundle them.

## References

- [rclone SMB](https://rclone.org/smb/), [WebDAV](https://rclone.org/webdav/),
  [FTP](https://rclone.org/ftp/), [SFTP](https://rclone.org/sftp/)
