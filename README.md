# goose-sqlite

SQLite for [Goose](https://aardappel.github.io/goose/), on the system
`libsqlite3`. Package `sqlite`, used by goose-web apps with `import sqlite;`
(gweb then declares it) or directly:

```goose
import sqlite from "josephheinz/goose-sqlite@v0.2.1";   // or a path to a checkout

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
- `ReadOnly` is for a database nobody writes, in rollback-journal mode
  (`PRAGMA journal_mode=DELETE`): a `ReadOnly` open of a WAL database fails at
  the first `prepare` unless the `-shm` file already exists. For a database the
  app writes, read with `Mode.QueryOnly`.
- A worker that aborts mid-statement or mid-transaction releases its
  connections when its thread ends, so its lock does not outlive it.
- Statements: `run(stmt)` steps to the end and resets; `insert(stmt)` also
  gives the new row id and `update(stmt)` the rows changed (both return a
  value and a `bool`).
- Failures: `code(db)` is the extended result code of the last failure;
  `busy(db)` and `constraint(db)` test its primary code; `set_busy_timeout`
  changes the wait.
- Linux needs the libsqlite3 development package.

## Writes

One connection writes each database, from one thread, and everything else
reads through `Mode.QueryOnly`.

```goose
let db = sqlite::writer("data/app.db");          // WAL, created if missing
if !sqlite::ok(db) { print(sqlite::error(db)); exit(1); }
sqlite::migrate(db, ["CREATE TABLE todos (id INTEGER PRIMARY KEY, title TEXT NOT NULL)"]);

let s = sqlite::prepare(db, "INSERT INTO todos (title) VALUES (?)");
sqlite::bind(s, 1, "write it down");
if !sqlite::begin(db) { return; }
defer sqlite::rollback(db);                      // does nothing once the commit succeeded
let id, inserted = sqlite::insert(s);
if inserted { sqlite::commit(db); }
```

- `writer(path, durable = false)` returns this thread's read-write connection
  in WAL mode, creating the file if needed. The first thread to ask claims the
  path for the life of the process: any other thread gets a failed `Db` whose
  `error` says another thread is the writer. The claim is keyed by the path
  text, so `data/app.db` and `./data/app.db` are two claims. Closing the
  connection, or the thread ending, releases it. Keep writes on one thread (in
  goose-web, the state owner) and never build SQL from input; bind values.
- Readers use `local(path, Mode.QueryOnly)`. It opens read-write and sets
  `query_only=1`, so it works whatever the order connections open in, sees
  committed writes at its next statement, and rejects writes with code 8.
- `begin` is `BEGIN IMMEDIATE`; the writer waits up to 1,000 ms for another
  process's lock there, then `busy(db)` is true. `commit` and `rollback` as in
  the example.
- `migrate(db, steps)` takes `PRAGMA user_version` from `i` to `i + 1` with
  step `i`, in one transaction, and returns at once when the version already
  matches. A step may hold several statements. It returns false when a step
  fails (nothing is kept) or the database is newer than `steps`. Run it right
  after `writer`, at start-up, before any worker starts.
- Durability is the app author's choice, made with `durable`. The default is
  `synchronous=NORMAL`: no commit is lost when the process crashes and the
  file is never corrupted, but an OS crash or power loss can drop the last
  commits. `writer(path, true)` sets `synchronous=FULL` and `fullfsync=1`, so
  every commit reaches the disk, at a much higher cost per commit (about 0.6
  ms against about 10 microseconds on an Apple SSD).

Test: `goose build test/test_sqlite.goose && test/test_sqlite`. The design
is in goose-web `docs/DESIGN-ADDENDUM-2.md`, question 3.
