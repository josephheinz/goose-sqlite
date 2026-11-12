# goose-sqlite

SQLite for [Goose](https://aardappel.github.io/goose/), on the system
`libsqlite3`. Package `sqlite`, used by goose-web apps with `import sqlite;`
(gweb then declares it) or directly:

```goose
import sqlite from "../goose-sqlite";

let db = sqlite::local("data/shop.db");          // this thread's read-only connection
let s = sqlite::prepare(db, "SELECT name FROM products WHERE id = ?");
sqlite::bind(s, 1, 42);
if sqlite::step(s) { print(sqlite::text(s, 0)); sqlite::reset(s); }
```

- `local(path, mode)` keeps one connection per thread per path and mode;
  `open` gives a fresh one to `close`.
- `prepare` caches statements per connection by SQL text and returns them
  reset. Running the same query again while iterating it resets the outer loop.
- `step` returns true while there is a row and resets the statement at the
  end; call `reset` only when you stop early.
- Text columns are copied out (`text(s, col, out)` or `text(s, col)`).
- Errors: `ok(db)`, `ok(stmt)`, the `bool` results, and `error(db)`.
- A `ReadOnly` open of a WAL database fails at the first `prepare` unless the
  `-shm` file already exists, so read-only deployments should use
  rollback-journal mode (`PRAGMA journal_mode=DELETE`).
- Linux needs the libsqlite3 development package.

Test: `goose build test/test_sqlite.goose && test/test_sqlite`. The design
is in `../goose-web/DESIGN-ADDENDUM-2.md`, question 3.
