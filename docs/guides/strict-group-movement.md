# Strict group movement (experimental)

This opt-in extension strengthens the existing Group movement handshake. It
does not replace Group, go2, Rest, native Script supervision, or the safe-room
hold pilot. Existing profiles retain their previous behavior.

Set `group_strict_movement: true` in **every participant's profile**. The leader
must name the followers explicitly, on the same machine:

```text
;eohunter TeamProfile head Memberone Membertwo
;eohunter TeamProfile tail
```

Counts, an inferred roster and `lan` are not accepted for strict leaders. A
strict follower rejects a legacy leader and non-loopback endpoints. Both sides
need this build and native `Script#with_execution_guard` support; strict
admission refuses when that capability is missing. The existing transport assumes cooperating local processes;
these checks are safety and replay controls, not a sandbox against hostile code
running under the same operating-system account.

## Each hunting-room movement

The leader creates an episode tied to its current room/room refresh, hunt/run
identity and complete expected roster. Each follower lets its owned loot and
hand transaction finish, then records preparation after a completed engine turn.
The next turn publishes that evidence. Heartbeats and old reports cannot renew
it. The leader needs a recent completed turn too.

The final movement action checks local life, restraint, hard/cast RT, physical
group presence, cleanup/combat ownership and the full fresh acknowledgment set
at the actual native command-send boundary, including waits inside Lich's move
helper. It consumes the episode for one exact movement command. A native retry
needs a new episode; this action will not resend on the old permission.
Old, expired, duplicate or cancelled acknowledgments
cannot authorize a different step. A reconnect or Script-owner loss invalidates
the run; restart explicitly after recovery.

Muster runs below Rest, Loot, Loadout and Maintain in strict mode, so movement
preparation cannot starve those behaviors. Combat and emergency behavior retain
their existing priorities. Unsupported scripted exits and out-of-bounds hunting
travel request the existing Rest return instead of starting an uncoordinated
hunting go2 trip.

## Limits

This is an acknowledgment of preparation, **not an atomic group snapshot**.
A follower can enter RT after acknowledging; receipts expire after one second
and the whole episode after five seconds, but the game does not offer a
transaction that moves all participants atomically. Each room epoch is local
to its character and is never compared numerically across characters.

Outbound/return go2 travel, emergency movement and a separated follower's
existing catchup are not converted to per-step episodes here. The feature does
not itself provide a finite agent test, guaranteed return after peer loss, or
automatic recovery from a stopped script. Those need a separately reviewed
local test supervisor and explicit refuge/work/recovery allowances.

Offline protocol and behavior tests are not live hunting acceptance. The
finite two-member trial module remains an explicitly loaded development seam;
it is not enabled by this profile key or a registered LAB capability.

Lich guards do not nest. A controller already guarding the owner must explicitly
compose the action's `movement_guard_scope` policy into that guard for the
duration of the action, retain its own authority checks and remove the movement
policy afterward. This is a trusted local adapter, not a remote callback or an
unguarded fallback. Without such an adapter an already-guarded action refuses.

## Verification

Run the normal suite with `bundle exec rspec`. Protocol, behavior, profile and
two-process DRb fixtures are included. Native execution-guard tests additionally
require `LICH_EXECUTION_GUARD_ROOT` pointing to a reviewed Lich tree containing
`lib/common/script_execution_guard.rb` and the matching Script methods. They
are explicitly pending without that dependency. This is separate from
`LICH_COORDINATION_ROOT`, which selects the read-only transport/hold contract;
the two capabilities must not be assumed to ship in the same core revision.
