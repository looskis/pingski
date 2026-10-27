# Pingski

A tiny macOS daemon that turns HTTP requests into native notifications.

```sh
curl -X POST localhost:7464/notify -H 'Content-Type: application/json' -d '{
  "title": "Deploy finished",
  "subtitle": "production",
  "message": "v2.3.1 is live on 12 hosts",
  "icon": "https://example.com/logo.png",
  "url": "https://dash.example.com/deploys/42",
  "actions": [{ "id": "logs", "title": "View logs", "url": "https://dash.example.com/deploys/42/logs" }]
}'
```

* Pure Swift, no third-party dependencies, single ~1 MB binary wrapped in a minimal `.app` bundle
  (macOS only routes notifications to app bundles).
* Full `UserNotifications` feature set: title, subtitle, body, image/logo attachment, deep link on click,
  sound, grouping (threads), badge, interruption level, relevance, delayed delivery, action buttons
  (including text input), replace-by-id, list and remove.
* Click / action / dismiss events via polling, server-sent events and webhooks.
* OpenAPI 3.0 document served at `/openapi.json`, interactive docs at `/docs`, so any client can be generated.
* Optional bearer-token auth, configurable bind address and port, `brew services` support.

## Install

### Homebrew

```sh
brew install lookevink/tap/pingski      # from https://github.com/lookevink/homebrew-tap
brew services start pingski             # optional: run as a LaunchAgent

# or build the latest main from this repo:
brew install --HEAD ./Formula/pingski.rb
```

The formula builds from source with the Swift toolchain, assembles `Pingski.app`, ad-hoc signs it and
installs a `pingski` launcher in `bin`. Settings for the service go in `$(brew --prefix)/etc/pingski.env`:

```sh
PINGSKI_PORT=8080
PINGSKI_TOKEN=change-me
PINGSKI_WEBHOOK=https://hooks.example.com/pingski
```

### Prebuilt archive

