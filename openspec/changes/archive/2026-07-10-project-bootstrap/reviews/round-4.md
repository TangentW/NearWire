# Review Round 4

## Reviewers

- Architecture, module boundaries, API surface, and packaging
- Correctness, tests, reproducibility, and failure handling
- Security, supply chain, performance, documentation, and OpenSpec compliance

## Consolidated Findings

### P2: Simulator shutdown failures did not fail verification

The cleanup trap attempted to restore state but ignored every `simctl shutdown` error, so a successful test run could still leak a Simulator while reporting success.

Resolution: move restoration semantics into a tested helper. Preserve already-booted Simulators, restore a Simulator booted by the verifier, fail an otherwise successful gate with a dedicated cleanup status when restoration fails, and preserve an existing primary failure while reporting cleanup failure.

### P2: CocoaPods glob traversal and symlink escapes were possible

Parent traversal embedded in brace alternatives was not a standalone `Pathname` component, and lexical containment did not detect a matched symlink resolving outside Core or SDK.

Resolution: recursively expand bounded brace alternatives, reject parent traversal in every expansion, resolve every existing match, and require realpath containment. Add brace and symlink escape fixtures. SwiftPM target paths now apply the same realpath containment policy.

### P2: Public imports could re-export internal Core modules

The compiler parse tree marks `@_exported` imports but does not annotate Swift's `public import` syntax.

Resolution: combine compiler-confirmed import declarations with comment- and string-aware modifier token inspection. Add single-line and multiline `public import NearWireCore` fixtures.

### P2: Core graph parity discarded dependency metadata

The parity normalizer compared dependency names but ignored kind, package identity, aliases, and conditions.

Resolution: canonicalize and compare the complete target descriptor, including complete dependency metadata and target settings. Add conditional-versus-unconditional dependency drift coverage.

### P2: Xcode version parsing was vulnerable to SIGPIPE

An early-exiting `awk` in a pipeline could cause `xcodebuild -version` to receive SIGPIPE under `pipefail`.

Resolution: capture the complete version output before parsing it, then rerun the full package gate.

## Round Status

Every round 4 finding has an implemented remediation pending canonical recapture and fresh independent review.
