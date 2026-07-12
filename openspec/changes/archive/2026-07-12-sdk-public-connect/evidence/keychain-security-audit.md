# Keychain and Security Audit

## Production query inventory

The installation identity operations interface exposes exactly three operations: read, add, and random bytes. It has no update, delete, prompt, retry, sleep, polling, logging, or reflection operation.

The read dictionary contains exactly seven attributes:

1. generic-password class;
2. service `com.nearwire.sdk.installation-identity`;
3. account `default`;
4. data-protection Keychain selection;
5. return-data true;
6. match-limit one;
7. authentication UI skip.

The add dictionary contains exactly six attributes: class, service, account, data-protection selection, `WhenUnlockedThisDeviceOnly`, and the 36-byte identity data. Synchronizable, access group, access control, label, comment, and override attributes are absent.

`testLiveKeychainTranslationUsesOnlyReviewedSecurityConstants` bridges every abstract key and value to the actual Security.framework constants. `testIdentityHitUsesExactReadDictionaryOnly` and `testIdentityMissingGeneratesV4AndAddsExactAttributes` compare complete dictionaries. The transcript matrix proves bounded read/random/add counts for hit, miss, duplicate winner, protected duplicate, malformed/noncanonical data, unexpected type, access failure, random failure, random-length failure, and add failure.

## Identity and isolation

- Missing identity requests exactly 16 bytes from `SecRandomCopyBytes`, sets RFC 4122 V4 and variant bits, serializes once, and adds once.
- Stored data must be exactly 36 UTF-8 bytes and canonical lowercase UUID text.
- Duplicate add performs exactly one reread and then succeeds or fails closed.
- Work runs in a detached worker retaining only the operations adapter. It does not retain `NearWire`, the lease, pairing input, metadata, endpoint, certificate, or Event.
- Public orchestration claims the process lease before identity access. Claim failure and cancellation-after-claim tests prove zero identity calls where lower-stage work is unauthorized.

SwiftPM and CocoaPods attach Apple's `Security.framework` only to the SDK product/subspec. Core remains dependency-free.
