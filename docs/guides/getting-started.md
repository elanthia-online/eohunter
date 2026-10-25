# Getting started

eohunter hunts with a bigshot profile you already have. This page gets
you from nothing to a dry run and then a first hunt.

## What you need

- Lich 5.22.0 or later. See [Core dependencies](core-dependencies.md)
  for what the engine uses from it. The script checks for the constants
  it needs at startup and refuses to start on an older Lich, saying to
  update.
- A profile: a bigshot profile at
  `data/<game>/<char>/bigshot_profiles/<name>.yaml`, written by bsprofiles
  or by hand, which eohunter reads unchanged; or a hunt made with
  `;eohunter setup` (below). See [Profiles](profiles.md) for every key it
  honours.
- For Cleanse, an `ecleanse.yaml` in the same character directory,
  written by ecleanse's setup window. Without one, Cleanse runs with
  every toggle off.

## Installing

With the gem, the usual way:

```
gem install eohunter
eohunter install
```

`eohunter install` finds Lich (or takes `--lich-dir <path>`) and copies
the script, its parts and the coordination library into `scripts/`. Run it
again after `gem update eohunter` to upgrade; `eohunter doctor` shows what
is installed. Until the gem is on rubygems.org, install the `.gem` file
attached to a GitHub release: `gem install ./eohunter-<version>.gem`.

From a build: the repo builds one `eohunter.lic` with the engine inlined,
and `libeocoordination.lic` (see the README section on building). Drop
`eohunter.lic` into `scripts/`; add `libeocoordination.lic` beside it for
strict group movement, which loads it. If a `scripts/eohunter/` directory
from an earlier install is beside it, remove that directory; the built
file does not read it. The built file has no setup editor: that runs from
the `scripts/eohunter/` parts.

From the parts: copy `scripts/eohunter.lic`, `scripts/eohunter/`,
`scripts/libeocoordination.lic` and `scripts/eocoordination/` into Lich's
`scripts/`.

## Making a hunt with the editor

```
;eohunter setup
```

opens a window for hunts. Pick a Bigshot profile and Import it to start
from one you have, or New for an empty hunt. Change settings page by
page, then Validate: it checks the hunt against the installed engine and
lists errors and warnings under the settings they belong to and on the
Review page. Save writes the hunt to
`data/<game>/<char>/eohunter/profiles/<name>.yaml`; the Bigshot profile
is never written.

## The first run

Start with a dry run. It loads the profile, resolves rooms and builds
every policy, prints a summary of what it found, then exits without
sending a command:

```
;eohunter <profile> dry
```

Read the report. It names the hunting room and boundaries, the targets,
each routine a-j with its lines, the signs, the combat buffs and the
hunting loadout. A room that failed to resolve prints as nothing, an
empty routine prints empty, a target list with no letters is visible at
a glance - these show here rather than in the hunting area.

A stance word the game would refuse does not appear: the profile rejects
it at load and keeps the documented default, so check `hunting_stance`,
`wander_stance` and `stand_stance` against the stance names if the
character is not standing the way you expect.

Then hunt:

```
;eohunter <profile>
```

The script prints an `eohunter:` line for everything it decides: the
behavior that took control, the target and routine, a rest reason, a
flee reason, a cleanse. Watching those lines for one cycle tells you
whether the profile says what you meant.

## Modes

| Command | What it does |
|---|---|
| `;eohunter <profile>` | hunt: prep, walk to the hunting room, fight, loot, rest, repeat |
| `;eohunter <profile> dry` | load and report only |
| `;eohunter <profile> bandits` | bandit mode: the bandit nouns on the quick routine, no target switch, no flee past `always_flee_from`; also on in bounty mode when the bounty says "suppress bandit activity", never from a bandit task merely held |
| `;eohunter <profile> track <creature>` | Rangers: TRACK toward the creature before each step |
| `;eohunter <profile> head <count>` | lead a group: wait for that many followers, then hunt |
| `;eohunter <profile> head <name> ...` | lead a group of those characters |
| `;eohunter <profile> head <count> lan` | the same, with the rally hub served to the network rather than to this machine only |
| `;eohunter <profile> tail [uri]` | follow a leader; the rally whisper names the uri |
| `;eohunter bounty [<creature>] [head|tail]` | ebounty's hunt child, in place of `bigshot bounty`, alone or in a group |
| `;eohunter setup` | open the hunt editor |
| `;eohunter reload` | drop what is loaded, so the next run reads the files fresh |

Group hunting is described in the README. The leader serves its rally
hub on the loopback address, so leader and followers share a machine by
default; add `lan` when they do not. The hub answers orders without
authentication, so only open it to a network you trust. Bounties stay ebounty's; the
bounty child reads the profile ebounty loaded and exits at the resting
room for ebounty to carry on.

## Stopping

`;kill eohunter` at any time. A trip in flight (go2) is killed with it.
`;pause eohunter` freezes the script where it is, as with any Lich
script; a trip in flight keeps walking until the next tick after
`;unpause`.

The engine also stops itself. Five failed actions in a row, or one
behavior acting more often than roundtime allows (sixty times in a
minute), trip the watchdog: it prints `watchdog:` with the behavior and
which behaviors above it declined that tick, then stops. Death stops
it unless the profile says to depart or quit. A dead player in the room
during the hunt stops it when `deader` is on. Each of these is a
decision the engine would rather hand to you than guess at; see
[Troubleshooting](troubleshooting.md) for what to look at.

## What to expect on the first hunt

One action per tick, about four ticks a second, and only the most
urgent behavior acts. In practice: Wander steps and hides, Engage takes
one routine line per tick with the roundtime waits inside the action,
Loot searches each corpse once, Maintain keeps signs and blesses up
between fights, Rest walks home when the profile's rest rule says so.
Cleanse and Flee and Survival sit above all of that and take the tick
when something is wrong.

Nothing sends a command and hopes. Every send waits for the game's
answer and returns a result, and a refused command is a failed action,
not a retry loop.
