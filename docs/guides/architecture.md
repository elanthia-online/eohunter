# Architecture

eohunter is an engine of small behaviors over a read-only view of the
game, with one contract for every command it sends. This page is the
map: the pieces, the tick, and where each kind of rule lives. The API
reference for each class is in the YARD docs; the rules themselves,
with bigshot line references, are in the engine plan.

## The pieces

| Piece | File | What it is |
|---|---|---|
| Engine | runner.rb | the tick loop and priority arbiter; the watchdogs; pause and stop |
| Behavior | behavior.rb | a priority, `wants_control?(world)` and `tick(world)` |
| Actions | actions.rb | the contract every game command follows: preconditions, roundtime, send, confirm, Result |
| World | world.rb | the read-only facade over Lich's parsed state: Me, RoomView, Hands, routing, claim, hidden creatures |
| Events | events.rb | an in-process bus: emit, subscribe, await with a timeout |
| Watch | watch.rb | the subscription to Lich's combat observers; game facts become events |
| Travel | travel.rb | go2 supervised a tick at a time, one trip owning it, suspended on preemption |
| Profile | profile.rb | a bigshot YAML into the behaviors' policies |
| Targets | targets.rb | which creatures to fight, with which routine, in which order |
| Loadout | loadout.rb, loadout_selection.rb | optional hand policies and ordered named-set selection; all item movement delegates to Lich::Stash |
| Group | group.rb | the leader's Hub over DRb, the follower's Member, and the follower behaviors |
| Controller | controller.rb | opt-in supervision for Lich Agent Bridge; not part of ordinary hunting |

The behaviors, one file each, are listed below. The script,
`eohunter.lic`, is the wiring: it loads the engine, reads the profile,
builds the behaviors, installs the watch, and runs the loop.

## The tick

About four times a second the engine:

