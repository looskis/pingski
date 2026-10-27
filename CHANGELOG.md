# Changelog

All notable changes to Pingski are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow semver.

## [0.1.0] - 2026-10-27

### Added

- HTTP daemon on Network.framework (keep-alive, chunked bodies, CORS, SSE) with `--port`, `--host`,
  `--token`, `--webhook`, `--provisional`, env vars and `PINGSKI_ENV_FILE`.
- `POST /notify` with title, subtitle, message, icon (URL, file or data URI), deep link, sound, group,
  badge, priority, relevance, delayed delivery, action buttons with text input, and replace-by-id.
- List, get, remove and clear notifications; `POST /authorize` to trigger the permission prompt.
- Click, action, dismiss, delivered and removed events via `GET /events`, SSE `/events/stream`,
  a global webhook and per-notification `callbackUrl`.
- OpenAPI 3.0.3 document at `/openapi.json` and interactive docs at `/docs`.
- `pingski send` client and `pingski openapi` spec dump.
- Homebrew formula with a `brew services` definition.
