/* goose-sqlite: SQLite for Goose. local() keeps one connection per thread per path and mode.
   Connections use SQLITE_OPEN_NOMUTEX: use each one from one thread only. */
#include "goose.h"
#include <sqlite3.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>

typedef struct { const uint8_t *data; int64_t len; } gsq_bytes;
typedef struct gsq_stmt { sqlite3_stmt *st; const char *sql; int64_t len; struct gsq_stmt *next; } gsq_stmt;
typedef struct gsq_db { sqlite3 *db; char *path; int mode; gsq_stmt *stmts; struct gsq_db *next; } gsq_db;

#define GSQ_WRITER 4

typedef struct gsq_claim { char *path; pthread_t owner; struct gsq_claim *next; } gsq_claim;

static pthread_mutex_t claims_lock = PTHREAD_MUTEX_INITIALIZER;
static gsq_claim *claims;
static __thread gsq_db *local_dbs;
static __thread char open_error[256];

uint64_t gsq_open(gsq_bytes path, int32_t mode) {
    char *p = malloc((size_t)path.len + 1);
    memcpy(p, path.data, (size_t)path.len); p[path.len] = 0;
    int flags = mode == 0 ? SQLITE_OPEN_READONLY : (mode == 1 || mode == 3) ? SQLITE_OPEN_READWRITE : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE;
    sqlite3 *db = NULL;
    if (sqlite3_open_v2(p, &db, flags | SQLITE_OPEN_NOMUTEX, NULL) != SQLITE_OK) {
        strlcpy(open_error, db ? sqlite3_errmsg(db) : "out of memory", sizeof open_error);
        sqlite3_close(db); free(p); return 0;
    }
    sqlite3_busy_timeout(db, 2000);
    if (mode == 3 && sqlite3_exec(db, "PRAGMA query_only=1", NULL, NULL, NULL) != SQLITE_OK) {
        strlcpy(open_error, sqlite3_errmsg(db), sizeof open_error);
        sqlite3_close(db); free(p); return 0;
    }
    gsq_db *d = calloc(1, sizeof *d);
    d->db = db; d->path = p; d->mode = mode;
    return (uint64_t)(uintptr_t)d;
}
uint64_t gsq_local(gsq_bytes path, int32_t mode) {
    for (gsq_db *d = local_dbs; d; d = d->next)
        if (d->mode == mode && strlen(d->path) == (size_t)path.len && memcmp(d->path, path.data, (size_t)path.len) == 0) return (uint64_t)(uintptr_t)d;
    gsq_db *d = (gsq_db *)(uintptr_t)gsq_open(path, mode);
    if (!d) return 0;
    d->next = local_dbs; local_dbs = d;
    return (uint64_t)(uintptr_t)d;
}
void gsq_error(uint64_t h, gs_rref out) {
    gsq_db *d = (gsq_db *)(uintptr_t)h;
    const char *m = d ? sqlite3_errmsg(d->db) : open_error;
    gs_bld_append(out, m, strlen(m));
}
int32_t gsq_exec(uint64_t h, gsq_bytes sql) {
    gsq_db *d = (gsq_db *)(uintptr_t)h;
    if (!d) return 0;
    char *z = malloc((size_t)sql.len + 1); memcpy(z, sql.data, (size_t)sql.len); z[sql.len] = 0;
    int rc = sqlite3_exec(d->db, z, NULL, NULL, NULL); free(z);
    return rc == SQLITE_OK;
}
/* Cached by the SQL text's address and length first (a literal is the same pointer every call), then by content. */
uint64_t gsq_prepare(uint64_t h, gsq_bytes sql) {
    gsq_db *d = (gsq_db *)(uintptr_t)h;
    if (!d) return 0;
    gsq_stmt *s;
    for (s = d->stmts; s; s = s->next)
        if (s->len == sql.len && (s->sql == (const char *)sql.data || memcmp(s->sql, sql.data, (size_t)sql.len) == 0)) {
            sqlite3_reset(s->st); return (uint64_t)(uintptr_t)s;
        }
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v3(d->db, (const char *)sql.data, (int)sql.len, SQLITE_PREPARE_PERSISTENT, &st, NULL) != SQLITE_OK || !st) return 0;
    s = calloc(1, sizeof *s);
    char *copy = malloc((size_t)sql.len); memcpy(copy, sql.data, (size_t)sql.len);
    s->st = st; s->sql = copy; s->len = sql.len; s->next = d->stmts; d->stmts = s;
    return (uint64_t)(uintptr_t)s;
}
#define ST(h) (((gsq_stmt *)(uintptr_t)(h))->st)
/* Every call accepts the 0 handle of a failed prepare and does nothing. */
int32_t gsq_bind_int(uint64_t s, int32_t i, int64_t v) { return s && sqlite3_bind_int64(ST(s), i, v) == SQLITE_OK; }
int32_t gsq_bind_f64(uint64_t s, int32_t i, double v) { return s && sqlite3_bind_double(ST(s), i, v) == SQLITE_OK; }
int32_t gsq_bind_text(uint64_t s, int32_t i, gsq_bytes v) { return s && sqlite3_bind_text(ST(s), i, (const char *)v.data, (int)v.len, SQLITE_TRANSIENT) == SQLITE_OK; }
int32_t gsq_bind_null(uint64_t s, int32_t i) { return s && sqlite3_bind_null(ST(s), i) == SQLITE_OK; }
int32_t gsq_step(uint64_t s) {
    if (!s) return -1;
    int rc = sqlite3_step(ST(s));
    if (rc == SQLITE_ROW) return 1;
    sqlite3_reset(ST(s));
    return rc == SQLITE_DONE ? 0 : -1;
}
void gsq_reset(uint64_t s) { if (s) sqlite3_reset(ST(s)); }
int64_t gsq_int(uint64_t s, int32_t i) { return s ? sqlite3_column_int64(ST(s), i) : 0; }
double gsq_f64(uint64_t s, int32_t i) { return s ? sqlite3_column_double(ST(s), i) : 0; }
int32_t gsq_is_null(uint64_t s, int32_t i) { return !s || sqlite3_column_type(ST(s), i) == SQLITE_NULL; }
int64_t gsq_text_len(uint64_t s, int32_t i) { return s ? sqlite3_column_bytes(ST(s), i) : 0; }
/* sqlite3_column_text must run before sqlite3_column_bytes (SQLite docs). */
void gsq_text_copy(uint64_t s, int32_t i, gs_rref out) {
    if (!s) return;
    const unsigned char *t = sqlite3_column_text(ST(s), i);
    int n = sqlite3_column_bytes(ST(s), i);
    if (t && n > 0) gs_bld_append(out, t, (size_t)n);
}
static void claim_drop(const char *path) {
    pthread_mutex_lock(&claims_lock);
    for (gsq_claim **pp = &claims; *pp; pp = &(*pp)->next)
        if (strcmp((*pp)->path, path) == 0) { gsq_claim *c = *pp; *pp = c->next; free(c->path); free(c); break; }
    pthread_mutex_unlock(&claims_lock);
}
/* Closes a connection from gsq_open (or a thread-local one, which is then forgotten). */
void gsq_close(uint64_t h) {
    gsq_db *d = (gsq_db *)(uintptr_t)h;
    if (!d) return;
    if (d->mode == GSQ_WRITER) claim_drop(d->path);
    for (gsq_db **pp = &local_dbs; *pp; pp = &(*pp)->next) if (*pp == d) { *pp = d->next; break; }
    for (gsq_stmt *s = d->stmts, *n; s; s = n) { n = s->next; sqlite3_finalize(s->st); free((void *)s->sql); free(s); }
    sqlite3_close(d->db);
    free(d->path);
    free(d);
}
int64_t gsq_changes(uint64_t h) { return h ? sqlite3_changes64(((gsq_db *)(uintptr_t)h)->db) : 0; }
int64_t gsq_last_id(uint64_t h) { return h ? sqlite3_last_insert_rowid(((gsq_db *)(uintptr_t)h)->db) : 0; }
int32_t gsq_run(uint64_t s) {
    if (!s) return 0;
    int rc;
    while ((rc = sqlite3_step(ST(s))) == SQLITE_ROW) {}
    sqlite3_reset(ST(s));
    return rc == SQLITE_DONE;
}
int64_t gsq_stmt_last_id(uint64_t s) { return s ? sqlite3_last_insert_rowid(sqlite3_db_handle(ST(s))) : 0; }
int64_t gsq_stmt_changes(uint64_t s) { return s ? sqlite3_changes64(sqlite3_db_handle(ST(s))) : 0; }
/* The extended code of the last failure; sqlite3_reset in gsq_run keeps it. */
int32_t gsq_code(uint64_t h) { return h ? sqlite3_extended_errcode(((gsq_db *)(uintptr_t)h)->db) : 0; }
void gsq_busy_timeout(uint64_t h, int32_t ms) { if (h) sqlite3_busy_timeout(((gsq_db *)(uintptr_t)h)->db, ms); }
#define DB(h) (((gsq_db *)(uintptr_t)(h))->db)
int32_t gsq_begin(uint64_t h) { return h && sqlite3_exec(DB(h), "BEGIN IMMEDIATE", NULL, NULL, NULL) == SQLITE_OK; }
int32_t gsq_commit(uint64_t h) { return h && sqlite3_exec(DB(h), "COMMIT", NULL, NULL, NULL) == SQLITE_OK; }
/* Only when a transaction is open, so a rollback after a failed BEGIN or a finished commit leaves the error state alone. */
void gsq_rollback(uint64_t h) { if (h && !sqlite3_get_autocommit(DB(h))) sqlite3_exec(DB(h), "ROLLBACK", NULL, NULL, NULL); }
/* Claimed by the path text as given: "data/a.db" and "./data/a.db" are two claims. */
static int claim_take(char *p) {
    int taken = 1;
    pthread_mutex_lock(&claims_lock);
    for (gsq_claim *c = claims; c; c = c->next)
        if (strcmp(c->path, p) == 0) { taken = 0; break; }
    if (taken) {
        gsq_claim *c = malloc(sizeof *c);
        c->path = strdup(p); c->owner = pthread_self(); c->next = claims; claims = c;
    }
    pthread_mutex_unlock(&claims_lock);
    return taken;
}
static int pragma_text_is(sqlite3 *db, const char *sql, const char *want) {
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(db, sql, -1, &st, NULL) != SQLITE_OK) return 0;
    const unsigned char *t = sqlite3_step(st) == SQLITE_ROW ? sqlite3_column_text(st, 0) : NULL;
    int same = t && strcmp((const char *)t, want) == 0;
    sqlite3_finalize(st);
    return same;
}
uint64_t gsq_writer(gsq_bytes path, int32_t durable) {
    for (gsq_db *d = local_dbs; d; d = d->next)
        if (d->mode == GSQ_WRITER && strlen(d->path) == (size_t)path.len && memcmp(d->path, path.data, (size_t)path.len) == 0) return (uint64_t)(uintptr_t)d;
    char *p = malloc((size_t)path.len + 1);
    memcpy(p, path.data, (size_t)path.len); p[path.len] = 0;
    if (!claim_take(p)) {
        snprintf(open_error, sizeof open_error, "another thread is the writer for %s", p);
        free(p); return 0;
    }
    gsq_db *d = (gsq_db *)(uintptr_t)gsq_open(path, GSQ_WRITER);
    if (!d) { claim_drop(p); free(p); return 0; }
    free(p);
    sqlite3_busy_timeout(d->db, 1000);
    const char *sync = durable ? "PRAGMA synchronous=FULL" : "PRAGMA synchronous=NORMAL";
    if (!pragma_text_is(d->db, "PRAGMA journal_mode=WAL", "wal")) strlcpy(open_error, "cannot enable WAL", sizeof open_error);
    else if (sqlite3_exec(d->db, sync, NULL, NULL, NULL) != SQLITE_OK || (durable && sqlite3_exec(d->db, "PRAGMA fullfsync=1", NULL, NULL, NULL) != SQLITE_OK))
        strlcpy(open_error, sqlite3_errmsg(d->db), sizeof open_error);
    else { d->next = local_dbs; local_dbs = d; return (uint64_t)(uintptr_t)d; }
    gsq_close((uint64_t)(uintptr_t)d);
    return 0;
}
