## ADDED Requirements

### Requirement: OpenSpec before apply

Every implementation change SHALL have a validated OpenSpec proposal, capability specifications, technical design when applicable, and task list before source apply work begins.

#### Scenario: Change enters apply

- **WHEN** an implementation task modifies production or test source
- **THEN** its OpenSpec artifacts already exist
- **AND** OpenSpec reports the change ready for apply

### Requirement: Sequential change delivery

Only one implementation change SHALL be in the apply and remediation phase at a time. The next change SHALL NOT enter apply until the current change has passed tests, completed zero-finding review, and been archived.

#### Scenario: Current change has unresolved findings

- **WHEN** any review finding or required verification remains unresolved
- **THEN** the current change remains active
- **AND** the next change does not begin production implementation

### Requirement: Test and documentation coverage

Every change SHALL include proportionate unit or integration tests, SHALL update affected documentation, and SHALL use English for new natural-language documentation, comments, user-visible strings, and specification artifacts.

#### Scenario: Change verification

- **WHEN** a change reaches review
- **THEN** changed behavior is covered by automated tests
- **AND** affected documentation is current
- **AND** new natural-language repository content is English

### Requirement: Multi-agent multidimensional review

Every implemented change SHALL be reviewed by at least three independent agent perspectives covering architecture and API design, correctness and test coverage, and security, performance, and documentation.

#### Scenario: First review round finds issues

- **WHEN** any reviewer reports an actionable finding
- **THEN** the finding is recorded in the change review evidence
- **AND** implementation and tests are updated
- **AND** another multi-agent review round runs after remediation

#### Scenario: Review gate passes

- **WHEN** the final review round completes
- **THEN** every required review dimension has a recorded report
- **AND** no unresolved finding remains

### Requirement: Evidence-based completion

Each change SHALL record the exact validation commands, results, review rounds, and residual limitations needed to prove completion against its specs and tasks.

#### Scenario: Change archive decision

- **WHEN** a change is considered complete
- **THEN** its task list is complete
- **AND** OpenSpec validation passes
- **AND** test and review evidence is present
- **AND** the change is archived before the next change enters apply
