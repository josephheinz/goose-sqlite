// Part of goose-sqlite. Import with `import sqlite.query;`.
// Builds SQL with ? placeholders and a list of bound values; prepare(db, q) prepares it through the statement cache and binds them.
// Misuse sets query_error and makes prepare fail; it never aborts.

namespace sqlite;

import std;
import sqlite;

enum Kind { Select, Insert, Update, Delete }

// One growable field, last, so a Query is never an array element. Values are tagged by section (0 set, 1 where) and kind (0 int, 1 float, 2 text, 3 null).
struct Query {
    kind: Kind, error: u8[..256], all: bool = false, pending: i64 = 0,
    table: u8[..64], cols: u8[..1024], sets: u8[..2048], joins: u8[..1024], wheres: u8[..2048],
    group: u8[..256], order: u8[..256], ret: u8[..256], lim: i64 = -1, off: i64 = 0,
    n: i64 = 0, section: i64[64], kinds: i64[64], ints: i64[64], floats: f64[64],
    text_at: i64[64], text_len: i64[64],
    texts: u8[>..]
}

fn kind_code(k: Kind) -> i64 { match k { Select => 0, Insert => 1, Update => 2, Delete => 3 } }

// ---------------------------------------------------------------- checks

fn ident_start(c: u8) -> bool { (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' }
fn ident_rest(c: u8) -> bool { ident_start(c) || (c >= '0' && c <= '9') }

// [A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)?
fn ident_ok(s: const u8[:]) -> bool {
    var at_start = true;
    var dots = 0;
    for i in 0..s.len {
        let c = s[i];
        if c == '.' {
            if at_start || dots > 0 { return false; }
            dots += 1;
            at_start = true;
        } else if at_start {
            if !ident_start(c) { return false; }
            at_start = false;
        } else if !ident_rest(c) { return false; }
    }
    return !at_start;
}

fn op_ok(op: const u8[:]) -> bool {
    op == "=" || op == "!=" || op == "<>" || op == "<" || op == "<=" || op == ">" || op == ">=" || op == "LIKE" || op == "GLOB"
}

// No quotes, ';', comments or NUL, so a '?' is never inside a literal; '?' only where allowed. 39 is the single quote.
fn raw_ok(s: const u8[:], allow_mark: bool) -> bool {
    if s.len == 0 { return false; }
    for i in 0..s.len {
        let c = s[i];
        if c == 39 || c == '"' || c == ';' || c == 0 { return false; }
        if c == '?' && !allow_mark { return false; }
        if i + 1 < s.len {
            let d = s[i + 1];
            if (c == '-' && d == '-') || (c == '/' && d == '*') { return false; }
        }
    }
    return true;
}

fn marks(s: const u8[:]) -> i64 {
    var n = 0;
    for i in 0..s.len { if s[i] == '?' { n += 1; } }
    return n;
}

// ---------------------------------------------------------------- errors

fn fail(q: Query&, msg: const u8[:]) {
    if q.error.len == 0 { q.error.append(msg); }
}

// The offending text is cut to 64 bytes so the message always fits.
fn fail_with(q: Query&, msg: const u8[:], s: const u8[:]) {
    if q.error.len > 0 { return; }
    q.error.append(msg);
    q.error.append(s[0..min(s.len, 64)]);
}

// False once the query is broken, or when a where_raw still lacks arg calls (which is then a misuse).
fn start(q: Query&) -> bool {
    if q.error.len > 0 { return false; }
    if q.pending != 0 { fail(q, "where_raw: ? count not met by arg calls"); return false; }
    return true;
}

// Checks that depend on the whole query, so they run at sql_text and prepare, not on the call that made the query incomplete.
fn final_error(q: const Query&) -> const u8[:] {
    if q.error.len > 0 { return q.error; }
    if q.pending != 0 { return "where_raw: ? count not met by arg calls"; }
    let k = kind_code(q.kind);
    if k == 1 && q.sets.len == 0 { return "INSERT without set"; }
    if k == 2 && q.sets.len == 0 { return "UPDATE without set"; }
    if (k == 2 || k == 3) && q.wheres.len == 0 && !q.all { return "UPDATE or DELETE without where; use all_rows to touch every row"; }
    return "";
}

fn query_error(q: const Query&) -> const u8[:] { final_error(q) }

// ---------------------------------------------------------------- values

fn push_slot(q: Query&, section: i64, kind: i64) -> i64 {
    if q.n >= 64 { fail(q, "more than 64 values"); return -1; }
    let i = q.n;
    q.n += 1;
    q.section[i] = section;
    q.kinds[i] = kind;
    return i;
}

fn push_int(q: Query&, section: i64, v: i64) {
    let i = push_slot(q, section, 0);
    if i >= 0 { q.ints[i] = v; }
}

fn push_float(q: Query&, section: i64, v: f64) {
    let i = push_slot(q, section, 1);
    if i >= 0 { q.floats[i] = v; }
}

fn push_text(q: Query&, section: i64, v: const u8[:]) {
    let i = push_slot(q, section, 2);
    if i >= 0 {
        q.text_at[i] = q.texts.len;
        q.text_len[i] = v.len;
        q.texts.append(v);
    }
}

fn push_null(q: Query&, section: i64) {
    push_slot(q, section, 3);
}

// ---------------------------------------------------------------- constructors

fn new_query(kind: Kind, table: const u8[:]) -> Query {
    var q = Query { kind: kind, error: "", table: "", cols: "", sets: "", joins: "", wheres: "", group: "", order: "", ret: "",
                    section: [0; 64], kinds: [0; 64], ints: [0; 64], floats: [0.0; 64], text_at: [0; 64], text_len: [0; 64], texts: [] };
    if !ident_ok(table) { fail_with(q, "bad table name: ", table); }
    else if table.len > 64 { fail(q, "query too long: table"); }
    else { q.table.append(table); }
    return q;
}

fn select_from(table: const u8[:], cols: const u8[:]) -> Query {
    var q = new_query(Kind.Select, table);
    if q.error.len == 0 {
        if !raw_ok(cols, false) { fail_with(q, "bad column list: ", cols); }
        else if cols.len > 1024 { fail(q, "query too long: columns"); }
        else { q.cols.append(cols); }
    }
    return q;
}

fn insert_into(table: const u8[:]) -> Query { new_query(Kind.Insert, table) }
fn update_table(table: const u8[:]) -> Query { new_query(Kind.Update, table) }
fn delete_from(table: const u8[:]) -> Query { new_query(Kind.Delete, table) }

// ---------------------------------------------------------------- where

// AND joins every clause; a clause that does not fit is a misuse, never cut.
fn add_where(q: Query&, clause: const u8[:]) {
    let sep = if q.wheres.len > 0 { 5 } else { 0 };
    if q.wheres.len + sep + clause.len > 2048 { fail(q, "query too long: where"); return; }
    if sep > 0 { q.wheres.append(" AND "); }
    q.wheres.append(clause);
}

fn where_col(q: Query&, col: const u8[:]) -> bool {
    if !start(q) { return false; }
    if kind_code(q.kind) == 1 { fail(q, "where on INSERT"); return false; }
    if !ident_ok(col) { fail_with(q, "bad column name: ", col); return false; }
    return true;
}

fn where_op(q: Query&, col: const u8[:], op: const u8[:]) -> bool {
    if !where_col(q, col) { return false; }
    if !op_ok(op) { fail_with(q, "bad operator: ", op); return false; }
    add_where(q, str(col, " ", op, " ?"));
    return q.error.len == 0;
}

fn where(q: Query&, col: const u8[:], op: const u8[:], v: i64) { if where_op(q, col, op) { push_int(q, 1, v); } }
fn where(q: Query&, col: const u8[:], op: const u8[:], v: f64) { if where_op(q, col, op) { push_float(q, 1, v); } }
fn where(q: Query&, col: const u8[:], op: const u8[:], v: bool) { if where_op(q, col, op) { push_int(q, 1, if v { 1 } else { 0 }); } }
fn where(q: Query&, col: const u8[:], op: const u8[:], v: const u8[:]) { if where_op(q, col, op) { push_text(q, 1, v); } }

fn where_null(q: Query&, col: const u8[:]) { if where_col(q, col) { add_where(q, str(col, " IS NULL")); } }
fn where_not_null(q: Query&, col: const u8[:]) { if where_col(q, col) { add_where(q, str(col, " IS NOT NULL")); } }

// 1, 2, 4, ... 32.
fn pad_count(k: i64) -> i64 {
    var p = 1;
    while p < k { p *= 2; }
    return p;
}

// Writes the IN clause padded to a power of two; false when no value should be pushed.
fn in_open(q: Query&, col: const u8[:], k: i64) -> bool {
    if !where_col(q, col) { return false; }
    if k > 32 { fail(q, "where_in: more than 32 values"); return false; }
    if k == 0 { add_where(q, "0 = 1"); return false; }
    let p = pad_count(k);
    if q.n + p > 64 { fail(q, "more than 64 values"); return false; }
    var c: u8[>..] = str(col, " IN (");
    for j in 0..p {
        if j > 0 { c.append(", "); }
        c.append("?");
    }
    c.append(")");
    add_where(q, c);
    return q.error.len == 0;
}

// The padding repeats the last value, so the statement cache holds at most 6 texts per IN query.
fn where_in(q: Query&, col: const u8[:], vs: const i64[:]) {
    if !in_open(q, col, vs.len) { return; }
    for j in 0..pad_count(vs.len) {
        var at = j;
        if at >= vs.len { at = vs.len - 1; }
        push_int(q, 1, vs[at]);
    }
}

fn where_in(q: Query&, col: const u8[:], vs: const u8[:][:]) {
    if !in_open(q, col, vs.len) { return; }
    for j in 0..pad_count(vs.len) {
        var at = j;
        if at >= vs.len { at = vs.len - 1; }
        push_text(q, 1, vs[at]);
    }
}

// cond is wrapped in parentheses; its ? placeholders are filled by arg() calls, in order, before the next clause.
fn where_raw(q: Query&, cond: const u8[:]) {
    if !start(q) { return; }
    if kind_code(q.kind) == 1 { fail(q, "where on INSERT"); return; }
    if !raw_ok(cond, true) { fail_with(q, "bad where_raw text: ", cond); return; }
    add_where(q, str("(", cond, ")"));
    if q.error.len == 0 { q.pending = marks(cond); }
}

fn arg_slot(q: Query&) -> bool {
    if q.error.len > 0 { return false; }
    if q.pending <= 0 { fail(q, "arg without a ? left in where_raw"); return false; }
    q.pending -= 1;
    return true;
}

fn arg(q: Query&, v: i64) { if arg_slot(q) { push_int(q, 1, v); } }
fn arg(q: Query&, v: f64) { if arg_slot(q) { push_float(q, 1, v); } }
fn arg(q: Query&, v: bool) { if arg_slot(q) { push_int(q, 1, if v { 1 } else { 0 }); } }
fn arg(q: Query&, v: const u8[:]) { if arg_slot(q) { push_text(q, 1, v); } }
fn arg_null(q: Query&) { if arg_slot(q) { push_null(q, 1); } }

// ---------------------------------------------------------------- select clauses

fn select_only(q: Query&, what: const u8[:]) -> bool {
    if !start(q) { return false; }
    if kind_code(q.kind) != 0 { fail_with(q, "only a SELECT takes ", what); return false; }
    return true;
}

fn join(q: Query&, clause: const u8[:]) {
    if !select_only(q, "join") { return; }
    if !raw_ok(clause, false) { fail_with(q, "bad join text: ", clause); return; }
    let sep = if q.joins.len > 0 { 1 } else { 0 };
    if q.joins.len + sep + clause.len > 1024 { fail(q, "query too long: join"); return; }
    if sep > 0 { q.joins.append(" "); }
    q.joins.append(clause);
}

fn group_by(q: Query&, cols: const u8[:]) {
    if !select_only(q, "group_by") { return; }
    if !raw_ok(cols, false) { fail_with(q, "bad group_by text: ", cols); return; }
    let sep = if q.group.len > 0 { 2 } else { 0 };
    if q.group.len + sep + cols.len > 256 { fail(q, "query too long: group by"); return; }
    if sep > 0 { q.group.append(", "); }
    q.group.append(cols);
}

fn order_by(q: Query&, col: const u8[:], desc: bool = false) {
    if !select_only(q, "order_by") { return; }
    if !ident_ok(col) { fail_with(q, "bad column name: ", col); return; }
    let sep = if q.order.len > 0 { 2 } else { 0 };
    let tail = if desc { 5 } else { 0 };
    if q.order.len + sep + col.len + tail > 256 { fail(q, "query too long: order by"); return; }
    if sep > 0 { q.order.append(", "); }
    q.order.append(col);
    if desc { q.order.append(" DESC"); }
}

// LIMIT ? OFFSET ? is emitted whenever a limit or a positive offset is set, so every page shares one SQL text.
fn limit(q: Query&, n: i64) {
    if !select_only(q, "limit") { return; }
    if n < 0 { fail(q, "negative limit"); return; }
    q.lim = n;
}

fn offset(q: Query&, n: i64) {
    if !select_only(q, "offset") { return; }
    if n < 0 { fail(q, "negative offset"); return; }
    q.off = n;
}

// ---------------------------------------------------------------- writes

fn set_col(q: Query&, col: const u8[:]) -> bool {
    if !start(q) { return false; }
    let k = kind_code(q.kind);
    if k != 1 && k != 2 { fail(q, "set on a SELECT or DELETE"); return false; }
    if !ident_ok(col) { fail_with(q, "bad column name: ", col); return false; }
    let sep = if q.sets.len > 0 { 1 } else { 0 };
    if q.sets.len + sep + col.len > 2048 { fail(q, "query too long: set"); return false; }
    if sep > 0 { q.sets.append(","); }
    q.sets.append(col);
    return true;
}

// Column names are kept comma-separated; sql_text writes them as `a, b` or `a = ?, b = ?`.
fn set(q: Query&, col: const u8[:], v: i64) { if set_col(q, col) { push_int(q, 0, v); } }
fn set(q: Query&, col: const u8[:], v: f64) { if set_col(q, col) { push_float(q, 0, v); } }
fn set(q: Query&, col: const u8[:], v: bool) { if set_col(q, col) { push_int(q, 0, if v { 1 } else { 0 }); } }
fn set(q: Query&, col: const u8[:], v: const u8[:]) { if set_col(q, col) { push_text(q, 0, v); } }
fn set_null(q: Query&, col: const u8[:]) { if set_col(q, col) { push_null(q, 0); } }

fn returning(q: Query&, cols: const u8[:]) {
    if !start(q) { return; }
    if kind_code(q.kind) == 0 { fail(q, "returning on a SELECT"); return; }
    if !raw_ok(cols, false) { fail_with(q, "bad returning text: ", cols); return; }
    let sep = if q.ret.len > 0 { 2 } else { 0 };
    if q.ret.len + sep + cols.len > 256 { fail(q, "query too long: returning"); return; }
    if sep > 0 { q.ret.append(", "); }
    q.ret.append(cols);
}

// Allows an UPDATE or DELETE with no where clause.
fn all_rows(q: Query&) {
    if start(q) { q.all = true; }
}

// ---------------------------------------------------------------- output

fn paged(q: const Query&) -> bool { q.lim >= 0 || q.off > 0 }

// The SQL appended to out; false, with out untouched, when the query is not usable.
fn sql_text(q: const Query&, out: u8[>..]&) -> bool {
    if final_error(q).len > 0 { return false; }
    let k = kind_code(q.kind);
    if k == 0 {
        out.append("SELECT "); out.append(q.cols); out.append(" FROM "); out.append(q.table);
        if q.joins.len > 0 { out.append(" "); out.append(q.joins); }
    } else if k == 1 {
        out.append("INSERT INTO "); out.append(q.table); out.append(" (");
        var count = 1;
        for i in 0..q.sets.len {
            if q.sets[i] == ',' { out.append(", "); count += 1; } else { out.push(q.sets[i]); }
        }
        out.append(") VALUES (");
        for i in 0..count { if i > 0 { out.append(", "); } out.append("?"); }
        out.append(")");
    } else if k == 2 {
        out.append("UPDATE "); out.append(q.table); out.append(" SET ");
        var start_at = 0;
        for i in 0..(q.sets.len + 1) {
            if i == q.sets.len || q.sets[i] == ',' {
                if start_at > 0 { out.append(", "); }
                out.append(q.sets[start_at..i]); out.append(" = ?");
                start_at = i + 1;
            }
        }
    } else {
        out.append("DELETE FROM "); out.append(q.table);
    }
    if q.wheres.len > 0 { out.append(" WHERE "); out.append(q.wheres); }
    if k == 0 {
        if q.group.len > 0 { out.append(" GROUP BY "); out.append(q.group); }
        if q.order.len > 0 { out.append(" ORDER BY "); out.append(q.order); }
        if paged(q) { out.append(" LIMIT ? OFFSET ?"); }
    } else if q.ret.len > 0 {
        out.append(" RETURNING "); out.append(q.ret);
    }
    return true;
}

fn bind_value(s: Stmt, at: i64, q: const Query&, k: i64) -> bool {
    let kind = q.kinds[k];
    if kind == 0 { return bind(s, at, q.ints[k]); }
    if kind == 1 { return bind(s, at, q.floats[k]); }
    if kind == 2 {
        let from = q.text_at[k];
        return bind(s, at, q.texts[from..from + q.text_len[k]]);
    }
    return bind_null(s, at);
}

// Binds set values, then where values, each in call order, then limit and offset. A failed Stmt means query_error or error(db) says why.
fn prepare(db: Db, q: const Query&) -> Stmt {
    var sql: u8[>..] = [];
    if !sql_text(q, sql) { return Stmt { h: 0 }; }
    let s = prepare(db, sql);
    if !ok(s) { return s; }
    var at = 1;
    for section in 0..2 {
        for k in 0..q.n {
            if q.section[k] == section {
                if !bind_value(s, at, q, k) { return Stmt { h: 0 }; }
                at += 1;
            }
        }
    }
    if paged(q) {
        if !bind(s, at, q.lim) || !bind(s, at + 1, q.off) { return Stmt { h: 0 }; }
    }
    return s;
}
