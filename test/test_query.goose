// goose build test/test_query.goose && test/test_query
import sqlite from "..";
import sqlite.query;
import std;
import os;

var failed = 0;
fn check(name: const u8[:], ok: bool) { if !ok { write_stderr(str("FAIL ", name, "\n")); failed += 1; } }

fn fresh(path: const u8[:]) {
    delete_file(path); delete_file(str(path, "-wal")); delete_file(str(path, "-shm"));
}

fn sql(q: const sqlite::Query&) -> u8[>..] {
    var out: u8[>..] = [];
    sqlite::sql_text(q, out);
    return out;
}

fn marks_in(s: const u8[:]) -> i64 {
    var n = 0;
    for i in 0..s.len { if s[i] == '?' { n += 1; } }
    return n;
}

fn test_text() {
    var q = sqlite::select_from("todos", "id, title, done");
    sqlite::where(q, "done", "=", false);
    sqlite::where_raw(q, "title LIKE ?"); sqlite::arg(q, "%x%");
    sqlite::order_by(q, "id", true);
    sqlite::limit(q, 20); sqlite::offset(q, 40);
    check("select error", sqlite::query_error(q) == "");
    check("select text", sql(q) == "SELECT id, title, done FROM todos WHERE done = ? AND (title LIKE ?) ORDER BY id DESC LIMIT ? OFFSET ?");

    var plain = sqlite::select_from("t", "*");
    check("select plain", sql(plain) == "SELECT * FROM t");

    var lim = sqlite::select_from("t", "a");
    sqlite::limit(lim, 5);
    check("select limit only", sql(lim) == "SELECT a FROM t LIMIT ? OFFSET ?");
    var off = sqlite::select_from("t", "a");
    sqlite::offset(off, 5);
    check("select offset only", sql(off) == "SELECT a FROM t LIMIT ? OFFSET ?");

    var ord = sqlite::select_from("t", "a");
    sqlite::order_by(ord, "a"); sqlite::order_by(ord, "b", true);
    check("select order twice", sql(ord) == "SELECT a FROM t ORDER BY a, b DESC");

    var nulls = sqlite::select_from("t", "a");
    sqlite::where_null(nulls, "a"); sqlite::where_not_null(nulls, "b");
    check("where null", sql(nulls) == "SELECT a FROM t WHERE a IS NULL AND b IS NOT NULL");

    var ins = sqlite::insert_into("t");
    sqlite::set(ins, "a", 1); sqlite::set(ins, "b", "x");
    check("insert", sql(ins) == "INSERT INTO t (a, b) VALUES (?, ?)");
    var ins1 = sqlite::insert_into("t");
    sqlite::set_null(ins1, "a");
    sqlite::returning(ins1, "id");
    check("insert one returning", sql(ins1) == "INSERT INTO t (a) VALUES (?) RETURNING id");

    var upd = sqlite::update_table("t");
    sqlite::set(upd, "a", 1);
    sqlite::where(upd, "id", "=", 7);
    check("update", sql(upd) == "UPDATE t SET a = ? WHERE id = ?");
    var upd2 = sqlite::update_table("t");
    sqlite::set(upd2, "a", 1); sqlite::set(upd2, "b", 2.5);
    sqlite::all_rows(upd2);
    check("update all", sql(upd2) == "UPDATE t SET a = ?, b = ?");

    var del = sqlite::delete_from("t");
    sqlite::where(del, "id", "=", 7);
    sqlite::returning(del, "id, a");
    check("delete returning", sql(del) == "DELETE FROM t WHERE id = ? RETURNING id, a");
    var del2 = sqlite::delete_from("t");
    sqlite::all_rows(del2);
    check("delete all", sql(del2) == "DELETE FROM t");

    var jn = sqlite::select_from("todos", "todos.id, u.name");
    sqlite::join(jn, "JOIN users u ON u.id = todos.user_id");
    sqlite::join(jn, "LEFT JOIN tags g ON g.todo = todos.id");
    sqlite::where(jn, "u.name", "=", "ann");
    check("join", sql(jn) == "SELECT todos.id, u.name FROM todos JOIN users u ON u.id = todos.user_id LEFT JOIN tags g ON g.todo = todos.id WHERE u.name = ?");

    var gb = sqlite::select_from("todos", "done, count(*)");
    sqlite::group_by(gb, "done");
    sqlite::order_by(gb, "done");
    check("group by", sql(gb) == "SELECT done, count(*) FROM todos GROUP BY done ORDER BY done");

    var broken = sqlite::select_from("bad name", "a");
    var out: u8[>..] = [];
    check("sql_text fails on error", !sqlite::sql_text(broken, out) && out.len == 0);
}

