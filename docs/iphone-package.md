# Jailbroken iPhone Package

The production jailbroken iPhone package is built from `backend-swift/` as `wiki.qaq.unfaird`. It serves the built React frontend, exposes the same `/api/*` surface used by the web app, handles Wisp TCP proxying, downloads Apple CDN IPAs on the server, injects SINF and metadata, decrypts the IPA locally through unfaird, and serves completed IPA files back to the frontend.

It intentionally does not install IPAs locally. The completed decrypted package remains in `DATA_DIR/packages`, and the frontend downloads it through `/api/packages/{id}/file`.

## Decryption Flow

The integrated Swift backend exposes the same API contract as `../unfairdaemon/unfair.sh`:

```text
POST /api/v1/decrypt multipart field ipa
GET queue.ready_url
GET queue.download_url
```

The AssppWeb download API calls this local decrypt path directly inside the same launchd service.

## Build

```bash
make build
```

`make build` creates one complete rootless deb containing:

- the Vite frontend from `frontend/dist`
- the Swift/Vapor backend binary
- Swift runtime libraries required by the iOS binary
- the launchd plist and maintainer scripts

Install the generated package on a jailbroken iPhone:

```bash
make install DEVICE_HOST=root@192.168.2.122
```

## Runtime Layout

```text
/var/jb/usr/share/assppweb/
  public/

/var/jb/usr/local/lib/unfaird/
  UnfairDaemon
  libswift*.dylib

/var/mobile/AssppWebData/
  packages/
  tasks.json
```

On Dopamine/rootless, the executable is staged by Theos under the package install prefix and signed with `ldid`.

## Environment

| Variable | Default | Purpose |
| --- | --- | --- |
| `PORT` | `8080` | HTTP listen port |
| `DATA_DIR` | `./data` | Persistent download metadata and IPA cache |
| `PUBLIC_DIR` | `./public` | Built frontend assets |
| `PUBLIC_BASE_URL` | auto-detect | Absolute base URL for manifest generation |
| `DOWNLOAD_THREADS` | `8` | Parallel HTTP range download workers |
| `MAX_DOWNLOAD_MB` | `0` | Optional server-side size limit |
| `ACCESS_PASSWORD` | empty | Optional UI/API access password |