1. runs its tick callbacks (the group heartbeat, the follower's report);
2. announces a room change, so room-scoped state resets before anything acts;
3. asks each behavior in priority order `wants_control?(world)` and stops at the first yes, keeping the trace of who declined;
4. hands control over, telling the behavior that had it last that it was preempted, so a trip in flight is suspended;
5. calls `tick(world)` on the chosen behavior, which issues at most one action and returns its Result;
6. feeds the Result to the watchdogs.

Intent is re-derived from World on every tick. Behaviors hold no
positional state; what they remember is bookkeeping (what was looted,
which room was blocked, when the last attack order went out).

| Priority | Behavior | Owns |
|---|---|---|
| 0 | Survival | dead, escape rooms, standing up, pulling a member up, dead players and members |
| 5 | Cleanse | all of ecleanse: afflictions, hazards, disarm recovery, hive traps; Troubadour's Rally |
| 10 | Flee | `should_flee?` and the ambusher, one step out per tick |
| 15 | Muster | the leader's holds between fights |
| 20 | Rest / Orders | the rest cycle with every group wait, the final loot, the walk out; a follower runs orders instead |
| 30 | Loot | each corpse once, the room, the loot script, the fried bookkeeping |
| 35 | Loadout | restore the configured hunting hands after a temporary owner finishes |
| 40 | Maintain | signs, Assume Aspect, bless, wrack |
| 50 | Engage / Assist | the routine language, one line per tick; a follower takes the leader's target first |
| 60 | Wander / Follow | steps, hides, waits, tracking, hidden-creature holds; a follower walks back to the leader |

Loadout deliberately sits below every temporary hand owner. Its
predicate only compares the current snapshot with cached ReadyList or
previously resolved item IDs; its action delegates the complete two-hand
transaction to `Lich::Stash.hands`. Engage and Assist explicitly own
the hands while their current target and routine remain selected, preventing a
between-step restore from interrupting combat. A priority or Assist target
change releases the previous routine's ownership. Engage also checks the
handoff immediately before taking the next target, so state changes after
arbitration cannot silently bypass equipment preparation. Selection consumes
the existing target choice and parsed classification; it never picks another
monster or performs inventory commands.

## Actions

An action is a class with `preconditions` (a reason or `:ok`) and
`perform`. `call` runs the preconditions, settles roundtime, performs,
and returns a `Result` with a status (`:success`, `:failed`, `:timeout`,
`:skipped`), a reason, and the game line that decided it. Sending goes
through three helpers:

- `send_through_ladder`: Lich's bounded `fput`, which resends on the
  game's transient refusals (roundtime, stun, webbed) and reports the
  permanent ones as failures;
- `send_and_match`: send once and wait for one of the given answers;
- `send_and_observe`: send and wait for an event from the watch.

Nothing sends a command and hopes. A refused command is a failed action
with the refusal as its reason, and the caller decides what that means.

The two are kept apart deliberately. A gate that refuses before
`perform` returns `:skipped`: the preconditions, the target that died
during the roundtime wait, our own death, the engine's interrupt. None
of them reached the game, so the action declined itself. `:failed` means
a command went out and the game refused it or never answered, which is
what the repeated-failures watchdog counts. Without that split an
ordinary stun read as five failures in five ticks and stopped a live
hunt in about a second with nothing on the wire, where bigshot's
`bs_put` waits the stun out and carries on.

## World

World is the only place that reads Lich globals. Everything it exposes
is a plain value: `me.health_pct`, `me.prone?`, `room.targets`,
`hands.right`, `claim_mine?`, `hidden_target_ids`. Under it are Lich's
own readers: Status for the muckle states, the `check*` globals for
posture, GameObj.targets for the fightable list, Injured for the
ability gates, Experience for the exact numbers, Map for routing.

The source accessors (`xmldata`, `gameobj`, `status`, `spell`, `map`
and the rest) are the spec seam: a spec stubs those and fakes any state
without a game. Lich reads that can raise are rescued to a safe default
at that seam and nowhere else.

## Events and the watch

Momentary facts travel on the event bus; durable facts live in World.
The watch subscribes to Lich's combat observers and Combat::Messages
once, from the running script, and turns their facts into engine
events: an incoming swing, an ally's attack, a disarm, a hive trap, an
arriving ambusher, the endroll of our own attack. Behaviors and actions
subscribe to what they need and unsubscribe when done.

When Lich emits `definitions_reloaded`, Watch reads the current
`Combat::Messages.events` and replaces its named message subscription.
Added names become available immediately and removed names stop being
forwarded; the reload payload is not an event-name registry. Uninstall
removes the current handlers, including the reload listener.

## Travel

A trip is go2 started with a room, supervised one tick at a time. One
trip owns go2; a behavior that is preempted has its trip suspended (the
script killed) and resumed when it has control again. Rest, Wander,
Cleanse and the follower's Follow all travel this way.

## Groups

The leader serves a Hub over DRb. Followers push a Report into it every
tick and pull their Orders from it, so the leader never makes a remote
call, and a follower that stops reporting is seen as lost rather than
raising into the leader's loop. Every follower call is bounded; a Hub
that stops answering is a lost leader. Orders, acks and the hunt id
carry through every exchange.

## The watchdogs

Two of them, both in the engine. Five failed actions in a row means the
model of the world is wrong. A behavior acting more than sixty times in
a minute, faster than roundtime allows, means it is looping on
successes. Either stops the engine and reports the behavior and which
behaviors above it declined that tick. Skipped lines and silent ticks
are not fires; the trip behaviors opt out of the fire budget since a
walk legitimately steps rooms faster than that.

## Where a rule lives

The engine plan (`docs/hunting-engine-plan.md`) has every rule read
from bigshot 5.16 and ecleanse 2.3.6 with the line references, one
section per behavior. The core consumption audit
(`docs/core-consumption-audit.md`) says, file by file, what Lich does
for the engine and what the engine still does itself. When something
looks wrong in a hunt, those two files say what the behavior was meant
to do and where in bigshot to compare.