fn in_text(vs: const i64[:]) -> u8[>..] {
    var q = sqlite::select_from("t", "a");
    sqlite::where_in(q, "a", vs);
    return sql(q);
}

fn test_where_in() {
    check("in 1", marks_in(in_text([1])) == 1);
    check("in 2", marks_in(in_text([1, 2])) == 2);
    check("in 3 pads to 4", marks_in(in_text([1, 2, 3])) == 4);
    check("in 5 pads to 8", marks_in(in_text([1, 2, 3, 4, 5])) == 8);
    check("in 1 text", in_text([1]) == "SELECT a FROM t WHERE a IN (?)");
    check("in 3 text", in_text([1, 2, 3]) == "SELECT a FROM t WHERE a IN (?, ?, ?, ?)");
    var none: i64[>..] = [];
    check("in empty", in_text(none) == "SELECT a FROM t WHERE 0 = 1");
    var many: i64[>..] = [];
    for i in 32 { many.push(i); }
    check("in 32", marks_in(in_text(many)) == 32);
    many.push(32);
    var q = sqlite::select_from("t", "a");
    sqlite::where_in(q, "a", many);
    check("in 33 errors", sqlite::query_error(q).len > 0 && sql(q) == "");
    var t = sqlite::select_from("t", "a");
    sqlite::where_in(t, "a", ["x", "y", "z"]);
    check("in text 3 pads to 4", marks_in(sql(t)) == 4);
}

fn bad(db: sqlite::Db, name: const u8[:], q: const sqlite::Query&) {
    check(name, sqlite::query_error(q).len > 0 && !sqlite::ok(sqlite::prepare(db, q)));
}

