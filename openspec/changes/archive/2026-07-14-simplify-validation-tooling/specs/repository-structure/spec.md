## MODIFIED Requirements

### Requirement: Authoritative monorepo roots

The repository SHALL use root-level `Core`, `SDK`, `Viewer`, `Demo`, `IntegrationTests`, and
`Documentation` directories, and SHALL keep `Package.swift`, `NearWire.podspec`,
`NearWire.xcworkspace`, `VERSION`, `README.md`, and `LICENSE` at the repository root. The repository
SHALL NOT require a custom validation-script directory when maintained product tests and standard
toolchain commands provide the required verification.

#### Scenario: Repository structure is inspected

- **WHEN** a clean checkout is inspected
- **THEN** every required root entry exists at its specified path
- **AND** no nested `Package.swift` or additional podspec exists below the repository root
- **AND** routine verification does not depend on a repository-specific `Scripts` directory
