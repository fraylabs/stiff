#define STIFF_STORE_EFFECT 1
#include <sqlite3.h>
#include <stdint.h>

#define STIFF_STORE_PATH_MAX 4096u
#define STIFF_STORE_KEY_MAX 255u
#define STIFF_STORE_OPERATION_MAX 255u
#define STIFF_STORE_VALUE_MAX 1048576u
#define STIFF_STORE_APPLICATION_ID 1398031942
#define STIFF_STORE_SCHEMA_VERSION 1

enum {
  STIFF_STORE_APPLIED = 1,
  STIFF_STORE_VERSION_CONFLICT = 2,
  STIFF_STORE_MISSING_CONFLICT = 3
};

typedef struct {
  char* data;
  size_t size;
  const char* error;
} StiffStoreText;

static StiffStoreText stiff_store_text(Env e, Term text, size_t limit) {
  StiffStoreText out = {0};
  size_t capacity = limit < 64 ? limit + 1 : 64;
  out.data = io_mem(malloc(capacity));
  while (term_aux(text) == CID_SCON) {
    Term fields[2];
    spare_free(e, cls_fit(2), ctr_take(e, text, 2, fields));
    text = fields[1];
    u64 scalar = fields[0];
    if (scalar > 0x10ffff || (scalar >= 0xd800 && scalar <= 0xdfff)) {
      out.error = "invalid_store_input";
      term_sink(e, text);
      break;
    }
    char bytes[4];
    size_t count = io_utf8(bytes, scalar);
    if (count > limit - out.size) {
      out.error = "store_input_too_large";
      term_sink(e, text);
      break;
    }
    if (out.size + count + 1 > capacity) {
      size_t next = capacity * 2;
      if (next < out.size + count + 1) next = out.size + count + 1;
      if (next > limit + 1) next = limit + 1;
      out.data = io_mem(realloc(out.data, next));
      capacity = next;
    }
    memcpy(out.data + out.size, bytes, count);
    out.size += count;
  }
  out.data[out.size] = 0;
  return out;
}

static int stiff_store_same(const void* a, int an, const char* b, size_t bn) {
  return an >= 0 && (size_t)an == bn && (!bn || memcmp(a, b, bn) == 0);
}

static const char* stiff_store_sqlite_code(int status) {
  switch (status & 0xff) {
    case SQLITE_BUSY:
    case SQLITE_LOCKED: return "store_busy";
    case SQLITE_CORRUPT:
    case SQLITE_NOTADB: return "store_corrupt";
    case SQLITE_CANTOPEN: return "store_open";
    case SQLITE_FULL: return "store_full";
    case SQLITE_READONLY: return "store_readonly";
    case SQLITE_SCHEMA:
    case SQLITE_CONSTRAINT: return "store_schema";
    default: return "store_io";
  }
}

static Term stiff_store_error(Env e, u64 cid, const char* code, const char* message) {
  return io_node(e, cid, io_str(e, code, strlen(code)), io_str(e, message, strlen(message)));
}

static int stiff_store_exec(sqlite3* db, const char* sql) {
  return sqlite3_exec(db, sql, NULL, NULL, NULL);
}

static int stiff_store_scalar(sqlite3* db, const char* sql, int* value) {
  sqlite3_stmt* statement = NULL;
  int status = sqlite3_prepare_v2(db, sql, -1, &statement, NULL);
  if (status == SQLITE_OK) status = sqlite3_step(statement);
  if (status == SQLITE_ROW) {
    *value = sqlite3_column_int(statement, 0);
    status = SQLITE_OK;
  } else if (status == SQLITE_DONE) status = SQLITE_ERROR;
  sqlite3_finalize(statement);
  return status;
}

typedef struct {
  const char* name;
  const char* type;
  int not_null;
  int primary_key;
} StiffStoreColumn;