fn test_misuse(db: sqlite::Db) {
    var nul: u8[>..] = [];
    nul.append("a = 1");
    nul.push(0 as u8);

    var a1 = sqlite::select_from("bad name", "a"); bad(db, "bad table", a1);
    var a2 = sqlite::select_from("1abc", "a"); bad(db, "table starts with digit", a2);
    var a3 = sqlite::select_from("a.b.c", "a"); bad(db, "table two dots", a3);
    var a4 = sqlite::select_from("t", "a'b"); bad(db, "cols quote", a4);
    var a5 = sqlite::select_from("t", "a = ?"); bad(db, "cols mark", a5);
    var a6 = sqlite::select_from("t", ""); bad(db, "cols empty", a6);
    var b1 = sqlite::select_from("t", "a"); sqlite::where(b1, "a;b", "=", 1); bad(db, "bad column", b1);
    var b2 = sqlite::select_from("t", "a"); sqlite::where(b2, "a", "= 1 OR 1 =", 1); bad(db, "bad operator", b2);
    var b3 = sqlite::select_from("t", "a"); sqlite::where(b3, "a", "like", "x"); bad(db, "operator is case sensitive", b3);
    var b4 = sqlite::select_from("t", "a"); sqlite::where_null(b4, "a b"); bad(db, "bad null column", b4);
    var c1 = sqlite::select_from("t", "a"); sqlite::where_raw(c1, "a = 'x'"); bad(db, "raw single quote", c1);
    var c2 = sqlite::select_from("t", "a"); sqlite::where_raw(c2, "a = \"x\""); bad(db, "raw double quote", c2);
    var c3 = sqlite::select_from("t", "a"); sqlite::where_raw(c3, "a = 1; DROP TABLE t"); bad(db, "raw semicolon", c3);
    var c4 = sqlite::select_from("t", "a"); sqlite::where_raw(c4, "a = 1 -- x"); bad(db, "raw line comment", c4);
    var c5 = sqlite::select_from("t", "a"); sqlite::where_raw(c5, "a = 1 /* x */"); bad(db, "raw block comment", c5);
    var c6 = sqlite::select_from("t", "a"); sqlite::where_raw(c6, nul); bad(db, "raw nul", c6);
    var c7 = sqlite::select_from("t", "a"); sqlite::join(c7, "JOIN u ON u.id = ?"); bad(db, "join mark", c7);
    var c8 = sqlite::select_from("t", "a"); sqlite::join(c8, "JOIN u ON u.k = 'x'"); bad(db, "join quote", c8);
    var c9 = sqlite::select_from("t", "a"); sqlite::group_by(c9, "a; b"); bad(db, "group_by semicolon", c9);
    var d1 = sqlite::delete_from("t"); sqlite::where(d1, "id", "=", 1); sqlite::returning(d1, "id -- x"); bad(db, "returning comment", d1);
    var e1 = sqlite::select_from("t", "a"); sqlite::where_raw(e1, "a = ?"); bad(db, "where_raw without arg", e1);
    var e2 = sqlite::select_from("t", "a"); sqlite::where_raw(e2, "a = ? AND b = ?"); sqlite::arg(e2, 1); bad(db, "where_raw one arg of two", e2);
    var e3 = sqlite::select_from("t", "a"); sqlite::where_raw(e3, "a = ?"); sqlite::where(e3, "b", "=", 1); sqlite::arg(e3, 1); bad(db, "arg after next clause", e3);
    var e4 = sqlite::select_from("t", "a"); sqlite::where_raw(e4, "a = 1"); sqlite::arg(e4, 1); bad(db, "extra arg", e4);
    var e5 = sqlite::select_from("t", "a"); sqlite::arg(e5, 1); bad(db, "arg with no where_raw", e5);
    var f1 = sqlite::select_from("t", "a");
    for i in 65 { sqlite::where(f1, "a", "=", i); }
    bad(db, "more than 64 values", f1);
    var many: i64[>..] = [];
    for i in 33 { many.push(i); }
    var f2 = sqlite::select_from("t", "a"); sqlite::where_in(f2, "a", many); bad(db, "where_in 33 values", f2);
    var f3 = sqlite::select_from("t", "a");
    sqlite::where_in(f3, "a", [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32]);
    sqlite::where_in(f3, "b", [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32]);
    sqlite::where(f3, "c", "=", 1);
    bad(db, "values over 64 across clauses", f3);
    var g1 = sqlite::select_from("t", "a"); sqlite::set(g1, "a", 1); bad(db, "set on select", g1);
    var g2 = sqlite::delete_from("t"); sqlite::set(g2, "a", 1); sqlite::all_rows(g2); bad(db, "set on delete", g2);
    var g3 = sqlite::insert_into("t"); sqlite::set(g3, "a", 1); sqlite::where(g3, "id", "=", 1); bad(db, "where on insert", g3);
    var g4 = sqlite::insert_into("t"); sqlite::where_raw(g4, "a = 1"); bad(db, "where_raw on insert", g4);
    var g5 = sqlite::update_table("t"); sqlite::set(g5, "a", 1); bad(db, "update without where", g5);
    var g6 = sqlite::delete_from("t"); bad(db, "delete without where", g6);
    var g7 = sqlite::insert_into("t"); bad(db, "insert without set", g7);
    var g8 = sqlite::update_table("t"); sqlite::where(g8, "id", "=", 1); bad(db, "update without set", g8);
    var g9 = sqlite::update_table("t"); sqlite::set(g9, "a", 1); sqlite::join(g9, "JOIN u ON 1"); sqlite::all_rows(g9); bad(db, "join on update", g9);
    var h1 = sqlite::select_from("t", "a"); sqlite::returning(h1, "a"); bad(db, "returning on select", h1);
    var h2 = sqlite::select_from("t", "a"); sqlite::limit(h2, -1); bad(db, "negative limit", h2);

    var first = sqlite::select_from("t", "a");
    sqlite::where(first, "a b", "=", 1);
    let msg = str(sqlite::query_error(first));
    sqlite::where(first, "c d", "=", 1);
    sqlite::set(first, "x", 1);
    check("first misuse is kept", sqlite::query_error(first) == msg);

    var fine = sqlite::select_from("t", "a");
    sqlite::where_raw(fine, "a = 1");
    check("where_raw without marks is fine", sqlite::query_error(fine) == "");
}

