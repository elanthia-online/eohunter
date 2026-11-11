# Troubleshooting

What the engine prints, what each stop means, and what to collect when
reporting.

## The lines

Every decision is an `eohunter:` line. The ones worth knowing:

| Line | Meaning |
|---|---|
| `hunting: survival, cleanse, ...` | the engine started with these behaviors |
| `engaging <name> (routine a)` | Engage took a target and which routine it will run |
| `resting: <reason>` | Rest decided to go home; the reason is the profile rule that fired (fried, oom, encumbered, wounded, a follower's reason) |
| `fleeing: <reason>` | Flee is leaving: the count, a name, a message, a hazard, an ambusher |
| `cleanse: <reason>` | Cleanse is treating something |
| `DISARMED: <noun> in room <id>` | the disarm was seen; Cleanse's recovery runs |
| `loadout <wanted>: <reason>` | the configured hunting hands could not be restored; a solo hunt or leader returns to rest before stopping |
| `could not reach <room>` | five go2 attempts at a room failed; on the way home Rest waits a minute and tries again, `trying <room> again (n of 3)` |
| `stranded: could not reach <room> from <here>` | three rounds failed; Rest preps and rests where it stands, and does not report `rested:` (the bounty child does not exit) |
| `watchdog: <kind> in <behavior> (<count>)` | the engine stopped itself; see below |
| `stopped: <reason>` | the engine ended and why |
| `<Error>: <message>` with frames | an exception in the engine; the frames are the engine's own |

## Stops

**`watchdog: repeated_failures in <behavior> (5): <reason>`.** Five
commands in a row went to the game and were refused or never answered:
a target that is not there, a command the character cannot do, a
container that does not open. The reason after the count is what the
last one answered, and the line under it is the game's own words when
the action read one, so the stop usually names its own cause. The line
after that says which behaviors above it declined the tick, so you can
tell "Engage kept swinging" from "Rest could not walk".

A tick the character simply could not act on does not count here.
Being stunned or webbed, a technique on cooldown, too little stamina,
a target that died while roundtime ran: those are skipped, not failed,
because nothing was sent. If the hunt stops with this line, a command
really did go out five times and the game really did refuse it.

**`watchdog: fire_budget in <behavior> (61)`.** A behavior put more
than sixty commands on the wire in a minute, faster than roundtime
allows a real action. It was looping on successes: a retarget that
never lands, a search that never clears, a stance flip. Only commands
the game actually received count: a routine line the behavior refused
itself (a spell gate, a stance it was already in) is not a fire,
whatever status it reported. The declining behaviors are printed as
above.

**`stopped: dead`.** Death, with `dead_man_switch` and `depart_switch`
off. **`stopped: deader`.** A dead player in the room during the hunt
with `deader` on. **`stopped: leader_lost` / `member_lost`.** The group
link went quiet past its deadline. **`stopped: engine_error`.** An
exception; the message and frames are printed.

**`eohunter: this Lich lacks <constant>; update Lich to 5.22.0 or later`.**
The Lich running is older than 5.22.0, the first release with the core
features the engine needs. Update Lich; see
[Core dependencies](core-dependencies.md).

**`stopped: loadout_stuck`.** The configured item was missing,
inaccessible, invalid for both hands, or did not reach the requested
hand. The preceding `loadout ...` line gives the exact desired state
and Lich::Stash error. Resolve the inventory or ReadyList entry before
restarting. The failure is attempted once per hunt, then requests the
existing return lifecycle. Followers use the leader's resting room;
a solo profile without one stops with the diagnostic where it is.

## The debug trace

The lines above are what the engine says on its own. The debug trace is
everything it thinks: every event on the bus, filed under a category,
and on request one line per tick saying who held it and why everyone
above declined. bigshot's `debug` has the same shape (a switch,
categories, a file with the game feed mirrored in); here the categories
are the event names, so nothing is left out by accident.