static int stiff_store_table(sqlite3* db, const char* pragma,
                             const StiffStoreColumn* expected, size_t expected_count) {
  sqlite3_stmt* statement = NULL;
  int status = sqlite3_prepare_v2(db, pragma, -1, &statement, NULL);
  size_t index = 0;
  while (status == SQLITE_OK || status == SQLITE_ROW) {
    status = sqlite3_step(statement);
    if (status != SQLITE_ROW) break;
    const char* name = (const char*)sqlite3_column_text(statement, 1);
    const char* type = (const char*)sqlite3_column_text(statement, 2);
    if (index >= expected_count || !name || !type ||
        strcmp(name, expected[index].name) || strcmp(type, expected[index].type) ||
        sqlite3_column_int(statement, 3) != expected[index].not_null ||
        sqlite3_column_int(statement, 5) != expected[index].primary_key) {
      status = SQLITE_SCHEMA;
      break;
    }
    index++;
  }
  if (status == SQLITE_DONE) status = index == expected_count ? SQLITE_OK : SQLITE_SCHEMA;
  sqlite3_finalize(statement);
  return status;
}

static int stiff_store_definition(sqlite3* db, const char* query, const char* expected) {
  sqlite3_stmt* statement = NULL;
  int status = sqlite3_prepare_v2(db, query, -1, &statement, NULL);
  if (status == SQLITE_OK) status = sqlite3_step(statement);
  if (status == SQLITE_ROW) {
    const char* actual = (const char*)sqlite3_column_text(statement, 0);
    status = actual && !strcmp(actual, expected) ? SQLITE_OK : SQLITE_SCHEMA;
  } else if (status == SQLITE_DONE) status = SQLITE_SCHEMA;
  sqlite3_finalize(statement);
  return status;
}

static int stiff_store_schema(sqlite3* db) {
  static const StiffStoreColumn kv[] = {
    {"key", "TEXT", 1, 1}, {"value", "TEXT", 1, 0}, {"version", "INTEGER", 1, 0}
  };
  static const StiffStoreColumn operations[] = {
    {"operation_id", "TEXT", 1, 1}, {"key", "TEXT", 1, 0},
    {"expected_version", "INTEGER", 1, 0}, {"value", "TEXT", 1, 0},
    {"outcome", "INTEGER", 1, 0}, {"result_version", "INTEGER", 0, 0},
    {"result_value", "TEXT", 0, 0}
  };
  int objects = 0;
  int status = stiff_store_scalar(db,
    "SELECT count(*) FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%';", &objects);
  if (status == SQLITE_OK && objects != 2) status = SQLITE_SCHEMA;
  if (status == SQLITE_OK) status = stiff_store_table(db, "PRAGMA table_info(stiff_kv);", kv, 3);
  if (status == SQLITE_OK) status = stiff_store_table(db,
    "PRAGMA table_info(stiff_operations);", operations, 7);
  if (status == SQLITE_OK) status = stiff_store_definition(db,
    "SELECT sql FROM sqlite_schema WHERE type='table' AND name='stiff_kv';",
    "CREATE TABLE stiff_kv(key TEXT PRIMARY KEY NOT NULL,value TEXT NOT NULL,"
    "version INTEGER NOT NULL CHECK(version BETWEEN 1 AND 4294967295))");
  if (status == SQLITE_OK) status = stiff_store_definition(db,
    "SELECT sql FROM sqlite_schema WHERE type='table' AND name='stiff_operations';",
    "CREATE TABLE stiff_operations(operation_id TEXT PRIMARY KEY NOT NULL,key TEXT NOT NULL,"
    "expected_version INTEGER NOT NULL,value TEXT NOT NULL,outcome INTEGER NOT NULL "
    "CHECK(outcome BETWEEN 1 AND 3),result_version INTEGER,result_value TEXT)");
  return status;
}

