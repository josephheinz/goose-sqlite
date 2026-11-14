/* goose-sqlite: SQLite for Goose. local() keeps one connection per thread per path and mode.
   Connections use SQLITE_OPEN_NOMUTEX: use each one from one thread only. */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE   /* clock_gettime and CLOCK_MONOTONIC under glibc's strict modes */
#endif
#include "goose.h"
#include <sqlite3.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <time.h>

typedef struct { const uint8_t *data; int64_t len; } gsq_bytes;
struct gsq_db;
/* deadline: when this statement's time limit ends, set at its first step (0: none). */
typedef struct gsq_stmt { sqlite3_stmt *st; const char *sql; int64_t len; struct gsq_stmt *next; struct gsq_db *owner; int64_t deadline; } gsq_stmt;
/* limit_ms: time_limit's value (0: none). deadline: the running statement's end, read by the progress handler.
   interrupted: the handler stopped the last statement that started. */
typedef struct gsq_db { sqlite3 *db; char *path; int mode; gsq_stmt *stmts; struct gsq_db *next;
                        int64_t limit_ms; int64_t deadline; int interrupted; } gsq_db;

#define GSQ_WRITER 4

typedef struct gsq_claim { char *path; pthread_t owner; struct gsq_claim *next; } gsq_claim;

static pthread_mutex_t claims_lock = PTHREAD_MUTEX_INITIALIZER;
static gsq_claim *claims;
typedef struct { gsq_db *head; } gsq_holder;

static __thread gsq_holder *tl_holder;
static __thread char open_error[256];
static pthread_once_t holder_once = PTHREAD_ONCE_INIT;
static pthread_key_t holder_key;

static void claim_drop(const char *path) {
    pthread_mutex_lock(&claims_lock);
    for (gsq_claim **pp = &claims; *pp; pp = &(*pp)->next)
        if (strcmp((*pp)->path, path) == 0) { gsq_claim *c = *pp; *pp = c->next; free(c->path); free(c); break; }
    pthread_mutex_unlock(&claims_lock);
}
static void gsq_free_db(gsq_db *d) {
    if (d->mode == GSQ_WRITER) claim_drop(d->path);
    for (gsq_stmt *s = d->stmts, *n; s; s = n) { n = s->next; sqlite3_finalize(s->st); free((void *)s->sql); free(s); }
    sqlite3_close(d->db);
    free(d->path);
    free(d);
}
/* A Goose thread that ends or aborts never calls gsq_close; without this its cached connections would keep their locks until the process exits. */
static void holder_destroy(void *p) {
    gsq_holder *h = p;
    for (gsq_db *d = h->head, *n; d; d = n) { n = d->next; gsq_free_db(d); }
    free(h);
}
static void holder_key_init(void) { pthread_key_create(&holder_key, holder_destroy); }
static gsq_holder *holder_get(void) {
    if (tl_holder) return tl_holder;
    gsq_holder *h = calloc(1, sizeof *h);
    pthread_once(&holder_once, holder_key_init);
    pthread_setspecific(holder_key, h);
    tl_holder = h;
    return h;
}

/* ---- time limits (time_limit): a progress handler checks the clock every 1,000 VM steps. */
static int64_t gsq_now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}
static int gsq_progress(void *p) {
    gsq_db *d = p;
    if (d->deadline == 0 || gsq_now_ms() < d->deadline) return 0;
    d->interrupted = 1;
    return 1;
}
/* A statement that has not stepped yet starts its time now; every step runs under that statement's own deadline. */
static void gsq_arm(gsq_stmt *s) {
    gsq_db *d = s->owner;
    if (!d) return;
    if (!sqlite3_stmt_busy(s->st)) {
        d->interrupted = 0;
        s->deadline = d->limit_ms > 0 ? gsq_now_ms() + d->limit_ms : 0;
    }
    d->deadline = s->deadline;
}
void gsq_time_limit(uint64_t h, int64_t ms) {
    gsq_db *d = (gsq_db *)(uintptr_t)h;
    if (!d) return;
    d->limit_ms = ms > 0 ? ms : 0;
    d->deadline = 0;
    sqlite3_progress_handler(d->db, d->limit_ms > 0 ? 1000 : 0, d->limit_ms > 0 ? gsq_progress : NULL, d);
}
int32_t gsq_interrupted(uint64_t h) { return h && ((gsq_db *)(uintptr_t)h)->interrupted; }

