// goose build test/test_sqlite.goose && test/test_sqlite
import sqlite from "..";
import std;
import os;

var failed = 0;
fn check(name: const u8[:], ok: bool) { if !ok { write_stderr(str("FAIL ", name, "\n")); failed += 1; } }

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

fn main() {
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
