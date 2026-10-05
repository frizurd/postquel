# Postquel

A native macOS PostgreSQL client (SwiftUI + AppKit + libpq). Prototype.

## Run

Requires Xcode / Swift 6 and libpq (defaults to Postgres.app; set `LIBPQ_PREFIX` for Homebrew `libpq`).

```sh
./scripts/build-app.sh --install   # build, install to /Applications, relaunch if running
./scripts/dev.sh                   # watch mode: rebuild + reinstall + relaunch on every change
swift run                          # run without bundling
```

Demo data: `createdb postquel_demo && psql postquel_demo -f scripts/seed-demo.sql`

## Layout

- `Sources/CLibPQ` – module map for libpq
- `Sources/Postquel/Database` – `PGConnection` (libpq on a serial queue, text results, cancel)
- `Sources/Postquel/Models` – session, table browser, query editor state
- `Sources/Postquel/Views` – `ResultsGrid` (NSTableView), `SQLEditor` (NSTextView), SwiftUI shell
