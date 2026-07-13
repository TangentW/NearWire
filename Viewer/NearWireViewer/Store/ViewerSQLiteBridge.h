#ifndef ViewerSQLiteBridge_h
#define ViewerSQLiteBridge_h

#include <sqlite3.h>

static inline int nearwire_sqlite3_db_config(
  sqlite3 *database,
  int operation,
  int enabled,
  int *result
) {
  return sqlite3_db_config(database, operation, enabled, result);
}

#endif
