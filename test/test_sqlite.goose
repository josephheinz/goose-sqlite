// goose build test/test_sqlite.goose && test/test_sqlite
import sqlite from "..";
import std;
import os;

var failed = 0;
fn check(name: const u8[:], ok: bool) { if !ok { write_stderr(str("FAIL ", name, "\n")); failed += 1; } }

fn fresh(path: const u8[:]) {
    delete_file(path); delete_file(str(path, "-wal")); delete_file(str(path, "-shm"));
}

struct Seen { fails: i64, first: i64, last: i64 }

struct Done { n: i64, ok: bool }

thread_fn reader(path: u8[..256], i: i64) {
    let db = sqlite::local(path);
    var sum = 0;
    var ok = sqlite::ok(db);
    if !ok { write_stderr(str("reader open: ", sqlite::error(db), "\n")); }
    for k in 1000 {
        let s = sqlite::prepare(db, "SELECT v FROM t WHERE id = ?");
        if ok && !sqlite::ok(s) { write_stderr(str("reader prepare: ", sqlite::error(db), "\n")); }
        ok = ok && sqlite::bind(s, 1, (k % 3) + 1);
        if sqlite::step(s) { sum += sqlite::int(s, 0); sqlite::reset(s); }
        else { if ok { write_stderr(str("reader: ", sqlite::error(db), "\n")); } ok = false; }
    }
    qput(Done { n: sum, ok: ok && sqlite::local(path).h == db.h });
}

fn test_results() {
    let path = "test/w.db";
    fresh(path);
    let db = sqlite::open(path, sqlite::Mode.Create);
    sqlite::exec(db, "CREATE TABLE u (id INTEGER PRIMARY KEY, k TEXT UNIQUE, n INTEGER)");
    let ins = sqlite::prepare(db, "INSERT INTO u (k, n) VALUES (?, ?)");
    sqlite::bind(ins, 1, "a"); sqlite::bind(ins, 2, 1);
    let id, ok = sqlite::insert(ins);
    check("insert id", ok && id == 1);
    let none = sqlite::prepare(db, "UPDATE u SET n = 5 WHERE id = ?");
    sqlite::bind(none, 1, 99);
    let n0, ok0 = sqlite::update(none);
    check("update none", ok0 && n0 == 0);
    sqlite::bind(none, 1, 1);
    let n1, ok1 = sqlite::update(none);
    check("update one", ok1 && n1 == 1);
    sqlite::bind(ins, 1, "b"); sqlite::bind(ins, 2, 2);
    check("run insert", sqlite::run(ins));
    let del = sqlite::prepare(db, "DELETE FROM u WHERE k = ?");
    sqlite::bind(del, 1, "b");
    check("run delete", sqlite::run(del) && sqlite::changes(db) == 1);
    sqlite::bind(ins, 1, "a"); sqlite::bind(ins, 2, 3);
    check("unique fails", !sqlite::run(ins));
    check("constraint code", sqlite::code(db) == 2067 && sqlite::constraint(db));
    check("constraint text", find(sqlite::error(db), "UNIQUE") >= 0);
    check("failed prepare run", !sqlite::run(sqlite::prepare(db, "INSERT INTO nope VALUES (1)")));
    sqlite::close(db);
    fresh(path);
}

fn count_rows(db: sqlite::Db) -> i64 {
    let s = sqlite::prepare(db, "SELECT count(*) FROM u");
    if !sqlite::step(s) { return -1; }
    let n = sqlite::int(s, 0);
    sqlite::reset(s);
    return n;
}

fn add_row(db: sqlite::Db, k: const u8[:]) -> bool {
    let s = sqlite::prepare(db, "INSERT INTO u (k, n) VALUES (?, 0)");
    sqlite::bind(s, 1, k);
    return sqlite::run(s);
}

fn commit_with_defer(db: sqlite::Db) -> bool {
    if !sqlite::begin(db) { return false; }
    defer sqlite::rollback(db);
    add_row(db, "deferred");
    return sqlite::commit(db);
}

fn test_transactions() {
    let path = "test/x.db";
    fresh(path);
    let a = sqlite::open(path, sqlite::Mode.Create);
    sqlite::exec(a, "CREATE TABLE u (id INTEGER PRIMARY KEY, k TEXT UNIQUE, n INTEGER)");
    check("begin", sqlite::begin(a));
    add_row(a, "kept");
    check("commit", sqlite::commit(a));
    check("commit keeps", count_rows(a) == 1);
    sqlite::begin(a);
    add_row(a, "gone");
    sqlite::rollback(a);
    check("rollback discards", count_rows(a) == 1);
    add_row(a, "kept");
    let before = sqlite::code(a);
    sqlite::rollback(a);
    check("rollback idle", sqlite::code(a) == before && before == 2067);
    check("defer rollback after commit", commit_with_defer(a) && count_rows(a) == 2);
    let b = sqlite::open(path, sqlite::Mode.ReadWrite);
    sqlite::begin(a);
    sqlite::set_busy_timeout(b, 50);
    check("begin busy", !sqlite::begin(b) && sqlite::busy(b));
    sqlite::rollback(a);
    sqlite::close(a); sqlite::close(b);
    fresh(path);
}

