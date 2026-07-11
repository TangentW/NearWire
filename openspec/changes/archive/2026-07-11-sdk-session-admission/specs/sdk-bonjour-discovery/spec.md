## MODIFIED Requirements

### Requirement: Matching does not establish trust

A matched result SHALL mean only that one advertised service has the requested public instance name. It SHALL NOT imply Viewer authentication, certificate continuity, connection acceptance, session activation, or event delivery.

The later session-admission layer SHALL still establish mandatory TLS, fully decode one Viewer hello, derive `ViewerDiscoveryDiscriminator` from that hello's exact installation ID, and require equality with the discovered `vid` before negotiation. Mismatch SHALL fail admission. Equality SHALL provide only advertisement/hello consistency and SHALL NOT bind the connection-local certificate or establish authentication.

Distinct valid `vid` values provide only best-effort collision detection. Missing, invalid, identical, or spoofed discriminators, and a publisher change between browsing and later DNS-SD resolution, MAY remain indistinguishable. Neither `vid`, a matching count, an unambiguous result, nor a matching Viewer hello SHALL authorize a security decision.

#### Scenario: Exact result is found

- **WHEN** discovery reports one matched endpoint
- **THEN** the later secure-connection layer must still establish TLS and complete protocol admission

#### Scenario: Hello identity differs

- **WHEN** the later Viewer hello derives a discriminator different from the matched advertisement
- **THEN** session admission fails before negotiation

#### Scenario: Identical discriminator cannot prove one publisher

- **WHEN** two exact advertisements carry the same valid `vid`
- **THEN** discovery merges them as one logical registration
- **AND** does not claim they originated from the same Viewer
