## MODIFIED Requirements

### Requirement: V1 TLS policy is fixed and inspectable

V1 SHALL require TLS 1.3 as both minimum and maximum, SHALL advertise only the `nearwire/1` ALPN token, and SHALL enable Network.framework peer-to-peer routing for App and Viewer parameters. Both roles SHALL enable TCP keepalive with fixed finite idle, interval, and failure-count values, and the idle value SHALL be shorter than 15 seconds so an otherwise idle transport emits a probe before the observed short AWDL route expiry.

#### Scenario: Policy plan

- **WHEN** either role constructs its TLS and TCP plan
- **THEN** TLS bounds, ALPN, ordered transport, peer-to-peer routing, and TCP keepalive values equal the V1 constants

#### Scenario: Idle peer-to-peer session

- **WHEN** a secure App/Viewer session carries no application Event for the keepalive idle interval
- **THEN** TCP is configured to probe the peer without consuming the Event protocol or rate-controlled queues
- **AND** probe failure remains finite rather than retaining an unusable transport indefinitely

#### Scenario: Unsupported override

- **WHEN** a caller attempts to request plaintext, another ALPN, a weaker TLS version, or disabled/unbounded keepalive through a supported API
- **THEN** no supported configuration API can express that override
