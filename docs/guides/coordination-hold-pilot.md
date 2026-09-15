# Coordination hold/release pilot

This draft adapter consumes the independently distributed
[`libeocoordination` library](https://github.com/elanthia-online/eohunter/pull/115).
It shares [#110](https://github.com/elanthia-online/eohunter/pull/110)'s completed-
tick hook, but does not require its read-only adapter. Whichever lands second
must reconcile that shared hook. The local policy and library contract match
the hold adapter in [#114](https://github.com/elanthia-online/eohunter/pull/114);
that broader group-transport integration remains a separate proposal.

The library owns bounded transport, pair identity, tickets, replay protection,
capacity and receipts. EOHunter owns safe-room eligibility and local pause/resume
policy. This draft depends on a compatible library release (API 0.1.0); it does
not depend on the closed Lich core coordination proposal. The library's runtime
integration requirements are documented with #115.

## Scope and explicit setup

Two independent character processes stay in a declared safe room. One owns an
empty Hunter engine (`behaviors: []`); its explicitly granted peer may request
`hold` and `release`. Loading Hunter is inert. No normal profile or command-line
mode enables the pilot, and it sends no movement, combat or game commands and
starts no child scripts.

The caller creates a compatible `EO::Coordination::Session`, establishes its
connection lifecycle, and supplies the exact peer identity, a dedicated control
token, the designated safe room, and a local eligibility reader. The adapter
loads `libeocoordination` on explicit construction if necessary and checks its
API version. The caller must invoke `start` and close the adapter in `ensure`
on the engine owner thread. Admission can be revoked from another thread;
only an owner turn can confirm local cleanup.

`Controller::Runtime#request('hold')` initiates a supervised return to safety;
this pilot uses `Engine#pause!` / `resume!` with a local ownership key.
Manual no-argument pauses remain independent. The peer can release only its
own exact hold, and a manual resume cannot clear the coordination hold.

The adapter refuses engines with behaviors. Pausing all behaviors in a real
hunt would also pause survival, so this pilot does not authorize normal hunting
integration. The read-only adapter still reports unknown coherence; a hold
receipt does not establish shared movement readiness or enable group travel.

## Request and owner contract

- One endpoint binds one exact session/run, one pinned peer identity and one
  separately supplied control token. Use a different token from the read
  endpoint. Same-user credentials prevent accidental use, not hostile
  impersonation by another process with access to those credentials.
- The library reserves an immutable request ID and arguments using a ticket
  valid for five receiver-local seconds. Retrying does not extend its deadline.
  Only `hold` (no arguments) and `release` (an exact `hold_id`) are granted.
- Submission returns `pending`. A completed engine turn takes at most one
  request; the following start callback checks safety and applies local policy.
  That turn's completed callback settles the receipt with its observed outcome.
- A receipt remains `running` until settlement. Its owner tick and engine state
  describe that observation, not current game readiness. An interrupted effect
  has an `unknown` outcome; admission or a network reply never proves success.
- An applied hold has a fixed 15-second local safety window. Another hold is
  refused while active. There is no renewal or resource-allocation interface.
- Duplicate delivery cannot reapply an operation or renew a hold. Conflicting
  request-ID reuse is refused. The library bounds receipts and retains replay
  protection for the grant; capacity requires a new explicit grant.
- A release settles only after the owner relinquishes the exact local hold.
  Applied holds keep cleanup pending until release or fail-closed owner cleanup.

Tickets bound issuance-to-use, not the age of a human's original intent.
The library socket worker validates and updates bounded receipt state; it never
executes Hunter policy. There is no Hunter socket protocol, receipt store,
discovery registry or second Script supervisor.

## Safety and failure

Every owner turn must positively establish the same session identity, designated
room, no live creatures, no death, no roundtime/cast roundtime, and explicit
local eligibility. Missing/unknown safety values, eligibility exceptions,
leaving the room, death or reconnect fail closed. The caller must wire real
connection state into eligibility; an open loopback socket cannot prove a live
game connection.

Revocation or expiry of the active hold window stops the empty engine and
relinquishes only this adapter's pause. Manual holds survive; it never resumes
autonomous work. A stalled owner cannot acknowledge expiry or cleanup until it
ticks again. Network timeout, request expiry and confirmed cleanup are distinct
facts. Native Script still owns script lifetime and shutdown.

## Offline verification

Point `EO_COORDINATION_ROOT` at the `scripts` directory of the #115 checkout:

```sh
EO_COORDINATION_ROOT=/path/to/eohunter/scripts bundle exec rspec
bundle exec rubocop
bundle exec rake build
bundle exec rake doc
```

Without that variable the optional library integration examples are pending.
The paired suite exercises the actual bounded loopback endpoint, including a
forked peer, over fake Worlds. It covers completed-turn ordering, independent
manual holds, exact release targeting, revocation/reconnect, hold expiry, safety
loss and interrupted effects. Every adapter example asserts zero game commands.
The library's own suites cover protocol authentication, ticket expiry, replay,
conflicting request IDs and bounded receipt capacity.

These offline checks establish the bounded adapter contract only. Historical
safe-room experiments do not establish acceptance of this revised branch, and
no live-game or group movement acceptance is claimed here.