// Open one scoped connection per effect. FULL synchronous WAL commits preserve
// the key mutation and its operation receipt together across process restart.
static int stiff_store_connect(const char* path, sqlite3** result) {
  sqlite3* db = NULL;
  int status = sqlite3_open_v2(path, &db,
    SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, NULL);
  if (status != SQLITE_OK) {
    if (db) sqlite3_close(db);
    return status;
  }
  sqlite3_extended_result_codes(db, 1);
  sqlite3_busy_timeout(db, 5000);
  int application_id = 0, user_version = 0, objects = 0;
  status = stiff_store_scalar(db, "PRAGMA application_id;", &application_id);
  if (status == SQLITE_OK) status = stiff_store_scalar(db, "PRAGMA user_version;", &user_version);
  if (status == SQLITE_OK) status = stiff_store_scalar(db,
    "SELECT count(*) FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%';", &objects);

  int empty = application_id == 0 && user_version == 0 && objects == 0;
  if (status == SQLITE_OK && empty) {
    // Serialize first initialization and repeat every ownership check after the
    // lock: another process may have initialized the empty file meanwhile.
    status = stiff_store_exec(db, "BEGIN IMMEDIATE;");
    if (status == SQLITE_OK) status = stiff_store_scalar(db, "PRAGMA application_id;", &application_id);
    if (status == SQLITE_OK) status = stiff_store_scalar(db, "PRAGMA user_version;", &user_version);
    if (status == SQLITE_OK) status = stiff_store_scalar(db,
      "SELECT count(*) FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%';", &objects);
    empty = application_id == 0 && user_version == 0 && objects == 0;
    if (status == SQLITE_OK && empty) {
      status = stiff_store_exec(db,
        "CREATE TABLE stiff_kv("
        "key TEXT PRIMARY KEY NOT NULL,value TEXT NOT NULL,"
        "version INTEGER NOT NULL CHECK(version BETWEEN 1 AND 4294967295));"
        "CREATE TABLE stiff_operations("
        "operation_id TEXT PRIMARY KEY NOT NULL,key TEXT NOT NULL,"
        "expected_version INTEGER NOT NULL,value TEXT NOT NULL,"
        "outcome INTEGER NOT NULL CHECK(outcome BETWEEN 1 AND 3),"
        "result_version INTEGER,result_value TEXT);"
        "PRAGMA application_id=1398031942;PRAGMA user_version=1;");
      if (status == SQLITE_OK) {
        application_id = STIFF_STORE_APPLICATION_ID;
        user_version = STIFF_STORE_SCHEMA_VERSION;
      }
    } else if (status == SQLITE_OK &&
               (application_id != STIFF_STORE_APPLICATION_ID ||
                user_version != STIFF_STORE_SCHEMA_VERSION)) status = SQLITE_SCHEMA;
    if (status == SQLITE_OK) status = stiff_store_exec(db, "COMMIT;");
    else stiff_store_exec(db, "ROLLBACK;");
  } else if (status == SQLITE_OK &&
             (application_id != STIFF_STORE_APPLICATION_ID ||
              user_version != STIFF_STORE_SCHEMA_VERSION)) status = SQLITE_SCHEMA;

  if (status == SQLITE_OK) status = stiff_store_schema(db);
  // Persistent pragmas come only after ownership and schema validation. A
  // rejected database retains its journal mode, schema and application markers.
  if (status == SQLITE_OK) status = stiff_store_exec(db, "PRAGMA journal_mode=WAL;");
  if (status == SQLITE_OK) status = stiff_store_exec(db, "PRAGMA synchronous=FULL;");
  if (status != SQLITE_OK) {
    sqlite3_close(db);
    return status;
  }
  *result = db;
  return SQLITE_OK;
}

static int stiff_store_path(Env e, Term value, StiffStoreText* path) {
  Term fields[1];
  spare_free(e, cls_fit(1), ctr_take(e, value, 1, fields));
  *path = stiff_store_text(e, fields[0], STIFF_STORE_PATH_MAX);
  if (path->error || !path->size || strlen(path->data) != path->size ||
      !strcmp(path->data, ":memory:")) return 0;
  return 1;
}

#ifdef CID_STORE_OPEN
static Term stiff_store_open_run(Env e, Term* f, IoWork* work) {
  (void)work;
  StiffStoreText path = stiff_store_text(e, f[0], STIFF_STORE_PATH_MAX);
  if (path.error || !path.size || strlen(path.data) != path.size || !strcmp(path.data, ":memory:")) {
    free(path.data);
    return stiff_store_error(e, CID_STOREOPENERROR, path.error ? path.error : "invalid_store_path",
      "Store path must name a bounded filesystem database.");
  }
  sqlite3* db = NULL;
  int status = stiff_store_connect(path.data, &db);
  if (db) sqlite3_close(db);
  if (status != SQLITE_OK) {
    free(path.data);
    return stiff_store_error(e, CID_STOREOPENERROR, stiff_store_sqlite_code(status),
      "Store initialization failed.");
  }
  // StoreReady{Store{path}} is flattened by the pinned compiler because Store
  // has one constructor. Native layout tests cover this private ABI choice.
  Term store = io_str(e, path.data, path.size);
  free(path.data);
  return io_box(e, CID_STOREREADY, store);
}
#endif