```
;eohunter debug                     what is on
;eohunter debug on | off            the trace; lines go to the front end, or to the file when that is on
;eohunter debug all                 every category
;eohunter debug combat,group        only these (from all), or these as well (from a list)
;eohunter debug rest off            this category no more
;eohunter debug tick [on|off]       one line per engine tick
;eohunter debug file [on|off]       write to logs/debug/<game>-<char>/eohunter.log instead of the front end
;eohunter debug feed [on|off]       mirror the raw game feed into that file too (file must be on)
;eohunter debug help                the same, in game
;eohunter <profile> debug           start a hunt with the trace on; `debug=combat,movement` for a subset,
                                    `debug file`, `debug tick` and `debug feed` set those as well
```

The categories: `combat` (engaged, each routine line started and
resolved with the creature's health and status, disengaged with how long
and how many commands it took), `movement` (trips, rooms, bounds),
`rest`, `group` (orders, holds, the looter), `recovery` (flee, cleanse,
death, disarm, loadout), `bounty`, `engine` (start, stop, preemption,
the watchdog, the tick line).

The settings persist per character, and a running hunt picks a change up
within a tick, so `;eohunter debug tick` from a second window turns the
tick line on in the hunt already running. While the file is on the hunt
says so at start and at exit, since a forgotten trace grows; the file is
rolled to `.1` at 20 MB when a run opens it.

A stretch of a solo hunt with everything on reads like this. The `>>>`
and `<<<` lines are the feed mirror, so the game's actual words sit
between an action's start and its result:

```
21:14:03.405 engine   8030   tick #6 holder=engage status=success reason=targeted | declined: survival=none flee=none rest=none loot=none
21:14:03.405 combat   8030   engaged target=223891 name="greater kappa" routine=a
21:14:03.661 combat   8030   routine_action_started target=223891 name="greater kappa" routine=a command=attack resources=mana:84,health:150,spirit:10,stamina:100 hp=100 status=""
21:14:03.662 >>> attack #223891
21:14:04.010 <<< You swing a vultite claidhmore at a greater kappa!
21:14:06.903 combat   8030   routine_action_resolved target=223891 name="greater kappa" routine=a command=attack status=success reason=- line="" resources_before=... resources_after=... hp=61 status=prone
21:14:10.421 combat   8030   disengaged target=223891 name="greater kappa" status=dead why=no_target engaged_for=7.0 commands=2 hp=0
21:14:10.422 engine   8030   tick #33 holder=loot status=success reason=corpses | declined: survival=none flee=none rest=not_fried
```

Grepping the file for one creature's id gives its whole fight. `rest=not_fried`
on the tick line is Rest's own reason for declining, which is the answer
to "why is it not resting yet".

## Common causes

- **A room did not resolve.** `dry` prints the hunting room and the
  boundaries; a blank one means the id or `u<uid>` in the profile is not
  in your map. The resting room is not in the report, so check it in the
  profile directly. Fix the profile, not the engine.
- **Every routine line is skipped.** A modifier is vetoing all of them.
  `dry` prints the compiled routine with its modifiers; check for a
  `!` that is inverted, or a buff word whose buff name changed.
- **The hunt never starts.** Wander wants the claim to be ours; in a
  shared area another hunter's claim makes it wait. Survival or Cleanse
  may be holding the tick: a stun, a web, a hazard in the room.
- **Loot never happens.** The looter in a group is the leader's
  `ma_looter`; a follower loots only when told. `delay_loot` waits
  fifteen seconds after the kill.
- **A creature is never attacked.** It is not in `targets`, or it is in
  `invalid_targets` or CharSettings' untargetable list, or an ASSESS
  matched `boons_ignore`, or Lich's GameObj.targets excludes it (dead,
  an appendage, an animated decoy).

## Reporting

The useful things: the `eohunter:` lines around the problem, the game
text just before it, your profile name, and the Lich version line from
`;version`. For a group problem, the leader's and the follower's lines
both. Report to Nisugi, or open an issue on the repo with those pasted.
