## MODIFIED Requirements

### Requirement: Workspace panels and refresh preserve stable presentation

Timeline, Inspector, composer, Devices, and header regions SHALL have stable semantic identity and independently controlled visibility. When Timeline and Inspector are both initially visible, the native horizontal split SHALL allocate approximately 70% of the available panel width to Timeline and 30% to Inspector, subject to maintained minimum widths and the native divider. The settled split SHALL retain that allocation until the operator resizes the divider or changes panel visibility. The operator SHALL remain able to resize the divider, and a sole visible panel SHALL expand into the available width.

Toolbar panel toggles and Inspector tab changes SHALL publish immediately. Ordinary Event refresh SHALL retain the existing Timeline, Inspector, composer, and chart containers while applying only semantically changed values.

Equivalent snapshots SHALL not publish. Data-only refresh SHALL disable implicit animation, coalesce high-frequency change notifications to the bounded cadence, and avoid removing and recreating whole conditional branches. No model mutation SHALL be initiated from within a SwiftUI render update.

#### Scenario: Events arrive at normal cadence

- **WHEN** a visible Timeline or Inspector already exists and new data arrives
- **THEN** affected rows or detail values update without whole-window flashing
- **AND** unrelated controls retain focus, scroll position, selection, and accessibility identity

#### Scenario: The operator changes an Inspector tab

- **WHEN** the tab selection changes without a new Event
- **THEN** the selected tab appears immediately
- **AND** the transition does not wait for another runtime publication

#### Scenario: Event panels first appear together

- **WHEN** the Event workspace first materializes with Timeline and Inspector visible and delayed layout has settled
- **THEN** Timeline retains approximately 70% and Inspector approximately 30% of the available horizontal panel width
- **AND** both panels satisfy their minimum widths and remain user-resizable

#### Scenario: Ordinary content updates after the split settles

- **WHEN** Timeline or Inspector content changes without an operator divider action
- **THEN** the existing divider position remains stable
- **AND** the panels do not redistribute to an equal split

#### Scenario: One Event panel is hidden

- **WHEN** the operator hides Timeline or Inspector
- **THEN** the remaining Event panel expands into the available horizontal space
- **AND** restoring both panels reintroduces the native adjustable divider without recreating unrelated workspace regions
