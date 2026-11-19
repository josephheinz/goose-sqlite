# goose-sqlite

SQLite for [Goose](https://aardappel.github.io/goose/), on the system
`libsqlite3`. Package `sqlite`, used by gweb apps with `import sqlite;`
(gweb then declares it) or directly:

```goose
import sqlite from "josephheinz/goose-sqlite@v1.8.3";   // or a path to a checkout

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
  (`PRAGMA journal_mode=DELETE`). Whether a `ReadOnly` open of a WAL database
  can read without its `-shm` file depends on the SQLite build (it fails on
  macOS). For a database the app writes, read with `Mode.QueryOnly`.
- A worker that aborts mid-statement or mid-transaction releases its
  connections when its thread ends, so its lock does not outlive it.
- Statements: `run(stmt)` steps to the end and resets; `insert(stmt)` also
  gives the new row id and `update(stmt)` the rows changed (both return a
  value and a `bool`).
- Failures: `code(db)` is the extended result code of the last failure;
  `busy(db)` and `constraint(db)` test its primary code; `set_busy_timeout`
  changes the wait.
- Linux needs the libsqlite3 development package.
- `time_limit(db, ms)` interrupts a statement that runs longer than `ms`
  milliseconds from its first step (0 clears it). `step`, `run` or `exec`
  then return false and `interrupted(db)` is true. `begin`, `commit` and
  `rollback` have no limit. Use it for queries built from user input, such as
  full-text search.

## Full-text search (FTS5)

FTS5 is part of SQLite only when the library was built with it. The system
`libsqlite3` on macOS has it. Debian, Ubuntu and Alpine build theirs with it
too, as far as we know; this is not tested here. Check the library the
server links, at start-up:

```goose
let s = sqlite::prepare(db, "SELECT sqlite_compileoption_used('ENABLE_FTS5')");
let fts5 = sqlite::step(s) && sqlite::int(s, 0) == 1;
sqlite::reset(s);
```

Or from a shell on the server: `sqlite3 :memory: "SELECT
sqlite_compileoption_used('ENABLE_FTS5')"` prints 1 (the `sqlite3` tool may
use its own copy of SQLite; the check in Goose is the one that counts). If it
is 0, install a `libsqlite3` built with `SQLITE_ENABLE_FTS5`. Give a search
query a `time_limit`: a short prefix can match much of an index.

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
  gweb, the state owner) and never build SQL from input; bind values.
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

## Query builder

`import sqlite.query;` builds SQL with bound values, so no value is ever
spliced into the text.

```goose
import sqlite.query;

var q = sqlite::select_from("todos", "id, title, done");
sqlite::where(q, "done", "=", false);
sqlite::where_raw(q, "title LIKE ?"); sqlite::arg(q, pattern);
sqlite::order_by(q, "id", true);
sqlite::limit(q, 20); sqlite::offset(q, 40);
let s = sqlite::prepare(db, q);
guard sqlite::ok(s) else { print(sqlite::query_error(q), sqlite::error(db)); return; }
while sqlite::step(s) { ... sqlite::int(s, 0) ... }

var u = sqlite::update_table("todos");
sqlite::set(u, "done", true);
sqlite::where(u, "id", "=", id);
let n, ok = sqlite::update(sqlite::prepare(db, u));
```

- Start with `select_from`, `insert_into`, `update_table` or `delete_from`;
  `where`, `where_null`, `where_not_null`, `where_in`, `where_raw` + `arg`,
  `join`, `group_by`, `order_by`, `limit`, `offset`, `set`, `set_null`,
  `returning` and `all_rows` follow in any order. `sql_text(q, out)` gives
  the SQL for logs.
- `where` clauses join with AND; put OR in a parenthesised `where_raw`.
- Bind order: `set` values, `where` values in call order, then limit and
  offset. `LIMIT ? OFFSET ?` is bound, so every page has one SQL text.
- `where_in` pads to 1, 2, 4, ... 32 placeholders by repeating the last
  value; an empty list is `0 = 1`; more than 32 values is an error.
- Table and column names are checked (`name` or `table.name`), and so is
  `op` (`=`, `!=`, `<>`, `<`, `<=`, `>`, `>=`, `LIKE`, `GLOB`). `cols`,
  `where_raw`, `join`, `group_by` and `returning` refuse quotes, `;`, `--`,
  `/*` and NUL; only `where_raw` may hold `?`. Bind string literals.
- Misuse is a value, not an abort: the first one sets `query_error(q)`,
  later calls do nothing, and `prepare` returns a failed `Stmt`. Misuse is
  a bad name, operator or text; `?` and `arg` counts that differ; more than
  64 values; `set` on a SELECT or DELETE; `where` on an INSERT; an UPDATE or
  DELETE with no `where` and no `all_rows`; an INSERT or UPDATE with no
  `set`; a clause too long for its buffer.
- Equal queries give the same cached `Stmt`: do not run one while iterating
  the other.

Tests: `goose build test/test_sqlite.goose && test/test_sqlite` and
`goose build test/test_query.goose && test/test_query`. The design is in
gweb `docs/DESIGN-ADDENDUM-2.md`, question 3, and
`docs/DESIGN-ADDENDUM-17-PLATFORM.md`, decision 1.
