# Resource and Filesystem Audit — Round 6

Date: 2026-07-13 (Asia/Shanghai)

This audit supersedes the restoration and residual-copy portions of the Round 5 audit. It records exact commands and non-content file identity metadata. Configured signing remains deferred to the goal-level `release-hardening` change.

## Pre-audit identity

Command:

```text
stat -f '%N|dev=%d|inode=%i|mode=%Lp|size=%z|mtime=%m' \
  '/Users/tangent/Library/Application Support/NearWire' \
  '/Users/tangent/Library/Application Support/NearWire/NearWire.sqlite' \
  '/Users/tangent/Library/Application Support/NearWire/NearWire.sqlite-wal' \
  '/Users/tangent/Library/Application Support/NearWire/NearWire.sqlite-shm'
```

Result, exit 0:

```text
/Users/tangent/Library/Application Support/NearWire|dev=16777232|inode=18366234|mode=700|size=160|mtime=1783889157
/Users/tangent/Library/Application Support/NearWire/NearWire.sqlite|dev=16777232|inode=18366235|mode=600|size=184320|mtime=1783890698
/Users/tangent/Library/Application Support/NearWire/NearWire.sqlite-wal|dev=16777232|inode=18366237|mode=600|size=0|mtime=1783890698
/Users/tangent/Library/Application Support/NearWire/NearWire.sqlite-shm|dev=16777232|inode=18366238|mode=600|size=32768|mtime=1783905287
```

The original directory was isolated with this exact command, exit 0:

```text
mv '/Users/tangent/Library/Application Support/NearWire' /tmp/NearWire-preaudit-round6-20260713
```

No database content was read or copied into repository evidence.

## Opt-in live-path test

The marker `/tmp/nearwire-live-container-audit.enabled` contained only `enabled`. Command:

```text
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/NearWireViewerRound6Audit ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO CLANG_MODULE_CACHE_PATH=/tmp/NearWireModuleCache \
  SWIFT_MODULECACHE_PATH=/tmp/NearWireModuleCache test \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testOptInLiveApplicationSupportArtifactsWhileViewerStoreIsOpen
```

Exact result:

```text
active main: mode 0600, logical 188416 bytes, allocated 188416 bytes
active WAL: mode 0600, logical 193672 bytes, allocated 196608 bytes
active SHM: mode 0600, logical 32768 bytes, allocated 32768 bytes
directory: mode 0700
Executed 1 test, 0 failures
** TEST SUCCEEDED **
result bundle: /tmp/NearWireViewerRound6Audit/Logs/Test/Test-NearWireViewer-2026.07.13_09-16-46-+0800.xcresult
```

## Running application ownership

Launch command, exit 0:

```text
open -n /tmp/NearWireViewerRound6Audit/Build/Products/Debug/NearWire.app
```

Inspection command:

```text
lsof \
  '/Users/tangent/Library/Application Support/NearWire/NearWire.sqlite' \
  '/Users/tangent/Library/Application Support/NearWire/NearWire.sqlite-wal' \
  '/Users/tangent/Library/Application Support/NearWire/NearWire.sqlite-shm'
```

Exact relevant result, exit 0:

```text
NearWire PID 63555: main fd 3u, 6r, 7r; WAL fd 4u, 9r; SHM txt and fd 5u
main inode 18764339, WAL inode 18764341, SHM inode 18764342
```

Normal quit command, exit 0:

```text
osascript -e 'tell application id "com.nearwire.viewer" to quit'
```

Clean-close `stat` result, exit 0:

```text
directory: inode 18764338, mode 0700
main: inode 18764339, mode 0600, logical 188416 bytes, 368 allocated 512-byte blocks
WAL: inode 18764341, mode 0600, logical 0 bytes, 0 allocated blocks
SHM: inode 18764342, mode 0600, logical 32768 bytes, 64 allocated 512-byte blocks
```

## Restoration and residual-data cleanup

Commands, each exit 0:

```text
mv '/Users/tangent/Library/Application Support/NearWire' /tmp/NearWire-audit-round6-cleanup-20260713
mv /tmp/NearWire-preaudit-round6-20260713 '/Users/tangent/Library/Application Support/NearWire'
rm -rf /tmp/NearWire-audit-round6-cleanup-20260713
```

The opt-in marker was deleted after the test. The restored `stat` command returned the exact same device, inode, mode, logical size, and modification time for the directory and all three files as the pre-audit identity block. A final bounded `/tmp` search returned no result for:

```text
NearWire-preaudit-round6-20260713
NearWire-audit-round6-cleanup-20260713
NearWire-audit-created-20260713
nearwire-live-container-audit.enabled
```

The audit therefore leaves no duplicate SQLite store outside Viewer quota, retention, and cleanup. The restored pre-existing store remains unsupported current application data and was not modified or represented as a valid current schema.

## Encryption disclosure

`Documentation/Viewer-Local-Store.md` now states directly that the local SQLite database has no NearWire application-layer at-rest encryption. Owner-only modes are verified above. FileVault or other system volume protection may apply when separately configured, but NearWire does not detect, require, or guarantee it. JSON exports remain ordinary unencrypted files outside Viewer quota and retention.
