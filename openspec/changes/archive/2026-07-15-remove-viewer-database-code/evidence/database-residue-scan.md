# Database Residue Scan

The maintained scan scope is Viewer production source, Viewer tests, the Viewer Xcode project, active OpenSpec capabilities, and maintained Viewer documentation. Archived OpenSpec history is intentionally excluded because it records earlier architecture.

## Source and test files

Commands:

```sh
find Viewer/NearWireViewer/Store -type f -print
find Viewer/NearWireViewerTests -type f \( -iname '*store*' -o -iname '*sqlite*' -o -iname '*database*' \) -print
```

Result: both produce no paths. Every former Store implementation file and `ViewerStoreTests.swift` is deleted, and the now-empty `Viewer/NearWireViewer/Store` directory is removed.

## SQL, SQLite, and project linkage

Commands:

```sh
rg -n -i '\bimport[[:space:]]+SQLite3\b|sqlite3_|libsqlite3|CREATE[[:space:]]+TABLE|ALTER[[:space:]]+TABLE|DROP[[:space:]]+TABLE|INSERT[[:space:]]+INTO|DELETE[[:space:]]+FROM|PRAGMA|ViewerEventStore|ViewerStoreCatalog|ViewerStoreCoordinator|ViewerStoreExplorerGateway|ViewerSQLite|ViewerStoreTests' \
  Viewer/NearWireViewer Viewer/NearWireViewerTests Viewer/NearWireViewer.xcodeproj/project.pbxproj \
  --glob '*.swift' --glob '*.h' --glob '*.m' --glob '*.pbxproj'
rg -n 'SWIFT_OBJC_BRIDGING_HEADER|/\* Store \*/|path = Store|ViewerSQLiteBridge|libsqlite3' \
  Viewer/NearWireViewer.xcodeproj/project.pbxproj
rg -n '"[[:space:]]*(CREATE|ALTER|DROP|INSERT|DELETE|SELECT|UPDATE|PRAGMA)[[:space:]]' \
  Viewer/NearWireViewer Viewer/NearWireViewerTests --glob '*.swift' --glob '*.h' --glob '*.m'
```

Result: all searches produce no matches. The target has no SQLite library, bridge header setting, Store group, SQL/schema statement, connection wrapper, or old Store type reference.

## Remaining identity persistence

A broad `Store` naming scan finds only `Identity/ViewerIdentityStore.swift` and `ViewerStoredIdentityMaterial`. This is the existing macOS Keychain boundary for the installation identifier and TLS identity. It contains no Event or Session data, SQL, SQLite, table, or database operation and remains required for secure listener startup.

The bounded `ViewerDevicePreferences` UserDefaults record for requested rates and nicknames also remains. It is product preference persistence, not a Source, Session, Event, or Performance database.

## Inspector surface

`ViewerExplorerInspectorTab` contains exactly Metadata, Raw, Tree, Pretty, and Renderer. Production and test code has no Causality Inspector state, tab, candidate graph, or cross-Event lookup. `EventCausality`, `correlationID`, and `replyTo` remain only as protocol and selected-Event metadata.