uint64_t gsq_open(gsq_bytes path, int32_t mode) {
    char *p = malloc((size_t)path.len + 1);
    memcpy(p, path.data, (size_t)path.len); p[path.len] = 0;
    int flags = mode == 0 ? SQLITE_OPEN_READONLY : (mode == 1 || mode == 3) ? SQLITE_OPEN_READWRITE : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE;
    sqlite3 *db = NULL;
    if (sqlite3_open_v2(p, &db, flags | SQLITE_OPEN_NOMUTEX, NULL) != SQLITE_OK) {
        snprintf(open_error, sizeof open_error, "%s", db ? sqlite3_errmsg(db) : "out of memory");
        sqlite3_close(db); free(p); return 0;
    }
    sqlite3_busy_timeout(db, 2000);
    if (mode == 3 && sqlite3_exec(db, "PRAGMA query_only=1", NULL, NULL, NULL) != SQLITE_OK) {
        snprintf(open_error, sizeof open_error, "%s", sqlite3_errmsg(db));
        sqlite3_close(db); free(p); return 0;
    }
    gsq_db *d = calloc(1, sizeof *d);
    d->db = db; d->path = p; d->mode = mode;
    return (uint64_t)(uintptr_t)d;
}
uint64_t gsq_local(gsq_bytes path, int32_t mode) {
    gsq_holder *h = holder_get();
    for (gsq_db *d = h->head; d; d = d->next)
        if (d->mode == mode && strlen(d->path) == (size_t)path.len && memcmp(d->path, path.data, (size_t)path.len) == 0) return (uint64_t)(uintptr_t)d;
    gsq_db *d = (gsq_db *)(uintptr_t)gsq_open(path, mode);
    if (!d) return 0;
    d->next = h->head; h->head = d;
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
    d->interrupted = 0;
    d->deadline = d->limit_ms > 0 ? gsq_now_ms() + d->limit_ms : 0;
    int rc = sqlite3_exec(d->db, z, NULL, NULL, NULL); free(z);
    d->deadline = 0;
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
    s->st = st; s->sql = copy; s->len = sql.len; s->next = d->stmts; d->stmts = s; s->owner = d;
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
    gsq_arm((gsq_stmt *)(uintptr_t)s);
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
/* Closes a connection from gsq_open (or a thread-local one, which is then forgotten). */
void gsq_close(uint64_t h) {
    gsq_db *d = (gsq_db *)(uintptr_t)h;
    if (!d) return;
    if (tl_holder) for (gsq_db **pp = &tl_holder->head; *pp; pp = &(*pp)->next) if (*pp == d) { *pp = d->next; break; }
    gsq_free_db(d);
}
int64_t gsq_changes(uint64_t h) { return h ? sqlite3_changes64(((gsq_db *)(uintptr_t)h)->db) : 0; }
int64_t gsq_last_id(uint64_t h) { return h ? sqlite3_last_insert_rowid(((gsq_db *)(uintptr_t)h)->db) : 0; }
int32_t gsq_run(uint64_t s) {
    if (!s) return 0;
    gsq_arm((gsq_stmt *)(uintptr_t)s);
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
/* BEGIN, COMMIT and ROLLBACK run with no time limit. */
static void gsq_unarm(uint64_t h) { if (h) ((gsq_db *)(uintptr_t)h)->deadline = 0; }
int32_t gsq_begin(uint64_t h) { gsq_unarm(h); return h && sqlite3_exec(DB(h), "BEGIN IMMEDIATE", NULL, NULL, NULL) == SQLITE_OK; }
int32_t gsq_commit(uint64_t h) { gsq_unarm(h); return h && sqlite3_exec(DB(h), "COMMIT", NULL, NULL, NULL) == SQLITE_OK; }
/* Only when a transaction is open, so a rollback after a failed BEGIN or a finished commit leaves the error state alone. */
void gsq_rollback(uint64_t h) { gsq_unarm(h); if (h && !sqlite3_get_autocommit(DB(h))) sqlite3_exec(DB(h), "ROLLBACK", NULL, NULL, NULL); }
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
    gsq_holder *h = holder_get();
    for (gsq_db *d = h->head; d; d = d->next)
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
    if (!pragma_text_is(d->db, "PRAGMA journal_mode=WAL", "wal")) snprintf(open_error, sizeof open_error, "%s", "cannot enable WAL");
    else if (sqlite3_exec(d->db, sync, NULL, NULL, NULL) != SQLITE_OK || (durable && sqlite3_exec(d->db, "PRAGMA fullfsync=1", NULL, NULL, NULL) != SQLITE_OK))
        snprintf(open_error, sizeof open_error, "%s", sqlite3_errmsg(d->db));
    else { d->next = h->head; h->head = d; return (uint64_t)(uintptr_t)d; }
    gsq_close((uint64_t)(uintptr_t)d);
    return 0;
}
