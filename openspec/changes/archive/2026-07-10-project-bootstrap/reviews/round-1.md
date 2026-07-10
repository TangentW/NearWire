# Review Round 1

## Reviewers

- Architecture, module boundaries, API surface, and packaging
- Correctness, tests, reproducibility, and failure handling
- Security, supply chain, performance, documentation, and OpenSpec compliance

## Consolidated Findings

### P1: Platform-specific Swift Package coverage is missing

The package gate builds and tests on the macOS host but does not compile supported SDK products for iOS 16 or shared products with an explicit macOS 13 deployment target.

Resolution required: add explicit iOS and macOS destination builds while retaining host unit tests.

### P1: Internal Core API isolation is underspecified

Future supported `NearWire` signatures could expose Core-declared event types, which would make those types part of the public compatibility contract despite the internal-product policy.

Resolution required: add a normative public-facade invariant and consumer compile fixtures that prevent supported APIs from exposing internal Core modules.

### P1: Boundary and dependency isolation are not automated

The gate does not reject UI framework imports in Core, external root-package dependencies, unauthorized target paths, or external Core/SDK pod dependencies.

Resolution required: add and invoke a dedicated boundary verifier.

### P1: CocoaPods validation is weakened

The lint command skips import validation and permits all warnings, so it cannot prove a warning-clean consumer import surface.

Resolution required: enable import validation, remove blanket warning acceptance, and use lintable metadata. Preserve explicit consumer fixture requirements for later public API changes.

### P1: Package resolve is not executed

The completed task requires resolve, build, tests, and strict-concurrency diagnostics, but the gate does not run `swift package resolve`.

Resolution required: add an explicit repository-local resolve operation and rerun evidence.

### P1: Exact raw validation logs are missing

The evidence summary records commands and conclusions but not verbatim stdout, stderr, and exit status.

Resolution required: add an evidence capture command and store timestamped raw logs plus an index.

### P1: Strict-concurrency warnings do not fail the gate

Swift 5 complete-concurrency diagnostics may be emitted as warnings, and CocoaPods currently permits all warnings.

Resolution required: run strict-concurrency compilation with warnings as errors and keep pod lint warning-clean.

### P1: Aggregate verification omits strict OpenSpec validation

The bootstrap aggregate can report success while the active specifications are invalid.

Resolution required: include non-interactive strict validation of all OpenSpec changes and specs.

### P2: The approved root license artifact is missing

The architecture includes a root `LICENSE`, while only inline proprietary podspec text exists.

Resolution required: add the authoritative proprietary license and require it in the structure gate.

### P2: The English-language check is incomplete and overstated

The scan excludes package metadata and future Apple resource formats, and a Han-character scan cannot prove that all natural language is English.

Resolution required: expand formats and roots, handle scanner errors, describe the mechanical scope accurately, and retain human review as the semantic gate.

### P2: Semantic version validation is incorrect

The shell regular expression accepts invalid versions and rejects valid pre-release plus build metadata combinations.

Resolution required: use a SemVer 2.0 parser and add positive and negative script tests.

### P2: The CocoaPods minimum version is not enforced

The documentation requires CocoaPods 1.16+, but the script only checks command presence.

Resolution required: validate the executable version and add positive and negative checker tests.

## Round Status

Round 1 has unresolved findings. The change cannot proceed to archive or the next implementation change.
