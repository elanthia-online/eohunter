# Extending the engine

How to add an action, a routine word, or a behavior, and the rules
every addition follows. Read [Architecture](architecture.md) first.

## The rules

1. **Lich first.** If Lich has a reader, a module or a verb helper for
   it, use that. The engine has no parsers of its own for combat text,
   no copies of core tables, no second implementation of something
   Lich does. The core consumption audit says where the line is. A
   missing core feature is a lich-5 pull request, and the engine waits
   for it behind a test package rather than working around it.
2. **Read through World.** Behaviors and actions never touch XMLData,
   GameObj or the other globals. Add a reader on World, with a source
   accessor if it is a new Lich object, and stub it in the spec.
3. **Send through an Action.** Every game command is an action with
   preconditions, a send helper and a Result. No bare `fput` or `put`.
4. **Return, do not loop.** An action does one thing and returns. A
   refusal is a failed Result with a reason. Waiting for a condition is
   bounded, with a deadline and the interrupt checked.
5. **One line per tick.** A behavior's `tick` issues at most one action.
   Work that needs several sends spans several ticks with state in the
   behavior, so Survival and Cleanse can take the tick between them.
6. **Specs without a game.** Every action and behavior has a spec that
   fakes the world with structs and stubs the send seam, says what the
   game answered and checks what the engine sent.
7. **Cite the rule.** A comment names the bigshot or ecleanse function
   and line the behavior comes from, with a `@bigshot` tag in the
   docstring. A rule with no source is a rule the next reader cannot
   check.

## Adding an action

An action is a class under `EO::Engine::Actions` with `Base` as its
parent.

```ruby
module EO::Engine
  module Actions
    # Kneel, for the routine word. bigshot cmd_kneel (0000).
    class Kneel < Base
      ANSWERS = /^You kneel|^You are already kneeling|^You can't|^Roundtime/

      def preconditions
        return :dead if me.dead?
        return :already if me.kneeling?

        :ok
      end

      def perform
        result = send_and_match('kneel', ANSWERS)
        return result unless result.success?

        line = result.line.to_s
        return Result.new(status: :failed, reason: :refused, line: line) if line =~ /can't/

        Result.new(status: :success, reason: :knelt, line: line)
      end
    end
  end
end
```

`Base` gives you `@world`, `me`, `send_through_ladder`,
`send_and_match`, `send_and_observe`, `send_and_await`, `interrupted?`, `clock_now` and
the roundtime settle that `call` runs before `perform`. The answers
regex should be the game's lines, complete; an action that times out
waiting for a line it did not list is a bug. Prefer a Lich reader for
the answer set when one exists (the PSM readers' `results_regex`,
`Spell.results_regex`).

For a named event, use
`send_and_await(command, :event_name, timeout: 6, matcher: correlation)`.
It arms the subscription before sending through the existing refusal ladder,
then waits with a monotonic deadline and interrupt/death checks. The helper
adds no retries. Its matcher selects the response; inspect `result.event.data`
after confirmation to decide whether the game accepted or denied the command.
A correlated negative response still confirms receipt. Silence returns
`:timeout` with `:no_confirmation`; ladder failures pass through unchanged.
Interrupt, death and bus cancellation return `:failed` with `:interrupted`,
`:dead` or `:cancelled`. Timeouts must be finite nonnegative real numbers;
the helper validates them before sending, and zero checks immediately.

Arming excludes earlier bus emissions, but cannot establish causation if
Lich's scanner delivers an older queued game line after arming. Match payload
fields that identify the requested item or target wherever possible. A caller
using `Events.arm` directly must either call `wait` or ensure `cancel` runs;
both release the subscription, and cancellation is safe to repeat.

Spec it by stubbing the send seam:

```ruby
it 'kneels once and reports a refusal' do
  action = described_class.new(world)
  allow(action).to receive(:send_and_match).and_return(
    EO::Engine::Actions::Result.new(status: :success, line: 'You kneel.')
  )
  expect(action.call.reason).to eq(:knelt)
end
```

## Adding a routine word

Words Engage dispatches itself are in `Behaviors::Engage#dispatch`.
The rest of bigshot's `cmd_*` table is in `Engage::Routines.run` in
routines.rb, which matches the word and calls an action. Add the word
there, add it to the `UNSUPPORTED` regex in engage.rb so Engage routes
it, and document it in [Routines](routines.md). If the word needs a
modifier, `Engage::Conditions` is where modifiers live; a new word
goes in `word_skip?` with a spec in engage_spec.

## Adding a behavior

A behavior subclasses `EO::Engine::Behavior` and answers `priority`,
`wants_control?(world)` and `tick(world)`. Optional hooks: `preempted!`
when another behavior takes the tick (suspend a trip), `cancel!` on
engine stop (kill a trip), `fire_budget` to change or opt out of the
fire-rate watchdog, and `name`.

The arbiter skips a behavior entirely while the character is muckled
(stunned, webbed, bound) unless it answers `runs_muckled?` with true.
Every action below Cleanse refuses with `:muckled` before it sends, so a
behavior that kept winning the tick through a stun would spend the stun
refusing itself and starve the ones that could get out of it. Survival
and Cleanse are the two that opt in.

`wants_control?` is a pure read of World; it must not send anything, not
even through a Lich helper that might (the ability gates in Injured can
send `_injury`, so they are read at the action, not the predicate).
`tick` issues one action and returns its Result, or nil for a tick that
did nothing. Return the action's own Result rather than a fresh one
where you can: `Actions::Base#call` stamps `acted` on a Result whose
command reached the game, and the fire-rate watchdog counts only those.
A Result you build by hand (a gate refusal, a no-op) is never a fire,
and setting `acted` yourself is not allowed.

Register it in the script's `build`, in priority order, and add its
policy to `Profile` if it reads profile keys. Add a row to the priority
table in the README and in [Architecture](architecture.md).

## Adding a World reader

A new fact from Lich goes on World, `Me`, `RoomView` or `Hands`, as a
plain value. Read it through an existing source accessor, or add one
(`def foo = ::Lich::Gemstone::Foo`) so a spec can stub it. Rescue only
what can raise, to a default that means "unknown", and say in the
comment what unknown reads as. Never rescue `NameError` from a wrong
constant into a silent default; two of those hid real bugs for a while.

## Running things

```
bundle exec rspec                  # the suite, about a second
bundle exec rubocop                # Layout and Lint, ASCII-only source
bundle exec rake build             # dist/eohunter.lic
bundle exec rake doc               # the YARD site into doc/
```

To try a change in the game, copy `scripts/eohunter.lic` and
`scripts/eohunter/` into a Lich that has the core dependencies, or
build and drop the single file in. `;eohunter <profile> dry` loads
everything without sending a command.