// The ids of every row, in order, as "1,3,"; the failure text when the query does not prepare.
fn ids(db: sqlite::Db, q: const sqlite::Query&) -> u8[>..] {
    var out: u8[>..] = [];
    let s = sqlite::prepare(db, q);
    if !sqlite::ok(s) { out.append("ERR "); out.append(sqlite::query_error(q)); out.append(sqlite::error(db)); return out; }
    while sqlite::step(s) { format(out, sqlite::int(s, 0)); out.append(","); }
    return out;
}

fn add_todo(db: sqlite::Db, title: const u8[:], done: bool, score: f64, no_score: bool) -> i64 {
    var q = sqlite::insert_into("todos");
    sqlite::set(q, "title", title);
    sqlite::set(q, "done", done);
    if no_score { sqlite::set_null(q, "score"); } else { sqlite::set(q, "score", score); }
    let id, good = sqlite::insert(sqlite::prepare(db, q));
    return if good { id } else { -1 };
}

fn test_round_trip(db: sqlite::Db) {
    check("create", sqlite::exec(db, "CREATE TABLE todos (id INTEGER PRIMARY KEY, title TEXT NOT NULL, done INTEGER NOT NULL, score REAL)"));
    check("insert 1", add_todo(db, "write", false, 1.5, false) == 1);
    check("insert 2", add_todo(db, "test", true, 2.5, false) == 2);
    check("insert 3", add_todo(db, "ship", false, 0.0, true) == 3);

    var w1 = sqlite::select_from("todos", "id"); sqlite::where(w1, "done", "=", false);
    check("where bool", ids(db, w1) == "1,3,");
    var w2 = sqlite::select_from("todos", "id"); sqlite::where(w2, "title", "=", "test");
    check("where text", ids(db, w2) == "2,");
    var w3 = sqlite::select_from("todos", "id"); sqlite::where(w3, "score", ">", 2.0);
    check("where float", ids(db, w3) == "2,");
    var w4 = sqlite::select_from("todos", "id"); sqlite::where(w4, "id", ">=", 2);
    check("where int", ids(db, w4) == "2,3,");
    var w5 = sqlite::select_from("todos", "id"); sqlite::where_null(w5, "score");
    check("where null", ids(db, w5) == "3,");
    var w6 = sqlite::select_from("todos", "id"); sqlite::where_not_null(w6, "score");
    check("where not null", ids(db, w6) == "1,2,");
    var w7 = sqlite::select_from("todos", "id"); sqlite::where_in(w7, "id", [1, 3]);
    check("where in int", ids(db, w7) == "1,3,");
    var w8 = sqlite::select_from("todos", "id"); sqlite::where_in(w8, "title", ["write", "ship"]);
    check("where in text", ids(db, w8) == "1,3,");
    var w9 = sqlite::select_from("todos", "id"); sqlite::where_in(w9, "id", [3, 3, 3]);
    check("where in padded", ids(db, w9) == "3,");
    var wa: i64[>..] = [];
    var w10 = sqlite::select_from("todos", "id"); sqlite::where_in(w10, "id", wa);
    check("where in empty", ids(db, w10) == "");
    var w11 = sqlite::select_from("todos", "id");
    sqlite::where_raw(w11, "title LIKE ? OR score > ?"); sqlite::arg(w11, "%t%"); sqlite::arg(w11, 2.0);
    check("where raw", ids(db, w11) == "1,2,");
    var w12 = sqlite::select_from("todos", "id");
    sqlite::where_raw(w12, "score IS ? OR id = ?"); sqlite::arg_null(w12); sqlite::arg(w12, 2);
    check("where raw null", ids(db, w12) == "2,3,");
    var w13 = sqlite::select_from("todos", "id");
    sqlite::where(w13, "done", "=", false); sqlite::where_raw(w13, "title LIKE ?"); sqlite::arg(w13, "s%"); sqlite::where(w13, "id", "<", 10);
    check("where mixed order", ids(db, w13) == "3,");
    var w14 = sqlite::select_from("todos", "id"); sqlite::where(w14, "title", "GLOB", "w*");
    check("where glob", ids(db, w14) == "1,");

    var p1 = sqlite::select_from("todos", "id"); sqlite::order_by(p1, "id", true);
    check("order desc", ids(db, p1) == "3,2,1,");
    var p2 = sqlite::select_from("todos", "id"); sqlite::order_by(p2, "id", true); sqlite::limit(p2, 2); sqlite::offset(p2, 1);
    check("limit offset", ids(db, p2) == "2,1,");
    var p3 = sqlite::select_from("todos", "id"); sqlite::order_by(p3, "id"); sqlite::offset(p3, 2);
    check("offset only", ids(db, p3) == "3,");

    var u1 = sqlite::update_table("todos");
    sqlite::where(u1, "id", "=", 2);
    sqlite::set(u1, "title", "tested"); sqlite::set(u1, "done", false);
    let n1, ok1 = sqlite::update(sqlite::prepare(db, u1));
    check("update one", ok1 && n1 == 1);
    var s1 = sqlite::select_from("todos", "id"); sqlite::where(s1, "title", "=", "tested"); sqlite::where(s1, "done", "=", false);
    check("update bound in order", ids(db, s1) == "2,");

    var u2 = sqlite::update_table("todos");
    sqlite::set(u2, "done", true);
    sqlite::all_rows(u2);
    let n2, ok2 = sqlite::update(sqlite::prepare(db, u2));
    check("update all rows", ok2 && n2 == 3);
    var s2 = sqlite::select_from("todos", "id"); sqlite::where(s2, "done", "=", true);
    check("all done", ids(db, s2) == "1,2,3,");

    var d1 = sqlite::delete_from("todos");
    sqlite::where(d1, "id", "=", 2);
    let n3, ok3 = sqlite::update(sqlite::prepare(db, d1));
    check("delete one", ok3 && n3 == 1);
    var s3 = sqlite::select_from("todos", "id");
    check("rows left", ids(db, s3) == "1,3,");

    var a = sqlite::select_from("todos", "id"); sqlite::where(a, "id", ">", 0);
    var b = sqlite::select_from("todos", "id"); sqlite::where(b, "id", ">", 99);
    let sa = sqlite::prepare(db, a);
    let sb = sqlite::prepare(db, b);
    check("equal queries share a stmt", sqlite::ok(sa) && sa.h == sb.h);
    var c = sqlite::select_from("todos", "id"); sqlite::where(c, "id", "<", 0);
    let raw = sqlite::prepare(db, "SELECT id FROM todos WHERE id > ?");
    check("builder uses the statement cache", sqlite::prepare(db, c).h != sa.h && raw.h == sa.h);
}

fn main() {
    let path = "test/q.db";
    fresh(path);
    let db = sqlite::open(path, sqlite::Mode.Create);
    check("open", sqlite::ok(db));
    test_text();
    test_where_in();
    test_misuse(db);
    test_round_trip(db);
    sqlite::close(db);
    fresh(path);
    print(if failed == 0 { "all query checks passed" } else { "query checks failed" });
    exit(if failed == 0 { 0 } else { 1 });
}
