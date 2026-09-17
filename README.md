# Arsip

A native macOS PostgreSQL client (SwiftUI + AppKit + libpq). Prototype.

## Run

Requires Xcode / Swift 6 and libpq (defaults to Postgres.app; set `LIBPQ_PREFIX` for Homebrew `libpq`).

```sh
./scripts/build-app.sh --install   # build, install to /Applications, relaunch if running
./scripts/dev.sh                   # watch mode: rebuild + reinstall + relaunch on every change
swift run                          # run without bundling
```

Demo data: `createdb arsip_demo && psql arsip_demo -f scripts/seed-demo.sql`

## Layout

- `Sources/CLibPQ` – module map for libpq
- `Sources/Arsip/Database` – `PGConnection` (libpq on a serial queue, text results, cancel)
- `Sources/Arsip/Models` – session, table browser, query editor state
- `Sources/Arsip/Views` – `ResultsGrid` (NSTableView), `SQLEditor` (NSTextView), SwiftUI shell
