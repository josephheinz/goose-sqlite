# Changelog

## v1.8.8

No code change. Tagged with gweb v1.8.8.

## v1.8.7

No code change. Tagged with gweb v1.8.7.

## v1.8.6

No code change. Tagged with gweb v1.8.6.

## v1.8.5

No code change. Tagged with gweb v1.8.5.

## v1.8.4

No code change. Tagged with gweb v1.8.4.

## v1.8.3

No code change. Tagged with gweb v1.8.3.

## v1.8.2

No code change. Tagged with gweb v1.8.2.

## v1.8.1

No code change. Tagged with gweb v1.8.1.

## v1.8.0

No code change. Tagged with gweb v1.8.0.

## v1.7.0

No code change. Tagged with gweb v1.7.0.

## v1.6.0

No code change. Tagged with gweb v1.6.0.

## v1.5.0

No code change. Tagged with gweb v1.5.0.

## v1.4.0

No code change. Tagged with gweb v1.4.0.

## v1.3.0

No code change. Tagged with gweb v1.3.0.

## v1.2.0

- `sqlite::time_limit(db, ms)`: a statement that runs longer than `ms` milliseconds from its first step is interrupted
  (a progress handler; 0 clears it). `sqlite::interrupted(db)` says the limit stopped the last statement.
- README: full-text search needs a `libsqlite3` built with FTS5, and how to check.

## v1.1.0

No code change. Tagged with gweb v1.1.0.

## v1.0.0

No code change. Tagged with gweb v1.0.0. From here gweb, goose-net and goose-sqlite follow semver together (gweb docs/site/stability.md).

## v0.7.0

No code change. Tagged with gweb v0.7.0.

## v0.6.0

No code change. Tagged with gweb v0.6.0.

## v0.5.1

Tagged with gweb v0.5.1. Whether `ReadOnly` reads a WAL database without its `-shm` file depends on the SQLite build; the test and README now say so (it fails on macOS, reads on Ubuntu). Use `QueryOnly` for a database the app writes.

## v0.5.0

No code change. Tagged with gweb v0.5.0. CI: GitHub Actions test on macOS and Linux and publish a release for each `v*` tag.

## v0.4.0

No code change. Tagged with gweb v0.4.0 (the renamed goose-web), which pins one tag for all three packages.

## v0.3.0

- Query builder: `import sqlite.query;` builds select, insert, update and delete with bound values and checked names.

## v0.2.1

No code change. Tagged with goose-web v0.2.1, which pins one tag for all three packages.

## v0.2.0

- Writes: `writer(path, durable)`, `run`, `insert`, `update`, `begin`, `commit`, `rollback`, `migrate` and `version`.
- Errors: `code`, `busy`, `constraint` and `set_busy_timeout`.
- `Mode.QueryOnly`: reads a WAL database that the app writes, whatever order connections open in.
- A thread's cached connections close when the thread ends, so an aborted worker releases its locks.

## v0.1.1

The repo moved from `jheinz-bzs` to `josephheinz`. No code change.

## v0.1.0

First tagged release: per-thread read-only connections and a prepared statement cache on the system `libsqlite3`.