#ifdef CID_STORE_READ
static Term stiff_store_read_run(Env e, Term* f, IoWork* work) {
  (void)work;
  StiffStoreText path = {0}, key = {0};
  if (!stiff_store_path(e, f[0], &path)) {
    free(path.data);
    term_sink(e, f[1]);
    return stiff_store_error(e, CID_STOREREADERROR, "invalid_store_path", "Store path is invalid.");
  }
  key = stiff_store_text(e, f[1], STIFF_STORE_KEY_MAX);
  if (key.error || !key.size) {
    free(path.data); free(key.data);
    return stiff_store_error(e, CID_STOREREADERROR, key.error ? key.error : "invalid_store_input",
      "Store key is invalid.");
  }
  sqlite3* db = NULL;
  int status = stiff_store_connect(path.data, &db);
  sqlite3_stmt* statement = NULL;
  if (status == SQLITE_OK) status = sqlite3_prepare_v2(db,
    "SELECT version,value FROM stiff_kv WHERE key=?1;", -1, &statement, NULL);
  if (status == SQLITE_OK) status = sqlite3_bind_text(statement, 1, key.data, (int)key.size, SQLITE_TRANSIENT);
  if (status == SQLITE_OK) status = sqlite3_step(statement);
  Term result = 0;
  if (status == SQLITE_ROW) {
    sqlite3_int64 version = sqlite3_column_int64(statement, 0);
    const char* value = (const char*)sqlite3_column_text(statement, 1);
    int bytes = sqlite3_column_bytes(statement, 1);
    if (version < 1 || version > UINT32_MAX || bytes < 0) status = SQLITE_CORRUPT;
    else result = io_node(e, CID_STOREFOUND, (u32)version, io_str(e, value, (size_t)bytes));
  } else if (status == SQLITE_DONE) result = term_pak(CID_STOREMISSING, 0);
  sqlite3_finalize(statement);
  if (db) sqlite3_close(db);
  free(path.data); free(key.data);
  if (result) return result;
  return stiff_store_error(e, CID_STOREREADERROR, stiff_store_sqlite_code(status), "Store read failed.");
}
#endif

#if defined(CID_STORE_COMPARE_WRITE) || defined(CID_STORE_OPERATION)
static int stiff_store_begin(sqlite3* db) {
  return stiff_store_exec(db, "BEGIN IMMEDIATE;");
}

static void stiff_store_rollback(sqlite3* db) {
  if (db) stiff_store_exec(db, "ROLLBACK;");
}
#endif

#ifdef CID_STORE_COMPARE_WRITE
static Term stiff_store_write_result(Env e, int outcome, uint32_t version,
                                     const char* value, size_t value_size, int replayed) {
  if (outcome == STIFF_STORE_APPLIED)
    return term_pak(replayed ? CID_STOREREPLAYED : CID_STOREAPPLIED, version);
  if (outcome == STIFF_STORE_MISSING_CONFLICT)
    return term_pak(replayed ? CID_STOREREPLAYEDMISSINGCONFLICT : CID_STOREMISSINGCONFLICT, 0);
  return io_node(e, replayed ? CID_STOREREPLAYEDVERSIONCONFLICT : CID_STOREVERSIONCONFLICT,
    version, io_str(e, value, value_size));
}

