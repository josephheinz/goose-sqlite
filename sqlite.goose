// sqlite: SQLite for Goose (DESIGN-ADDENDUM-2 in goose-web, question 3).
//
//   import sqlite from "../goose-sqlite";
//
//   let db = sqlite::local("data/shop.db");          // this thread's read-only connection
//   let s = sqlite::prepare(db, "SELECT name FROM products WHERE id = ?");
//   sqlite::bind(s, 1, 42);
//   if sqlite::step(s) { print(sqlite::text(s, 0)); sqlite::reset(s); }
//
// Text columns are copied out; nothing returned points into SQLite. A
// statement from prepare() comes back reset, and the same SQL text gives the
// same statement, so do not run one query again while iterating it.
// Links the system libsqlite3.

namespace sqlite;
import std;

struct Db { h: u64 }
struct Stmt { h: u64 }
enum Mode { ReadOnly, ReadWrite, Create }

extern fn c_open(path: const u8[:], mode: i32) -> u64 = "gsq_open";
extern fn c_local(path: const u8[:], mode: i32) -> u64 = "gsq_local";
extern fn c_error(h: u64, out: u8[>..]&) = "gsq_error";
extern fn c_exec(h: u64, sql: const u8[:]) -> i32 = "gsq_exec";
extern fn c_prepare(h: u64, sql: const u8[:]) -> u64 = "gsq_prepare";
extern fn c_bind_int(s: u64, i: i32, v: i64) -> i32 = "gsq_bind_int";
extern fn c_bind_f64(s: u64, i: i32, v: f64) -> i32 = "gsq_bind_f64";
extern fn c_bind_text(s: u64, i: i32, v: const u8[:]) -> i32 = "gsq_bind_text";
extern fn c_step(s: u64) -> i32 = "gsq_step";
extern fn c_reset(s: u64) = "gsq_reset";
extern fn c_int(s: u64, i: i32) -> i64 = "gsq_int";
extern fn c_f64(s: u64, i: i32) -> f64 = "gsq_f64";
extern fn c_text_len(s: u64, i: i32) -> i64 = "gsq_text_len";
extern fn c_text_copy(s: u64, i: i32, out: u8[>..]&) = "gsq_text_copy";
extern fn c_bind_null(s: u64, i: i32) -> i32 = "gsq_bind_null";
extern fn c_is_null(s: u64, i: i32) -> i32 = "gsq_is_null";
extern fn c_close(h: u64) = "gsq_close";
extern fn c_changes(h: u64) -> i64 = "gsq_changes";
extern fn c_last_id(h: u64) -> i64 = "gsq_last_id";

fn mode_code(m: Mode) -> i32 { match m { ReadOnly => 0, ReadWrite => 1, Create => 2 } }
fn open(path: const u8[:], mode: Mode = Mode.ReadOnly) -> Db { Db { h: c_open(path, mode_code(mode)) } }
fn local(path: const u8[:], mode: Mode = Mode.ReadOnly) -> Db { Db { h: c_local(path, mode_code(mode)) } }
fn ok(db: Db) -> bool { db.h != 0 }
fn ok(s: Stmt) -> bool { s.h != 0 }
fn error(db: Db) -> u8[>..] { var out: u8[>..] = []; c_error(db.h, out); return out; }
fn exec(db: Db, sql: const u8[:]) -> bool { c_exec(db.h, sql) != 0 }
fn prepare(db: Db, sql: const u8[:]) -> Stmt { Stmt { h: c_prepare(db.h, sql) } }
fn bind(s: Stmt, i: i64, v: i64) -> bool { c_bind_int(s.h, i as i32, v) != 0 }
fn bind(s: Stmt, i: i64, v: f64) -> bool { c_bind_f64(s.h, i as i32, v) != 0 }
fn bind(s: Stmt, i: i64, v: const u8[:]) -> bool { c_bind_text(s.h, i as i32, v) != 0 }
fn step(s: Stmt) -> bool { c_step(s.h) == 1 }
fn reset(s: Stmt) { c_reset(s.h); }
fn int(s: Stmt, col: i64) -> i64 { c_int(s.h, col as i32) }
fn float(s: Stmt, col: i64) -> f64 { c_f64(s.h, col as i32) }
fn text(s: Stmt, col: i64) -> u8[>..] { var out: u8[>..] = []; c_text_copy(s.h, col as i32, out); return out; }
fn text_len(s: Stmt, col: i64) -> i64 { c_text_len(s.h, col as i32) }
fn text(s: Stmt, col: i64, out: u8[>..]&) { c_text_copy(s.h, col as i32, out); }
fn bind_null(s: Stmt, i: i64) -> bool { c_bind_null(s.h, i as i32) != 0 }
fn is_null(s: Stmt, col: i64) -> bool { c_is_null(s.h, col as i32) != 0 }
fn close(db: Db) { c_close(db.h); }
fn changes(db: Db) -> i64 { c_changes(db.h) }
fn last_insert_id(db: Db) -> i64 { c_last_id(db.h) }
