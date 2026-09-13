# Read-only coordination pilot

`EO::Engine::Coordination::Adapter` publishes a copy of the existing group
report and movement predicate through an explicitly supplied Lich coordination
session. Loading the engine does not create a session, listener, observer, or
adapter. No profile key or command-line mode enables it. This is programmatic
pilot wiring for the separately built coordination prototype.

The adapter has no movement, hold/release, command, or order-delivery interface.
The current group Hub/Member DRb transport, follower reports, and movement
barrier retain their existing behavior. These observations do not join or
release that barrier.

## Owner and policy reuse

`Engine#on_tick_completed` runs after the chosen behavior and watchdogs, before
the interval sleep. Paused turns complete after control is handed off. A turn
aborted in a start callback or by an exception does not complete. Each callback
receives World, the increasing completed-turn number, and owner status.
`Engine#on_tick` is still the start callback and is not progression evidence.

The adapter's `report_reader` should call `Group.report` with the current
owner's existing policy/counters and current looting state. Its optional
`movement_reader` calls the existing `Group::Leader#movement_ready?`. The
adapter does not reproduce either policy. These readers must only copy local
state; they must not query a remote member, issue game commands, or start work.
If an existing policy callback can do those things, it is unsuitable for this
read-only pilot.

An illustrative explicit attachment, after constructing an enabled prototype
session and an existing engine, is:

```ruby
pilot = EO::Engine::Coordination::Adapter.new(
  publisher: session,
  report_reader: ->(world) {
    EO::Engine::Group.report(
      world, name: character_name, rest_policy: rest_policy, counters: counters,
      looting: loot.looting?, now: nil
    )
  },
  movement_reader: leader.method(:movement_ready?)
)
pilot.attach(engine)
```

Reuse the exact policy inputs for the owner being observed, including any
forced rest reason, sneaky setting, preparation state, and encumbrance filter
when those apply. An omitted movement reader remains unknown; no substitute
follower movement policy is invented. `now: nil` avoids adding an unused
wall-clock timestamp to this projection. Session endpoint lifecycle and
discovery registration are explicit responsibilities of the pilot caller;
the adapter only calls the local in-memory `identity` and `publish` methods.

## What is and is not coherent

The copied identity, tick, room, readiness diagnostics and owner status are
recursively immutable before publication. The adapter samples identity,
World room, and optional native generation metadata before and after its
readers. A connection/incarnation, room generation, room identity, report
room, or owner status mismatch rejects the capture. It never refreshes the
last accepted projection after a failed capture or publisher refusal.

Those checks are fences, not a transaction with native writers. `Group.report`
and `movement_ready?` read World independently; vitals, roundtime and other
native state can advance while they run. Consequently this adapter always
publishes `readiness.coherence: "unknown"` and `readiness.ready: nil` with an
explicit limitation. Even a true legacy `movement_ready` diagnostic cannot
make the coordination client's final `ready` true. Roundtime and owned loot
are exposed as diagnostics, and unknown values stay nil.

There is no supported atomic native source reader wired in this pilot.
The combat tracker envelope discussed in the proposal is not assumed to be a
public snapshot reader or an atomic version for World, vitals, and ownership.
Adding another observer or taking an adapter-only mutex would not fix that
writer contract. A production positive-readiness path needs separate review
of a supported source synchronization contract.

An optional `source_reader.call(world)` may supply already owned metadata:

```ruby
{
  connection_generation: 1, room_epoch: 7, connected: true,
  room: { version: 5, age: 0.1, room_epoch: 7, connection_generation: 1 },
  readiness: nil
}
```

The caller must bind those native generations to the publishing session and
report actual source versions/ages. An absent reader leaves connection state,
room epoch, and source qualities unknown. Supplying metadata never certifies
the independent World reads as coherent. Source age is local elapsed age,
not a timestamp to compare with another process's monotonic clock; transport
freshness and repeated-version aging belong to the core session/client.
Endpoint liveness cannot increment the owner's completed tick. Neither an
idle parser nor an unchanged source version alone proves the game is stalled.

`pilot.last_projection` is the last immutable accepted copy, not a current
readiness guarantee. `pilot.last_error` identifies a mixed capture, rejected
publication, or capture failure without exposing raw exceptions or logs.
Optional adapter failures do not stop the hunting engine. The client must
still enforce identity, source quality, and age when reading cached data.

## Offline verification

`spec/eohunter/coordination_spec.rb` exercises real completed-tick ordering,
existing Group policy calls, immutable copies, room/connection/owner changes
during capture, missing sources, roundtime/looting diagnostics, stopped owner
progression, and optional publication failure. All worlds and publishers are
local fakes. Core process/transport tests cover protocol and freshness; no
live-game acceptance or movement migration is claimed by this adapter.

The optional `spec/eohunter/coordination_integration_spec.rb` uses the actual
paired Lich `Session`, native loopback transport and `Client`, with the real
engine callback and `Group.report` over a fake World. Run it by setting
`LICH_COORDINATION_ROOT` to that explicit checkout when invoking RSpec. It
checks that unknown observations survive transport, pings cannot freshen a
stopped owner, and reconnect fences prior readers. Without that environment
variable the cross-repository examples are pending; ordinary Hunter specs do
not depend on a second checkout.
