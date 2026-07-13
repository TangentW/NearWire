#ifndef ViewerSQLiteBridge_h
#define ViewerSQLiteBridge_h

#include <fcntl.h>
#include <sqlite3.h>

static inline int nearwire_sqlite3_db_config(
  sqlite3 *database,
  int operation,
  int enabled,
  int *result
) {
  return sqlite3_db_config(database, operation, enabled, result);
}

static inline int nearwire_file_descriptor_path(int descriptor, char *buffer) {
  return fcntl(descriptor, F_GETPATH, buffer);
}

static inline const char *nearwire_sqlite3_temp_directory(void) {
  return sqlite3_temp_directory;
}

#endif
