# Coordination hold/release pilot

Status: draft Adapter; predecessor live smoke passed, coordination-library rewrite
has offline coverage and still requires its own safe-room live smoke.
Normal Hunter installation and profiles are unchanged.
Updated 2026-09-14 after the generic coordination library was built.

This is an EOHunter-only follow-up to [#110](https://github.com/elanthia-online/eohunter/pull/110).
It shares that proposal's small completed-tick hook, but does not include or
require its read-only Adapter. Whichever lands second should reconcile the
shared hook rather than duplicate it. It requires the generic
[`libeocoordination` library](https://github.com/elanthia-online/eohunter/pull/115).
The library owns bounded transport, pair identity, tickets, replay protection,
capacity and receipts. EOHunter owns only safe-room eligibility and the local
pause/resume policy. Do not merge until that library dependency and its narrow
[Lich hook-priority seam](https://github.com/elanthia-online/lich-5/pull/1621)
are reviewed and available in the supported test package.

## Smallest useful test

Two independent character processes remain in a declared safe room. One owns an
empty Hunter engine (`behaviors: []`); the other can request `hold` and `release`.
The owner applies requests on its own ticks. No movement, combat, child scripts,
game commands, automatic discovery, or ordinary hunting profile changes.

`Controller::Runtime#request('hold')` initiates a supervised return to safety;
that is deliberately NOT the operation used here. The pilot reuses
`Engine#pause!` / `resume!` with a local ownership key. Legacy no-argument calls
still operate the manual hold. A peer can release only its own exact hold, and a
manual resume cannot clear a coordination hold either.

The pilot refuses engines with behaviors. Pausing all behaviors in a real hunt
would also pause survival; this pilot does not authorize that. A later hunting
integration needs a separate policy review, not removal of this check as setup.

## Grant and request contract

- Explicit construction and `start` are required. Loading Hunter is inert.
- One endpoint, one exact owning session/run, one pinned peer identity, one
  separately supplied control token. Callers must supply a different token from
  the read endpoint; only this control token authenticates requests here.
- Full target and peer identities accompany every request. Same-host/same-user
  credentials prevent accidental use, not hostile same-user impersonation.
- The library's `ticket` operation reserves a request ID and its immutable arguments. The
  receiver returns a random ticket valid for five receiver-local seconds.
  Retrying issuance returns the same ticket and never extends its lifetime.
- `submit` presents that ticket. Only `hold` and `release` exist; a release names
  the exact hold request ID. Admission returns `pending`, not successful action.
- `result` reconciles by request ID. The library receipt stays `running` until a
  later owner tick has applied and observed the local policy result, then becomes
  `settled` with a separate outcome and cleanup state. It records the exact owner
  and peer generations, owner tick, and effective engine state; it is not an
  assertion of current game readiness or observed game action.
- `hold` has a fixed 15-second local safety window from owner application. A
  second hold is refused until the first is released. There is no renewal
  operation in this pilot.
- Expired tickets cannot first execute. Late duplicates can read their existing
  result but cannot execute again. Conflicting reuse of an ID is refused.
- The coordination library keeps a bounded receipt table and never evicts replay
  protection during a grant. At capacity start a new explicitly granted Adapter,
  with a new run identity and token.

The receiver-issued ticket bounds issuance-to-use, NOT the age of a human's
original intent. Authentication does not supply freshness or idempotency.

This local hold window is not the generalized resource-lease Interface proposed
after pressure-testing the coordination contract with a production DR consumer.
It neither arbitrates a contended resource nor transfers ownership. Expiry stops
the empty engine and begins truthful cleanup; it never resumes autonomous work.
Future resource leases need their own acquire/renew/release/reclaim lifecycle,
atomic storage Adapter and fencing generation. EOHunter remains only a consumer
of that contract and must not embed transport or allocation policy.

## Owner and failure rules

The library socket worker only validates and updates bounded receipt state. After
an EOHunter owner turn completes, `on_tick_completed` takes at most one admitted
request. The following `on_tick` checks current session identity and local safe-
room eligibility before applying it, and the next completed callback settles the
library receipt. This deliberately costs an owner turn so neither admission nor
an interrupted effect is reported as success. No second Script supervisor,
child registry, socket protocol, or EOHunter receipt store is created.

Safe eligibility must explicitly be true on every tick; exceptions, nil,
leaving the declared room, death, or a reconnect fail closed. The caller must
provide a local connection/eligibility reader, and wire it to the real session
owner. The pilot cannot infer a game reconnect from an open socket.

A lost grant, endpoint closure, or expired active hold window stops the empty engine
on its next owner tick; it does not resume into autonomous work. Manual holds
remain intact. A stalled owner stays held but cannot acknowledge expiry or
cleanup until it ticks again. Network timeout, operation expiry, and completed
cleanup are separate facts. Shutdown must be invoked by the owning script in
ensure; stopping the script is still native Script's responsibility.

Receipts include `cleanup` (`not_required`, `pending`, `complete`). An applied
hold keeps cleanup pending until that exact hold is released or the owner has
stopped and relinquished the pilot's local hold. A network response alone never
proves that cleanup happened. A terminal receipt's tick/state describes its
observation then, not a live status poll.

## Verification before live use

1. Legacy pause/resume semantics, independent manual and peer holds.
2. Pending before owner tick; applied only after completion; zero game sends.
3. Duplicate delivery, conflicting IDs, expired first delivery, bounded capacity.
4. Exact release target, wrong peer/token/run/generation, closed owner.
5. Reconnect, safety loss, grant closure and hold expiry stop without auto-resume.
6. A manual hold arriving during a peer hold survives peer release.
7. Paired library socket test, then two independent processes with explicit tokens.
8. Safe-room live smoke only after installing the tested build and verifying both
   characters and scripts. Keep private token files out of logs and repositories.

The read-only adapter still reports unknown coherence. Hold confirmation does
not make shared movement readiness coherent or enable group travel.

## Reproducing the offline contract

Point `EO_COORDINATION_ROOT` at the `scripts` directory in an eohunter #115
checkout, and `LICH_EXECUTION_GUARD_ROOT` at lich-5 #1575, then run:

```sh
EO_COORDINATION_ROOT=/path/to/eohunter/scripts \
LICH_EXECUTION_GUARD_ROOT=/path/to/lich-5-guard bundle exec rspec
bundle exec rubocop
bundle exec rake build
bundle exec rake doc
```

Without those variables their integration examples are explicitly pending. The
focused Adapter suite includes a forked peer over the actual library loopback
endpoint. Default Hunter startup does not require or enable the optional
coordination library.

## Test evidence (2026-09-13)

- Coordination-library Adapter: 950 examples, zero failures in the predecessor
  integrated run (seed 719); focused policy cases include an actual forked peer
  talking over the bounded loopback endpoint.
- The refactor removes EOHunter's duplicate transport, ticket, replay and receipt
  Implementation: 215 inserted lines against 350 removed across code and specs.
- Scoped Rubocop reports no offenses. Single-file build and Ruby compilation pass.
- The exact private live-smoke script also runs in two independent Ruby
  processes against fake Worlds. All nine checks pass, with no game commands
  and private credential files removed. This rehearsal caught an unknown-receipt
  `false`/`nil` mistake in the diagnostic before deployment.
- Unknown death/RT values or a creature arriving in the declared room fail
  closed. An effect interrupted before its confirming owner turn is reported as
  `unknown`, never successful.

The user explicitly launched the private diagnostic on Calvix and Skooshii in
safe room 324. All nine live checks passed at 10:32:51 +07, and both scripts
exited. Fresh LAB observations then confirmed both characters remained alive,
in room 324, with zero RT, no creatures and no active controller ownership.
Temporary grant files were removed. Neither normal hunting profiles nor the
normal Hunter installation were modified for this test.

The private test uses an empty engine, checks native game-connection thread
identity/liveness and room safety throughout, and prohibits every game command
and child start using native Script execution guards. Its first launch exposed
a diagnostic-only bug: a deny-all policy also rejected nil execution checkpoints.
That was corrected to allow nil checkpoints while still denying command strings;
three tests against the actual native guard and the repeated two-process
rehearsal passed before the successful live retry. No Lich guard change was made.

The private character-specific launcher and raw game logs are not distributed.
The predecessor live checks covered
identity, hold/release, duplicate delivery, preserving a local manual pause,
and teardown; expiry/reconnect/failure cases were tested offline. Because this
revision replaces that transport Implementation with the external library Interface,
it still needs a short safe-room live smoke before merge.