static Term stiff_store_compare_write_run(Env e, Term* f, IoWork* work) {
  (void)work;
  StiffStoreText path = {0}, operation = {0}, key = {0}, value = {0};
  uint32_t expected = (uint32_t)f[3];
  if (!stiff_store_path(e, f[0], &path)) {
    free(path.data); term_sink(e, f[1]); term_sink(e, f[2]); term_sink(e, f[4]);
    return stiff_store_error(e, CID_STOREWRITEERROR, "invalid_store_path", "Store path is invalid.");
  }
  operation = stiff_store_text(e, f[1], STIFF_STORE_OPERATION_MAX);
  key = stiff_store_text(e, f[2], STIFF_STORE_KEY_MAX);
  value = stiff_store_text(e, f[4], STIFF_STORE_VALUE_MAX);
  if (operation.error || key.error || value.error || !operation.size || !key.size || expected == UINT32_MAX) {
    const char* code = operation.error ? operation.error : key.error ? key.error : value.error ? value.error : "invalid_store_input";
    free(path.data); free(operation.data); free(key.data); free(value.data);
    return stiff_store_error(e, CID_STOREWRITEERROR, code, "Store write input is invalid.");
  }

  sqlite3* db = NULL;
  sqlite3_stmt* statement = NULL;
  int commit_uncertain = 0;
  int status = stiff_store_connect(path.data, &db);
  if (status == SQLITE_OK) status = stiff_store_begin(db);
  if (status == SQLITE_OK) status = sqlite3_prepare_v2(db,
    "SELECT key,expected_version,value,outcome,result_version,result_value "
    "FROM stiff_operations WHERE operation_id=?1;", -1, &statement, NULL);
  if (status == SQLITE_OK) status = sqlite3_bind_text(statement, 1, operation.data, (int)operation.size, SQLITE_TRANSIENT);
  if (status == SQLITE_OK) status = sqlite3_step(statement);
  if (status == SQLITE_ROW) {
    const char* saved_key = (const char*)sqlite3_column_text(statement, 0);
    int saved_key_size = sqlite3_column_bytes(statement, 0);
    sqlite3_int64 saved_expected = sqlite3_column_int64(statement, 1);
    const char* saved_value = (const char*)sqlite3_column_text(statement, 2);
    int saved_value_size = sqlite3_column_bytes(statement, 2);
    int same = stiff_store_same(saved_key, saved_key_size, key.data, key.size) &&
      saved_expected == expected && stiff_store_same(saved_value, saved_value_size, value.data, value.size);
    int outcome = sqlite3_column_int(statement, 3);
    sqlite3_int64 stored_version = sqlite3_column_type(statement, 4) == SQLITE_NULL
      ? 0 : sqlite3_column_int64(statement, 4);
    const char* stored_value = (const char*)sqlite3_column_text(statement, 5);
    int stored_value_size = sqlite3_column_bytes(statement, 5);
    if (!same) {
      sqlite3_finalize(statement); statement = NULL;
      status = stiff_store_exec(db, "COMMIT;");
      if (status == SQLITE_OK) {
        sqlite3_close(db); free(path.data); free(operation.data); free(key.data); free(value.data);
        return term_pak(CID_STOREIDEMPOTENCYCONFLICT, 0);
      }
    } else if (outcome >= STIFF_STORE_APPLIED && outcome <= STIFF_STORE_MISSING_CONFLICT &&
               stored_version >= 0 && stored_version <= UINT32_MAX && stored_value_size >= 0) {
      Term result = stiff_store_write_result(e, outcome, (uint32_t)stored_version,
        stored_value ? stored_value : "", (size_t)stored_value_size, 1);
      sqlite3_finalize(statement); statement = NULL;
      status = stiff_store_exec(db, "COMMIT;");
      if (status == SQLITE_OK) {
        sqlite3_close(db); free(path.data); free(operation.data); free(key.data); free(value.data);
        return result;
      }
      term_sink(e, result);
    } else status = SQLITE_CORRUPT;
  } else if (status == SQLITE_DONE) {
    sqlite3_finalize(statement); statement = NULL;
    status = sqlite3_prepare_v2(db, "SELECT version,value FROM stiff_kv WHERE key=?1;", -1, &statement, NULL);
    if (status == SQLITE_OK) status = sqlite3_bind_text(statement, 1, key.data, (int)key.size, SQLITE_TRANSIENT);
    if (status == SQLITE_OK) status = sqlite3_step(statement);
    int outcome = 0;
    uint32_t result_version = 0;
    char* result_value = NULL;
    size_t result_value_size = 0;
    if (status == SQLITE_ROW) {
      sqlite3_int64 current = sqlite3_column_int64(statement, 0);
      const char* current_value = (const char*)sqlite3_column_text(statement, 1);
      int current_size = sqlite3_column_bytes(statement, 1);
      if (current < 1 || current > UINT32_MAX || current_size < 0) status = SQLITE_CORRUPT;
      else if ((uint32_t)current == expected && expected > 0) {
        outcome = STIFF_STORE_APPLIED; result_version = expected + 1; status = SQLITE_OK;
      } else {
        outcome = STIFF_STORE_VERSION_CONFLICT; result_version = (uint32_t)current;
        result_value = io_mem(malloc((size_t)current_size + 1));
        memcpy(result_value, current_value, (size_t)current_size);
        result_value[current_size] = 0; result_value_size = (size_t)current_size;
        status = SQLITE_OK;
      }
    } else if (status == SQLITE_DONE) {
      if (expected == 0) { outcome = STIFF_STORE_APPLIED; result_version = 1; }
      else outcome = STIFF_STORE_MISSING_CONFLICT;
      status = SQLITE_OK;
    }
    sqlite3_finalize(statement); statement = NULL;

    if (status == SQLITE_OK && outcome == STIFF_STORE_APPLIED) {
      if (expected == 0) status = sqlite3_prepare_v2(db,
        "INSERT INTO stiff_kv(key,value,version) VALUES(?1,?2,1);", -1, &statement, NULL);
      else status = sqlite3_prepare_v2(db,
        "UPDATE stiff_kv SET value=?2,version=?3 WHERE key=?1 AND version=?4;", -1, &statement, NULL);
      if (status == SQLITE_OK) status = sqlite3_bind_text(statement, 1, key.data, (int)key.size, SQLITE_TRANSIENT);
      if (status == SQLITE_OK) status = sqlite3_bind_text(statement, 2, value.data, (int)value.size, SQLITE_TRANSIENT);
      if (status == SQLITE_OK && expected > 0) status = sqlite3_bind_int64(statement, 3, result_version);
      if (status == SQLITE_OK && expected > 0) status = sqlite3_bind_int64(statement, 4, expected);
      if (status == SQLITE_OK) status = sqlite3_step(statement);
      if (status == SQLITE_DONE && sqlite3_changes(db) == 1) status = SQLITE_OK;
      else if (status == SQLITE_DONE) status = SQLITE_CORRUPT;
      sqlite3_finalize(statement); statement = NULL;
    }
    if (status == SQLITE_OK) status = sqlite3_prepare_v2(db,
      "INSERT INTO stiff_operations(operation_id,key,expected_version,value,outcome,result_version,result_value) "
      "VALUES(?1,?2,?3,?4,?5,?6,?7);", -1, &statement, NULL);
    if (status == SQLITE_OK) status = sqlite3_bind_text(statement, 1, operation.data, (int)operation.size, SQLITE_TRANSIENT);
    if (status == SQLITE_OK) status = sqlite3_bind_text(statement, 2, key.data, (int)key.size, SQLITE_TRANSIENT);
    if (status == SQLITE_OK) status = sqlite3_bind_int64(statement, 3, expected);
    if (status == SQLITE_OK) status = sqlite3_bind_text(statement, 4, value.data, (int)value.size, SQLITE_TRANSIENT);
    if (status == SQLITE_OK) status = sqlite3_bind_int(statement, 5, outcome);
    if (status == SQLITE_OK && outcome != STIFF_STORE_MISSING_CONFLICT) status = sqlite3_bind_int64(statement, 6, result_version);
    if (status == SQLITE_OK && outcome == STIFF_STORE_MISSING_CONFLICT) status = sqlite3_bind_null(statement, 6);
    if (status == SQLITE_OK && outcome == STIFF_STORE_VERSION_CONFLICT)
      status = sqlite3_bind_text(statement, 7, result_value, (int)result_value_size, SQLITE_TRANSIENT);
    if (status == SQLITE_OK && outcome != STIFF_STORE_VERSION_CONFLICT) status = sqlite3_bind_null(statement, 7);
    if (status == SQLITE_OK) status = sqlite3_step(statement);
    if (status == SQLITE_DONE) status = SQLITE_OK;
    sqlite3_finalize(statement); statement = NULL;
    if (status == SQLITE_OK) {
      status = stiff_store_exec(db, "COMMIT;");
      commit_uncertain = status == SQLITE_IOERR || status == SQLITE_FULL;
    }
    if (status == SQLITE_OK) {
      Term result = stiff_store_write_result(e, outcome, result_version,
        result_value ? result_value : "", result_value_size, 0);
      free(result_value); sqlite3_close(db);
      free(path.data); free(operation.data); free(key.data); free(value.data);
      return result;
    }
    free(result_value);
  }

  sqlite3_finalize(statement);
  stiff_store_rollback(db);
  if (db) sqlite3_close(db);
  free(path.data); free(operation.data); free(key.data); free(value.data);
  return stiff_store_error(e, CID_STOREWRITEERROR,
    commit_uncertain ? "store_commit_uncertain" : stiff_store_sqlite_code(status),
    commit_uncertain
      ? "Commit acknowledgement failed; reconcile the operation ID before retrying."
      : "Store write failed.");
}
#endif

