# Changelog

## v0.2.0

- Writes: `writer(path, durable)`, `run`, `insert`, `update`, `begin`, `commit`, `rollback`, `migrate` and `version`.
- Errors: `code`, `busy`, `constraint` and `set_busy_timeout`.
- `Mode.QueryOnly`: reads a WAL database that the app writes, whatever order connections open in.
- A thread's cached connections close when the thread ends, so an aborted worker releases its locks.

## v0.1.1

The repo moved from `jheinz-bzs` to `josephheinz`. No code change.

## v0.1.0

First tagged release: per-thread read-only connections and a prepared statement cache on the system `libsqlite3`.