thread_fn watcher(path: u8[..256]) {
    let db = sqlite::local(path, sqlite::Mode.QueryOnly);
    var seen = Seen { fails: if sqlite::ok(db) { 0 } else { 1 }, first: -1, last: -1 };
    while seen.fails == 0 {
        let s = sqlite::prepare(db, "SELECT count(*) FROM u");
        if sqlite::step(s) {
            let c = sqlite::int(s, 0);
            sqlite::reset(s);
            if seen.first < 0 { seen.first = c; }
            seen.last = c;
        } else { seen.fails += 1; }
        let stop, got = qpoll<i64>();
        if got { break; }
    }
    qput(seen);
}

fn test_query_only() {
    let path = "test/q.db";
    fresh(path);
    let w = sqlite::open(path, sqlite::Mode.Create);
    sqlite::exec(w, "PRAGMA journal_mode=WAL");
    sqlite::exec(w, "CREATE TABLE u (id INTEGER PRIMARY KEY, k TEXT UNIQUE, n INTEGER)");
    add_row(w, "seed");
    sqlite::close(w);
    delete_file(str(path, "-wal")); delete_file(str(path, "-shm"));
    let q = sqlite::local(path, sqlite::Mode.QueryOnly);
    check("query_only reads wal without shm", sqlite::ok(q) && count_rows(q) == 1);
    check("query_only rejects write", !add_row(q, "nope") && (sqlite::code(q) & 255) == 8);
    sqlite::close(q);
    delete_file(str(path, "-wal")); delete_file(str(path, "-shm"));
    let r = sqlite::open(path, sqlite::Mode.ReadOnly);
    check("readonly fails wal without shm", !sqlite::ok(sqlite::prepare(r, "SELECT count(*) FROM u")));
    sqlite::close(r);
    delete_file(str(path, "-wal")); delete_file(str(path, "-shm"));

    let main_db = sqlite::open(path, sqlite::Mode.ReadWrite);
    var p: u8[..256] = "";
    p.append(path);
    for i in 3 { thread_spawn(watcher, p); }
    for i in 2000 { add_row(main_db, str("k", i)); }
    sleep_ms(50);
    for i in 3 { qput(1 as i64); }
    var fails = 0;
    var changed = true;
    for i in 3 { let s = qget<Seen>(); fails += s.fails; changed = changed && s.last > s.first; }
    check("threads see writes", fails == 0 && changed);
    sqlite::close(main_db);
    fresh(path);
}

fn main() {
    test_results();
    test_query_only();
    test_transactions();
    let path = "test/t.db";
    delete_file(path);
    let w = sqlite::open(path, sqlite::Mode.Create);
    check("open create", sqlite::ok(w));
    check("create", sqlite::exec(w, "CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER, name TEXT, x REAL)"));
    let ins = sqlite::prepare(w, "INSERT INTO t (v, name, x) VALUES (?, ?, ?)");
    for v in [10, 20, 30] {
        sqlite::bind(ins, 1, v);
        sqlite::bind(ins, 2, str("n", v, " <ü>"));
        sqlite::bind(ins, 3, v * 0.5);
        check("insert", !sqlite::step(ins));
    }
    check("last id", sqlite::last_insert_id(w) == 3);
    sqlite::bind(ins, 1, 40); sqlite::bind_null(ins, 2); sqlite::bind(ins, 3, 1.0); sqlite::step(ins);
    check("changes", sqlite::changes(w) == 1);
    let q = sqlite::prepare(w, "SELECT id, v, name, x FROM t ORDER BY id");
    var names: u8[>..] = [];
    var rows = 0;
    var nulls = 0;
    while sqlite::step(q) {
        rows += 1;
        if sqlite::is_null(q, 2) { nulls += 1; } else { sqlite::text(q, 2, names); names.push('|'); }
        check("float", sqlite::float(q, 3) > 0.0);
    }
    check("rows", rows == 4);
    check("nulls", nulls == 1);
    check("text copy", names == "n10 <ü>|n20 <ü>|n30 <ü>|");
    check("same statement", sqlite::prepare(w, "SELECT id, v, name, x FROM t ORDER BY id").h == q.h);
    check("bad sql", !sqlite::ok(sqlite::prepare(w, "SELEC nope")));
    check("error text", find(sqlite::error(w), "syntax") >= 0);
    check("journal", sqlite::exec(w, "PRAGMA journal_mode=DELETE"));
    sqlite::close(w);
    let missing = sqlite::open("test/missing.db");
    check("missing fails", !sqlite::ok(missing));
    check("missing error", sqlite::error(missing).len > 0);
    var p: u8[..256] = "";
    p.append(path);
    for i in 4 { thread_spawn(reader, p, i); }
    var total = 0;
    var all_ok = true;
    for i in 4 { let d = qget<Done>(); total += d.n; all_ok = all_ok && d.ok; }
    check("threads", all_ok && total == 4 * (334 * 10 + 333 * 20 + 333 * 30));
    print(if failed == 0 { "all sqlite checks passed" } else { "sqlite checks failed" });
    exit(if failed == 0 { 0 } else { 1 });
}