#ifdef CID_STORE_OPERATION
static Term stiff_store_operation_run(Env e, Term* f, IoWork* work) {
  (void)work;
  StiffStoreText path = {0}, operation = {0};
  if (!stiff_store_path(e, f[0], &path)) {
    free(path.data); term_sink(e, f[1]);
    return stiff_store_error(e, CID_STOREOPERATIONERROR, "invalid_store_path", "Store path is invalid.");
  }
  operation = stiff_store_text(e, f[1], STIFF_STORE_OPERATION_MAX);
  if (operation.error || !operation.size) {
    free(path.data); free(operation.data);
    return stiff_store_error(e, CID_STOREOPERATIONERROR,
      operation.error ? operation.error : "invalid_store_input", "Operation ID is invalid.");
  }
  sqlite3* db = NULL;
  sqlite3_stmt* statement = NULL;
  int status = stiff_store_connect(path.data, &db);
  if (status == SQLITE_OK) status = sqlite3_prepare_v2(db,
    "SELECT key,outcome,result_version FROM stiff_operations WHERE operation_id=?1;", -1, &statement, NULL);
  if (status == SQLITE_OK) status = sqlite3_bind_text(statement, 1, operation.data, (int)operation.size, SQLITE_TRANSIENT);
  if (status == SQLITE_OK) status = sqlite3_step(statement);
  Term result = 0;
  if (status == SQLITE_ROW) {
    const char* key = (const char*)sqlite3_column_text(statement, 0);
    int key_size = sqlite3_column_bytes(statement, 0);
    int outcome = sqlite3_column_int(statement, 1);
    sqlite3_int64 version = sqlite3_column_type(statement, 2) == SQLITE_NULL ? 0 : sqlite3_column_int64(statement, 2);
    if (key_size < 0 || version < 0 || version > UINT32_MAX) status = SQLITE_CORRUPT;
    else if (outcome == STIFF_STORE_APPLIED)
      result = io_node(e, CID_STOREOPERATIONAPPLIED, io_str(e, key, (size_t)key_size), (u32)version);
    else if (outcome == STIFF_STORE_VERSION_CONFLICT)
      result = io_node(e, CID_STOREOPERATIONVERSIONCONFLICT, io_str(e, key, (size_t)key_size), (u32)version);
    else if (outcome == STIFF_STORE_MISSING_CONFLICT)
      result = io_box(e, CID_STOREOPERATIONMISSINGCONFLICT, io_str(e, key, (size_t)key_size));
    else status = SQLITE_CORRUPT;
  } else if (status == SQLITE_DONE) result = term_pak(CID_STOREOPERATIONUNKNOWN, 0);
  sqlite3_finalize(statement);
  if (db) sqlite3_close(db);
  free(path.data); free(operation.data);
  if (result) return result;
  return stiff_store_error(e, CID_STOREOPERATIONERROR, stiff_store_sqlite_code(status), "Operation lookup failed.");
}
#endif

static void __attribute__((constructor)) stiff_store_register(void) {
#ifdef CID_STORE_OPEN
  io_eff(CID_STORE_OPEN, stiff_store_open_run, 0);
#endif
#ifdef CID_STORE_READ
  io_eff(CID_STORE_READ, stiff_store_read_run, 0);
#endif
#ifdef CID_STORE_COMPARE_WRITE
  io_eff(CID_STORE_COMPARE_WRITE, stiff_store_compare_write_run, 0);
#endif
#ifdef CID_STORE_OPERATION
  io_eff(CID_STORE_OPERATION, stiff_store_operation_run, 0);
#endif
}
