# Coordination hold/release pilot

Status: draft pilot; offline coverage and bounded two-character live smoke pass.
Normal Hunter installation and profiles are unchanged.
Scope approved 2026-09-13 after the read-only two-character smoke.

This is an EOHunter-only follow-up to [#110](https://github.com/elanthia-online/eohunter/pull/110).
It shares that proposal's small completed-tick hook, but does not include or
require its read-only adapter. Whichever lands second should reconcile the
shared hook rather than duplicate it. It requires the bounded native transport
and identity schema in [lich-5 #1613](https://github.com/elanthia-online/lich-5/pull/1613),
without adding write operations to the read-only Session. This is not a general
Lich coordination interface yet. Do not merge until the native dependency is
available in the supported test package and maintainers approve this scope.

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
- `ticket` reserves a request ID and its immutable operation arguments. The
  receiver returns a random ticket valid for five receiver-local seconds.
  Retrying issuance returns the same ticket and never extends its lifetime.
- `submit` presents that ticket. Only `hold` and `release` exist; a release names
  the exact hold request ID. Admission returns `pending`, not successful action.
- `result` reconciles by request ID. An applied receipt is published only after
  the owner completes a tick. It records that tick and the effective engine
  state, not an assertion of current game readiness or observed game action.
- `hold` has a fixed 15-second lease from owner application. A second hold is
  refused until the first is released. No renewal operation in this pilot.
- Expired tickets cannot first execute. Late duplicates can read their existing
  result but cannot execute again. Conflicting reuse of an ID is refused.
- Keep at most 32 request reservations for the entire pilot run. Never evict a
  receipt and accidentally make an old ID executable again. At capacity start a
  new explicitly granted pilot, with a new run identity and token.

The receiver-issued ticket bounds issuance-to-use, NOT the age of a human's
original intent. Authentication does not supply freshness or idempotency.

## Owner and failure rules

The native socket worker only validates and updates bounded receipt state. The
engine's existing `on_tick` callback checks the current session identity and
local safe-room eligibility, then drains admitted requests. Its
`on_tick_completed` callback confirms the resulting engine state. No second
Script supervisor or child registry is created: the bounded request/receipt
table is coordination bookkeeping only.

Safe eligibility must explicitly be true on every tick; exceptions, nil,
leaving the declared room, death, or a reconnect fail closed. The caller must
provide a local connection/eligibility reader, and wire it to the real session
owner. The pilot cannot infer a game reconnect from an open socket.

A lost grant, endpoint closure, or expired active lease stops the empty engine
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
5. Reconnect, safety loss, grant closure and lease expiry stop without auto-resume.
6. A manual hold arriving during a peer hold survives peer release.
7. Paired native socket test, then two independent processes with explicit tokens.
8. Safe-room live smoke only after installing the tested build and verifying both
   characters and scripts. Keep private token files out of logs and repositories.

The read-only adapter still reports unknown coherence. Hold confirmation does
not make shared movement readiness coherent or enable group travel.

## Reproducing the offline contract

Point `LICH_COORDINATION_ROOT` at a checkout of lich-5 #1613 (tested commit
`c5da7b5f3d26ba6dd0df63186b3161ef50a2129a`), then run:

```sh
LICH_COORDINATION_ROOT=/path/to/lich-5 bundle exec rspec
bundle exec rubocop
bundle exec rake build
bundle exec rake doc
```

Without that variable the native integration examples are explicitly pending.
The dedicated coordination workflow pins the above commit and runs all 33
focused cases, including a forked peer over the actual native loopback endpoint.
Default Hunter startup does not require or enable the optional Lich prototype.

## Test evidence (2026-09-13)

- Original integrated branch (including #110): 897 examples, zero failures
  (seed 62039). The exact publication branch omits #110's independent adapter
  tests: 874 examples, zero failures with the pinned native dependency (seed 719).
- 33 focused cases cover ownership, the protocol and failure handling, including
  an actual forked peer talking to the native bounded endpoint.
- Rubocop: all 83 Ruby files, no offenses. YARD: 100% documented.
- Single-file build and Ruby compilation pass.
- The exact private live-smoke script also runs in two independent Ruby
  processes against fake Worlds. All nine checks pass, with no game commands
  and private credential files removed. This rehearsal caught an unknown-receipt
  `false`/`nil` mistake in the diagnostic before deployment.
- Receipt `owner_age` increases without owner progress; reading it cannot
  refresh the recorded application time. Unknown death/RT values or a creature
  arriving in the declared room fail closed.

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

The private character-specific launcher and raw game logs are not distributed
with this PR. The portable protocol spec is checked in. Live checks covered
identity, hold/release, duplicate delivery, preserving a local manual pause,
and teardown; expiry/reconnect/failure cases were tested offline, not in game.
