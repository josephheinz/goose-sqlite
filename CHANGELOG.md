# Changelog

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