Every [release](https://github.com/looskis/pingski/releases) ships a universal (Apple silicon + Intel)
`pingski-x.y.z-macos-universal.tar.gz` containing `Pingski.app` and a `bin/pingski` launcher, plus a
`Pingski-x.y.z.zip` with just the app, and `SHA256SUMS`. Extract the tarball anywhere and put `bin` on
your `PATH`. Archives downloaded with a browser carry the quarantine flag; clear it with
`xattr -dr com.apple.quarantine <extracted dir>`.

### From a checkout

```sh
make build                     # -> build/Pingski.app
make run ARGS="--port 8080"    # run in the foreground
sudo make install              # PREFIX=/usr/local by default
make dist                      # universal release archives in build/dist
```

### First run: allow notifications

The first time Pingski tries to deliver a notification macOS shows a permission prompt. Click **Allow**.
If the prompt was dismissed or the daemon was stopped before you answered, macOS records a denial;
turn Pingski back on under **System Settings > Notifications > Pingski**. `GET /health` reports the
current state (`authorized`, `denied`, `notDetermined`, `provisional`).

For headless or prompt-free setups start with `pingski --provisional`: macOS grants *quiet* delivery
immediately. Notifications land in Notification Center without a banner or sound until the user promotes
them from the notification itself.

## Usage

```
pingski [serve] [--port 7464] [--host 127.0.0.1] [--token SECRET] [--webhook URL] [--provisional] [-v]
pingski send -t "Title" -m "Body" [--url https://...] [--icon path-or-url] [--action id=Title[=url]] ...
pingski openapi            # print the OpenAPI document
```

Environment variables `PINGSKI_PORT`, `PINGSKI_HOST`, `PINGSKI_TOKEN`, `PINGSKI_WEBHOOK`,
`PINGSKI_PROVISIONAL=1` and `PINGSKI_VERBOSE=1` mirror the flags. `PINGSKI_ENV_FILE` points at a
`KEY=VALUE` file that is loaded first.

Bind to `--host 0.0.0.0` to accept notifications from other machines; set `--token` when you do.

## API

| Method | Path | Purpose |
| --- | --- | --- |
| `POST` | `/notify`, `/notifications` | Send a notification (`201` delivered, `202` scheduled) |
| `GET` | `/notifications` | List pending and delivered notifications |
| `GET` / `DELETE` | `/notifications/{id}` | Inspect or remove one notification |
| `DELETE` | `/notifications` | Remove everything |
| `GET` | `/events?since=N&limit=M` | Recent events (`delivered`, `clicked`, `action`, `dismissed`, `removed`) |
| `GET` | `/events/stream` | Server-sent events, supports `Last-Event-ID` |
| `POST` | `/authorize[?provisional=true]` | Trigger the permission prompt |
| `GET` | `/health`, `/openapi.json`, `/docs`, `/` | Status, spec, interactive docs |

### Notification fields

| Field | Aliases | Notes |
| --- | --- | --- |
| `title` (required) | `header`, `heading` | |
| `subtitle` | | |
| `message` | `body`, `text` | |
| `icon` | `logo`, `image` | http(s) URL, file path, `file://` or `data:image/png;base64,...` (PNG, JPEG, GIF, HEIC, WebP, up to 10 MiB). Shown as the notification image. |
| `url` | `link`, `deep_link` | Opened with the default handler when clicked. Any scheme (`https://`, `slack://`, `vscode://`...). |
| `sound` | | `default`, `none`, `critical`, or a system sound name such as `Glass`, `Ping`, `Submarine` |
| `group` | `thread` | Notifications with the same group stack together |
| `badge` | | Dock badge number |
| `priority` | `interruption_level` | `passive`, `active`, `timeSensitive`, `critical` |
| `relevance` | | 0 to 1 |
| `delay` | `delay_seconds` | Seconds until delivery |
| `id` | | Re-sending with the same id replaces the notification |
| `actions` | `buttons` | `[{ "id", "title", "url", "destructive", "foreground", "textInput": { "buttonTitle", "placeholder" } }]` |
| `callbackUrl` | `callback_url`, `webhook` | Receives this notification's events as JSON POSTs |
| `data` | `payload` | Arbitrary JSON echoed in events |

Every response is JSON; errors look like `{"error":{"code":"validation_error","message":"..."}}`.

### Events

```sh
curl -N localhost:7464/events/stream
```

```
id: 12
event: clicked
data: {"seq":12,"type":"clicked","notificationId":"deploy-42","url":"https://dash.example.com/deploys/42","data":{"deployId":42},"timestamp":"..."}
```

The same JSON is POSTed to `--webhook` (all notifications) and `callbackUrl` (per notification) with an
`X-Pingski-Event` header. Events are kept in memory (last 1000) and reset when the daemon restarts.

Click handling requires the daemon to be running; if a notification is clicked after the daemon was
stopped, macOS launches `Pingski.app` and the click is lost.

## Generate a client

The document at `/openapi.json` (also in `openapi/openapi.json`) is OpenAPI 3.0.3, so any generator works:

```sh
# Python
openapi-generator generate -i http://localhost:7464/openapi.json -g python -o clients/python
# TypeScript (fetch)
npx openapi-typescript http://localhost:7464/openapi.json -o pingski.d.ts
# Go
oapi-codegen -package pingski openapi/openapi.json > client.go
```

## Development

```sh
swift build                 # debug binary (cannot post notifications outside the bundle)
make run ARGS="-v"          # build the bundle and run with debug logging
make test                   # unit tests (uses /Applications/Xcode.app for XCTest if xcode-select points at the CLT)
make openapi                # re-embed openapi/openapi.json after editing it
make icon                   # regenerate Resources/AppIcon.icns
```

Layout:

```
Sources/pingski/HTTP/     dependency-free HTTP/1.1 server on Network.framework (keep-alive, chunked, SSE)
Sources/pingski/Router    REST routes, auth, SSE
Sources/pingski/Notifier  UNUserNotificationCenter wrapper and delegate (clicks, actions, deep links)
Sources/pingski/Events    event log, SSE fan-out, webhooks
Sources/pingski/CLI       argument parsing, `send` client
openapi/openapi.json      API contract (embedded into the binary by scripts/embed-openapi.sh)
Formula/pingski.rb        Homebrew formula
```

## Releasing

1. Add a `## [x.y.z] - YYYY-MM-DD` section to `CHANGELOG.md` and commit it.
2. `scripts/release.sh x.y.z` bumps the version in `Version.swift`, `openapi.json` and the formula,
   runs the tests, commits, tags `vx.y.z` and pushes.
3. The `Release` GitHub Actions workflow builds and tests on a macOS runner, attaches the universal
   `pingski-x.y.z-macos-universal.tar.gz`, `Pingski-x.y.z.zip`, `SHA256SUMS` and `pingski.rb` (with
   the real `sha256`) to the GitHub release,
   and pushes the formula to `lookevink/homebrew-tap` using the `TAP_DEPLOY_KEY` repository secret
   (a deploy key with write access to the tap).
4. Without that secret, publish the formula by hand: `scripts/update-tap.sh x.y.z`.

## Limitations

* `timeSensitive` only breaks through Focus if the user allows it for Pingski; `critical` needs an Apple
  entitlement and behaves like `active` without one.
* A custom per-notification app icon is not possible with the public API; `icon` is shown as the
  attachment image next to the Pingski icon.
* macOS refuses notification permission for bundles in temporary directories (`/var/folders`, `/tmp`).

## License

MIT
