# frozen_string_literal: true

# ============================================================================
# actions (Base: bigshot send ladder and confirmation shapes)
# ============================================================================

#
# EO::Engine::Actions - verified game-command primitives.
#
# Contract: every action returns a Result the caller must handle. An action
# is preconditions -> settle RT -> target still live -> send through the
# refusal ladder -> confirmation (a result line, an observed World change,
# or an awaited bus event) -> Result. No bare fput-and-hope anywhere else.
#
# The ladder is Lich's fput with its bounds (lich-5 #1587: a resend cap,
# a deadline, the engine's interrupt on every wait, named failures); the
# three confirmation shapes are bigshot's cmd_* routines (see
# hunting-engine-plan.md, "Send and confirm").
#
module EO::Engine
  # Verified game-command primitives; see the file header for the contract.
  module Actions
    # What every action hands back: a `status` (:success, :skipped, :failed,
    # :timeout), the bus `event` that confirmed it, a `reason` Symbol naming
    # the outcome, and the answer `line` when one was read.
    #
    # @!attribute status
    #   @return [Symbol] :success, :skipped, :failed or :timeout
    # @!attribute event
    #   @return [Events::Event, nil] the confirming bus event, for the event shape
    # @!attribute reason
    #   @return [Symbol, nil] why: the precondition, failure or success name
    # @!attribute line
    #   @return [String, nil] the matched answer line, for the send_and_match shape
    # @!attribute acted
    #   @return [Boolean, nil] true when a command went to the game for this
    #     result; stamped by Base#call alone, never set by hand
    Result = Struct.new(:status, :event, :reason, :line, :acted, keyword_init: true) do
      # @return [Boolean] true when the status is :success
      def success? = status == :success
      # @return [Boolean] true when the status is :skipped
      def skipped? = status == :skipped
      # @return [Boolean] true for :failed and for :timeout alike
      def failed?  = status == :failed || status == :timeout
      # True when the action put a command on the wire, whatever the
      # game answered. This is what the engine's fire budget counts: a
      # status is the action's own account of itself, and a gate refusal
      # or a no-op can carry :failed or :success without ever sending;
      # the send seam is the one place that knows.
      #
      # @return [Boolean]
      def acted? = acted == true
    end

    # Mixed into the actions that CAST or SWING - the only ones soft cast
    # roundtime actually blocks. Everything else inherits Base's hard-RT
    # -only wait (see Base#settle_rt for the full rule).
    module CombatRt
      private

      def wait_cast_rt? = true
    end

    # The action contract. Subclasses give `preconditions` (a Symbol, :ok
    # to proceed) and `perform` (a Result); `call` runs the shared
    # gates between them. The three confirmation shapes are private
    # helpers here: send_and_match, send_and_observe and send_and_await.
    class Base
      # Seconds a confirmation wait lasts when the action names no other.
      DEFAULT_TIMEOUT = 8
      # Seconds a roundtime wait is allowed before it gives up (waitrt? cap).
      RT_SETTLE_CAP = 15

      # The refusal ladder is Lich's fput (lich-5 #1587), bounded: a resend
      # cap, a deadline, the engine's interrupt on every wait, and a named
      # failure instead of false. bigshot's bs_put resends a transient
      # refusal after a quarter second; fput does that under the cap with
      # resend_transient.
      MAX_RESENDS = 5
      # Seconds fput may spend on one command, resends included.
      SEND_DEADLINE = 30

      # Refusals the ladder must not resend. fput's transient rung matches
      # "don't seem" (global_defs.rb 1760) and, with resend_transient on,
      # sleeps and sends again up to the cap - but a severed leg is not
      # transient, so the command went out five times and failed
      # :too_many_resends, which the repeated-failures watchdog counts.
      # bigshot never reaches its own bs_put ladder for these: the line is
      # in the cmd_* dothistimeout match sets, so
      # it is read once as an answer. We read it once too.
      #
      # @bigshot cmd_weapon
      PERMANENT_REFUSALS = %r{
        You\sdon't\sseem\sto\sbe\sable\sto\smove\syour\s(?:legs|arms)\sto\sdo\sthat|
        You\sare\stoo\sinjured\sto\sdo\sthat
      }xi

      class << self
        # The engine's "are we stopping" callable, set once by the script
        # and inherited by every action that is not given its own.
        #
        # Actions are built at 46 call sites, each forwarding an @interrupt
        # it was itself handed; nothing ever supplied a root one, so every
        # interrupted? guard in cleanse, routines and flee was inert and
        # stop! could not shorten an fput or a roundtime wait already in
        # flight. The waits are bounded anyway (SEND_DEADLINE 30 s,
        # RT_SETTLE_CAP 15 s), so this shortens a stop rather than
        # unblocking one.
        #
        # @return [#call, nil]
        attr_accessor :interrupt
      end

      # @param world [World]
      # @param interrupt [#call, nil] answers true when the engine is stopping;
      #   every wait inside the action checks it. Defaults to the engine's,
      #   set by the script; pass one to override.
      # @param opts [Hash] the action's own keywords; `:target` is read by the
      #   shared live-target gate, the rest are the subclass's
      def initialize(world, interrupt: nil, **opts)
        @world = world
        @interrupt = interrupt || Base.interrupt
        @opts = opts
      end

      # The whole contract, in order: preconditions, settle roundtime, the
      # target still live, not dead, not interrupted, then `perform`.
      #
      # A gate that refuses returns :skipped, not :failed. Every one of them
      # returns before `perform`, so by construction the game heard nothing:
      # the action declined itself. :failed is reserved for a command the
      # game refused or did not answer, which is what the engine's
      # repeated-failures watchdog exists to notice (runner.rb 215). Before
      # this, a stun or an unaffordable technique read as five failures in
      # five ticks and stopped a live hunt in about a second with nothing
      # on the wire; bigshot's bs_put waits a stun out and carries on.
      #
      # @return [Actions::Result] a skipped Result naming the gate that
      #   refused (:target_gone, :dead, :interrupted, or the precondition
      #   Symbol), else whatever `perform` returns, stamped `acted` when a
      #   command was sent
      def call
        @acted = false
        pre = preconditions
        return Result.new(status: :skipped, reason: pre) unless pre == :ok

        settle_rt
        # settle_rt just slept out a roundtime - seconds during which the
        # target may have died. bigshot re-checks status and GameObj.targets
        # before every command and between array steps; the wait is when
        # kills land.
        return Result.new(status: :skipped, reason: :target_gone) unless target_still_live?
        # ...and seconds during which WE may have died. The death recovery
        # actions (DEPART, QUIT) are the ones that run dead.
        return Result.new(status: :skipped, reason: :dead) if me.dead? && !dead_ok?
        return Result.new(status: :skipped, reason: :interrupted) if interrupted?

        stamp(perform)
      end

      private

      def me = @world.me

      # True for an action that must run while we are dead (Depart, the
      # quit command); everything else is refused with :dead.
      def dead_ok? = false

      def interrupted? = @interrupt ? @interrupt.call ? true : false : false

      # The acted stamp, at the one exit `call` has: true only when this
      # call went through the send seam below. A perform that returned
      # without sending (a wand that found nothing to wave, a hide that
      # was already hidden) is not an action the game saw.
      def stamp(result)
        result.acted = true if @acted && result.is_a?(Result)
        result
      end

      # --- the send seam --------------------------------------------------

      # Lich's fput with the bounds (stubbed in specs): the first
      # non-refusal line, left in the script's buffer, or a Symbol naming
      # the failure.
      def game_send(command)
        # resend_transient is bigshot's bs_put behaviour and right for a
        # stun or a type-ahead, but fput's transient rung also matches
        # "don't seem" (global_defs.rb 1760), which is how a severed leg
        # refuses. That is not transient: the command went out five times
        # and failed :too_many_resends, and the watchdog counted every one.
        # bigshot never reaches its own ladder for these, because the line
        # is in the cmd_* dothistimeout match sets and is read
        # once as an answer. So: no resend, then classify what came back.
        answer = fput(command, max_resends: MAX_RESENDS, timeout: SEND_DEADLINE, interrupt: @interrupt,
                               resend_transient: false, failures: :symbol)
        return answer unless answer == :refused

        # fput unshifts the refusing line before answering :refused, so it
        # is still there to read (global_defs.rb 1779).
        line = next_line
        return :refused if line.nil?
        return Result.new(status: :failed, reason: :injured, line: line) if line =~ PERMANENT_REFUSALS

        # Everything else the rung caught is the transient kind bs_put
        # resends: hand it back and send again under the cap.
        unread_line(line)
        fput(command, max_resends: MAX_RESENDS, timeout: SEND_DEADLINE, interrupt: @interrupt,
                      resend_transient: true, failures: :symbol)
      end

      # One line from the script's queue, or nil when none is waiting.
      def next_line
        get?
      end

      # Hand a line back so a later reader sees it.
      def unread_line(line)
        script = ::Script.current
        script.downstream_buffer.unshift(line) if script
      end

      # Send +command+ through fput's refusal ladder. Returns the answer
      # line (still in the queue for the confirmation step), or a failed
      # Result: :dead, :interrupted, :too_many_resends, :no_response.
      def send_through_ladder(command)
        @acted = true
        answer = game_send(command)
        # game_send answers a Result of its own for a refusal it classified.
        return answer if answer.is_a?(Result)
        return Result.new(status: :failed, reason: answer) if answer.is_a?(Symbol)
        return Result.new(status: :failed, reason: :no_response) unless answer.is_a?(String)

        answer
      end

      # --- roundtime -----------------------------------------------------

      # HARD roundtime blocks everything, so it is the only thing every
      # action waits on. CAST (soft) roundtime bars casting, attacking and
      # dropping to defensive; everything else is legal during it, so only
      # the actions that genuinely cannot proceed opt in via CombatRt.
      # bigshot waits both before every command except hide and cock;
      # this is the same exception, generalised. Each wait is capped at
      # RT_SETTLE_CAP and ends on the engine's interrupt.
      def settle_rt
        game_wait_rt(:hard)
        game_wait_rt(:cast) if wait_cast_rt?
      end

      def wait_cast_rt? = false

      # Lich's waitrt? / waitcastrt? (lich-5 #1587): sliced, interruptible,
      # capped. Stubbed in specs.
      def game_wait_rt(kind)
        if kind == :cast
          waitcastrt?(interrupt: @interrupt, cap: RT_SETTLE_CAP)
        else
          waitrt?(interrupt: @interrupt, cap: RT_SETTLE_CAP)
        end
      end

      # --- target --------------------------------------------------------

      # True unless this action aims at a creature that is no longer a live
      # target. GameObj.targets is the game's own filtered list - hostile,
      # alive, with severed limbs and animated noise already excluded - so
      # membership is the whole test. Actions with no target are never
      # blocked by this.
      def target_still_live?
        target = @opts[:target]
        return true if target.nil?

        id = target.respond_to?(:id) ? target.id : target
        return true if id.to_s.empty?
        # A collective word ('all', for a warcry or an AoE technique) is not
        # a creature that can leave the room; only an id is checked.
        return true unless target.respond_to?(:id) || id.to_s =~ /\A\d+\z/

        ids = live_target_ids
        return true if ids.nil? # no target list available - do not block

        ids.include?(id.to_s)
      end

      # nil means "cannot tell", which must never be confused with "the
      # list is empty, so the target is dead".
      def live_target_ids
        return nil unless defined?(::GameObj)

        Array(::GameObj.targets).map { |t| t.id.to_s }
      rescue StandardError
        nil
      end

      def clock_now = Time.now

      # --- confirmation, three shapes -------------------------------------

      # Arm before the ladder so an immediate named event is retained while
      # fput finishes. A matcher correlates responses; the action decides
      # whether the confirmed payload means success or refusal.
      #
      # @param command [String] one game command
      # @param types [Array<Symbol>] confirming event names
      # @param timeout [Numeric] seconds to wait after the ladder returns
      # @param matcher [#call, nil] optional event correlation filter
      # @return [Result] the ladder failure unchanged, a confirming event,
      #   :failed for interrupt/death, or :timeout with :no_confirmation
      def send_and_await(command, *types, timeout: DEFAULT_TIMEOUT, matcher: nil)
        waiter = Events.arm(*types, &matcher)
        first = send_through_ladder(command)
        return first if first.is_a?(Result)

        event = waiter.wait(timeout: timeout, interrupt: -> { interrupted? }) { me.dead? }
        return Result.new(status: :success, event: event) if event
        return Result.new(status: :failed, reason: waiter.reason) if %i[interrupted dead].include?(waiter.reason)

        Result.new(status: :timeout, reason: :no_confirmation)
      ensure
        waiter&.cancel
      end

      # bigshot's cmd_* shape: send, then read lines until one matches
      # +regex+ (every known answer to this command, refusals included) or
      # +timeout+ passes. The matched line is the Result's +line+; the
      # caller decides what it means. No match is :timeout, which bigshot
      # turns into a rest reason and the engine's watchdog counts.
      def send_and_match(command, regex, timeout: DEFAULT_TIMEOUT)
        first = send_through_ladder(command)
        return first if first.is_a?(Result)

        deadline = clock_now + timeout
        until clock_now > deadline
          return Result.new(status: :failed, reason: :interrupted) if interrupted?
          return Result.new(status: :failed, reason: :dead) if me.dead?

          line = next_line
          if line.nil?
            sleep 0.05
            next
          end
          return Result.new(status: :success, line: line) if line =~ regex
        end
        Result.new(status: :timeout, reason: :no_confirmation)
      end

      # bigshot's stand / change_stance / wield shape: send, then poll World
      # until the block is true.
      def send_and_observe(command, timeout: DEFAULT_TIMEOUT)
        first = send_through_ladder(command)
        return first if first.is_a?(Result)

        deadline = clock_now + timeout
        until clock_now > deadline
          return Result.new(status: :success) if yield
          return Result.new(status: :failed, reason: :interrupted) if interrupted?
          return Result.new(status: :failed, reason: :dead) if me.dead?

          sleep 0.05
        end
        Result.new(status: :timeout, reason: :state_unchanged)
      end
    end
  end
end
