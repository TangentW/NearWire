## 1. Repository Foundation

- [x] 1.1 Add root repository metadata, version source, changelog, English README, and Git ignore rules.
- [x] 1.2 Create the approved Core, SDK, Viewer, Demo, IntegrationTests, Documentation, and Scripts directory structure.
- [x] 1.3 Add the root workspace skeleton without introducing generated or placeholder Xcode projects.
- [x] 1.4 Add an English repository agent guide that enforces the OpenSpec-first sequential change workflow.

## 2. Module and Package Skeleton

- [x] 2.1 Add minimal internal source entry points for every approved Core and SDK Swift target.
- [x] 2.2 Add smoke tests for every Swift target without defining premature public product behavior.
- [x] 2.3 Add the root Package.swift with explicit paths, approved products, platforms, and Swift 5 language mode.
- [x] 2.4 Verify Swift Package resolve, build, test, and strict-concurrency diagnostics on Xcode 16.

## 3. CocoaPods Distribution Skeleton

- [x] 3.1 Add the root NearWire.podspec with Core, SDK, UI, and Performance subspecs over the shared source tree.
- [x] 3.2 Add conditional SwiftPM-only imports where the multi-module SPM graph differs from the single CocoaPods module.
- [x] 3.3 Validate the podspec and record any environment limitation without weakening the distribution contract.

## 4. Delivery Documentation and Automation

- [x] 4.1 Add the complete sequential OpenSpec implementation roadmap for Core, SDK, Viewer, Demo, and hardening changes.
- [x] 4.2 Add repository structure, package, version, and English-language validation scripts.
- [x] 4.3 Add one bootstrap verification command that runs all available quality checks and fails on a required gate.
- [x] 4.4 Document SDK package integration, internal Core status, Viewer-only dependency isolation, and Swift compatibility semantics.

## 5. Verification and Review

- [x] 5.1 Run all bootstrap validation commands and save exact results under the change evidence directory.
- [x] 5.2 Run review round 1 with independent architecture/API, correctness/testing, and security/performance/documentation agents.
- [x] 5.3 Resolve every round 1 finding and rerun all affected validation commands.
- [x] 5.4 Run a fresh multi-agent review round after remediation and repeat until every reviewer reports zero unresolved findings.
- [x] 5.5 Complete the spec-to-evidence audit, validate OpenSpec, mark all tasks complete, and archive the change before applying the next change.
