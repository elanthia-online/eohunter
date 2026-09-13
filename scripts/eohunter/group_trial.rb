# frozen_string_literal: true

module EO::Engine
  # Optional finite two-member outing bookkeeping. Transport, Script ownership,
  # native survival, movement and return stay with the caller. In particular,
  # this module never starts scripts or supplies commands to a peer.
  module GroupTrial
    # A malformed trial configuration or a foreign member.
    class Invalid < StandardError; end

    # Passive, bounded shared state for one exact pair. Expose only through an
    # already authorized transport; member identities are pins, not credentials.
    class Session
      # @param identities [Array<Hash>] two character/session/run_id identities
      # @param refuge_room [Integer] player-designated common refuge
      # @param work_seconds [Numeric] maximum outbound plus encounter time (1-600 seconds)
      # @param return_seconds [Numeric] separate local recovery allowance
      # @param startup_seconds [Numeric] maximum time to meet the start barrier
      # @param freshness_seconds [Numeric] maximum interval between member reports
      # @param clock [Proc] receiver-local monotonic clock
      def initialize(identities:, refuge_room:, work_seconds:, return_seconds:, startup_seconds: 20,
                     freshness_seconds: 2, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        @identities = identities.map { |identity| self.class.identity(identity) }.freeze
        unless @identities.size == 2 && @identities.map { |identity| identity[:character].downcase }.uniq.size == 2
          raise Invalid, 'a trial requires exactly two distinct characters'
        end
        unless refuge_room.is_a?(Integer) && refuge_room.positive? && refuge_room != 4
          raise Invalid, 'a trial requires an explicit refuge'
        end
        { work: [work_seconds, 1, 600], return: [return_seconds, 10, 120],
          startup: [startup_seconds, 1, 60], freshness: [freshness_seconds, 0.1, 5] }.each do |name, (value, low, high)|
          unless value.is_a?(Numeric) && value.finite? && value.between?(low, high)
            raise Invalid, "invalid #{name} budget"
          end
        end
        @refuge_room, @work_seconds, @return_seconds = refuge_room, work_seconds, return_seconds
        @freshness_seconds, @clock = freshness_seconds, clock
        @startup_deadline = @clock.call + startup_seconds
        @mutex = Mutex.new
        @reports, @receipts = {}, {}
        @phase = :waiting
        @reason = @target_id = nil
      end

      # Normalize and copy an exact member identity.
      # @param value [Hash]
      # @return [Hash] frozen pin
      def self.identity(value)
        keys = %i[character session run_id]
        unless value.is_a?(Hash) && value.keys.sort == keys.sort &&
               keys.all? { |key| value[key].is_a?(String) && !value[key].empty? && value[key].bytesize <= 128 }
          raise Invalid, 'member identity requires character, session and run_id'
        end
        Controller::Immutable.copy(value)
      end

      # Report local startup readiness or liveness. The transport adapter must
      # call this only for its pinned, locally validated member.
      # @param identity [Hash] exact member
      # @param ready [Boolean] fresh local refuge admission, not game readiness
      # @param hands [Array<String, nil>] the member's original hand identities
      # @return [Hash] bounded state
      def report(identity, ready:, hands:)
        @mutex.synchronize do
          pin = member!(identity)
          unless [true, false].include?(ready) && valid_hands?(hands)
            raise Invalid, 'member report requires explicit readiness and known hands'
          end
          existing = @reports[pin]
          raise Invalid, 'original equipment changed within the trial' if existing && existing[:hands] != hands

          expire!
          @reports[pin] = { at: @clock.call, ready: ready, hands: Controller::Immutable.copy(hands) }
          if @phase == :waiting && @identities.all? { |member| fresh_report?(member) && @reports[member][:ready] }
            @phase = :working
            @work_deadline = @clock.call + @work_seconds
          end
          status_locked
        end
      end

      # Stop work for the whole pair; each member owns its own return.
      # @param identity [Hash] exact member
      # @param reason [String] bounded explanatory code
      # @return [Hash]
      def request_return(identity, reason:)
        @mutex.synchronize do
          member!(identity)
          expire!
          return_locked(reason.to_s[0, 120])
          status_locked
        end
      end

      # Record one native game-confirmed death. Disappearing targets and a
      # caller's guess are not kills. Duplicates cannot extend the work budget.
      # @param identity [Hash] exact reporting member
      # @param target_id [String] current exact creature ID
      # @param confirmed [Boolean] native death evidence
      # @return [Hash]
      def record_kill(identity, target_id:, confirmed:)
        @mutex.synchronize do
          member!(identity)
          expire!
          unless confirmed == true && target_id.is_a?(String) && target_id.match?(/\A[1-9]\d*\z/)
            raise Invalid, 'a kill requires exact native death evidence'
          end
          raise Invalid, 'kill is not the selected trial target' unless target_id == @selected_target_id

          if @phase == :working
            @target_id = target_id.dup.freeze
            return_locked('kill_limit')
          end
          status_locked
        end
      end

      # Pin the native engine's first assigned target. Switching a still-live
      # target ends work instead of counting an unrelated creature's death.
      # @param identity [Hash] exact member
      # @param target_id [String] native assigned target
      # @return [Hash]
      def select_target(identity, target_id:)
        @mutex.synchronize do
          member!(identity)
          expire!
          unless target_id.is_a?(String) && target_id.match?(/\A[1-9]\d*\z/)
            raise Invalid, 'target selection requires an exact creature ID'
          end
          if @phase == :working
            if @selected_target_id && @selected_target_id != target_id
              return_locked('target_changed')
            else
              @selected_target_id ||= target_id.dup.freeze
            end
          end
          status_locked
        end
      end

      # Retain one immutable local handoff receipt. Repeated identical delivery
      # is permitted; a contradictory successor cannot replace the first proof.
      # @param identity [Hash] exact member
      # @param receipt [Hash] participant-produced terminal receipt
      # @return [Hash]
      def finish(identity, receipt:)
        @mutex.synchronize do
          pin = member!(identity)
          unless receipt.is_a?(Hash) && receipt[:identity] == pin && [true, false].include?(receipt[:safe]) &&
                 receipt[:refuge_room] == @refuge_room && receipt[:hands] == @reports.dig(pin, :hands)
            raise Invalid, 'terminal receipt does not match the admitted member'
          end
          if @receipts.key?(pin) && @receipts[pin] != receipt
            raise Invalid, 'terminal receipt is immutable'
          end
          @receipts[pin] ||= Controller::Immutable.copy(receipt)
          return_locked('member_finished')
          status_locked
        end
      end

      # @return [Hash] immutable receiver-clock state, never raw local objects
      def status
        @mutex.synchronize do
          expire!
          status_locked
        end
      end

      private

      def member!(identity)
        @identities.find { |pin| pin == identity } || raise(Invalid, 'foreign trial member')
      end

      def valid_hands?(hands)
        hands.is_a?(Array) && hands.length == 2 &&
          hands.all? { |id| id.nil? || (id.is_a?(String) && id.match?(/\A[1-9]\d*\z/)) }
      end

      def fresh_report?(identity)
        report = @reports[identity]
        report && (@clock.call - report[:at]).between?(0, @freshness_seconds)
      end

      def expire!
        if @phase == :waiting && @clock.call >= @startup_deadline
          return_locked('startup_timeout')
        elsif @phase == :working
          if @clock.call >= @work_deadline
            return_locked('work_deadline')
          elsif !@identities.all? { |identity| fresh_report?(identity) }
            return_locked('peer_lost')
          end
        end
      end

      def return_locked(reason)
        return if @phase == :returning

        @phase, @reason = :returning, reason
      end

      def status_locked
        complete = @identities.all? { |identity| @receipts.key?(identity) }
        Controller::Immutable.copy(
          phase: @phase, reason: @reason, refuge_room: @refuge_room, return_seconds: @return_seconds,
          startup_remaining: [@startup_deadline - @clock.call, 0].max, work_seconds: @work_seconds,
          work_remaining: @work_deadline ? [@work_deadline - @clock.call, 0].max : @work_seconds,
          target_id: @target_id, selected_target_id: @selected_target_id, receipts: @receipts.values,
          complete: complete, success: complete && @reason == 'kill_limit' && @receipts.values.all? { |receipt| receipt[:safe] }
        )
      end
    end

    # Local owner-thread adapter. Call #tick before native behavior selection
    # and #finish! only after
    # exact child cleanup/owner release. Callbacks reuse the existing engine and
    # Rest; the follower must have a separately usable local return adapter.
    #
    # Session access MUST be local or bounded by the transport adapter. An
    # unbounded remote call on the owner thread cannot provide timed recovery.
    # Cached adapters must reject stale state rather than refreshing its age.
    #
    # Native ScriptExecutionGuard denial is latched. #commands_permitted? MUST
    # be used in separate disposable work and return guard scopes, never one
    # lifetime guard. After work denial, the caller catches Interrupted, joins
    # exact work children, leaves that guard, ticks this adapter, then uses a
    # fresh return-only guard. The return path must run only native recovery;
    # this state object cannot distinguish an offensive wire command. Local
    # grant loss remains latched and denies even a newly constructed guard.
    class Participant
      # @param session [Session, Object] bounded pinned shared-state adapter
      # @param identity [Hash] exact local character/session/run_id
      # @param snapshot [Proc] fresh local observation; never issues commands
      # @param authority [Proc] literal true while this local grant remains valid
      # @param start [Proc] starts native work after the pair's barrier
      # @param return_to_refuge [Proc] requests existing local Rest recovery
      # @param stop [Proc] stops only exact owned work; receives failure reason
      # @param clock [Proc] local monotonic clock
      def initialize(session:, identity:, snapshot:, authority:, start:, return_to_refuge:, stop:,
                     clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        @session, @identity = session, Session.identity(identity)
        @snapshot, @authority, @start, @return, @stop = snapshot, authority, start, return_to_refuge, stop
        @clock, @thread = clock, Thread.current
        @inbox_mutex, @inbox = Mutex.new, []
        @revoked = false
        @phase, @reason = :waiting, nil
        @configuration = @session.status
        @refuge_room = @configuration.fetch(:refuge_room)
        @return_seconds = @configuration.fetch(:return_seconds)
        raise Invalid, 'trial has already closed admission' if @configuration[:phase] == :returning

        @startup_deadline = @clock.call + @configuration.fetch(:startup_remaining)
        @hard_deadline = @startup_deadline +
                         @configuration.fetch(:work_remaining) + @return_seconds
        observed = @snapshot.call
        raise Invalid, 'trial must begin at the refuge with fresh original equipment and exact ownership' unless start_safe?(observed)

        @hands = Controller::Immutable.copy(observed[:hands])
        @session.report(@identity, ready: true, hands: @hands)
      end

      # Advance only the local supervisor; native behavior execution remains
      # the caller's job. A transport failure initiates independently owned return.
      # @return [Hash] local status
      def tick
        owner_thread!
        return status if @phase == :finished
        return revoke!('local_authority_lost') unless local_valid?
        return revoke!('return_deadline') if @phase == :returning && @clock.call >= @return_deadline
        return request_stop('startup_timeout') if @phase == :waiting && @clock.call >= @startup_deadline

        shared = @session.report(@identity, ready: @phase == :waiting && start_safe?(@snapshot.call), hands: @hands)
        if @phase == :waiting && shared[:phase] == :working
          raise Invalid, 'start state changed before activation' unless start_safe?(@snapshot.call)

          @work_deadline = @clock.call + shared.fetch(:work_remaining)
          @phase = :working
          @start.call
        end
        begin_return(shared[:reason]) if shared[:phase] == :returning
        drain_notifications if @phase == :working
        request_stop('work_deadline') if @phase == :working && @clock.call >= @work_deadline
        status
      rescue ThreadError
        raise
      rescue StandardError => error
        begin_return("peer_unavailable:#{error.class}")
        status
      end

      # Policy for the current disposable native guard scope (see class contract).
      # False is denial, never permission for an unguarded fallback. Return
      # ignores peer liveness but keeps the local authority and absolute deadline.
      # @return [Boolean]
      def commands_permitted?
        # Exact native children also evaluate this read-only policy. Their
        # identity/ownership belongs to Controller::ChildScripts; mutations
        # still require the parent owner thread.
        return false unless %i[working returning].include?(@phase)
        unless local_valid?
          @revoked = true
          return false
        end

        if @phase == :returning
          @clock.call < @return_deadline
        else
          @clock.call < @work_deadline && @session.status[:phase] == :working
        end
      rescue StandardError
        false
      end

      # Pin the target selected by native Engage/Assist on the owner thread.
      # @param target_id [String]
      # @return [Hash]
      def select_target(target_id:)
        owner_thread!
        shared = @session.select_target(@identity, target_id: target_id)
        @inbox_mutex.synchronize { @selected_target_id = shared[:selected_target_id] }
        begin_return(shared[:reason]) if shared[:phase] == :returning
        status
      end

      # Native observer ingress, safe from parser/observer threads. It copies a
      # bounded notification only; no snapshots, transport or game callbacks run.
      # The owner accepts only death evidence for its already selected target.
      # @param target_id [String] native creature ID
      # @param session [String] observation's local session pin
      # @param confirmed [Boolean] native death evidence
      # @return [Boolean] queued, not applied
      def enqueue_kill(target_id:, session:, confirmed:)
        return false unless session == @identity[:session] && confirmed == true &&
                            target_id.is_a?(String) && target_id.match?(/\A[1-9]\d*\z/)

        @inbox_mutex.synchronize do
          return false if @inbox.size >= 8 || @phase != :working || target_id != @selected_target_id

          @inbox << target_id.dup.freeze
        end
        true
      end

      # @param target_id [String] native confirmed target identity
      # @param confirmed [Boolean]
      # @return [Hash]
      def record_kill(target_id:, confirmed:)
        owner_thread!
        shared = @session.record_kill(@identity, target_id: target_id, confirmed: confirmed)
        begin_return(shared[:reason]) if shared[:phase] == :returning
        status
      end

      # An ordinary stop retains only the separate local return allowance.
      # @param reason [String]
      # @return [Hash]
      def request_stop(reason = 'ordinary_stop')
        owner_thread!
        begin
          @session.request_return(@identity, reason: reason)
        rescue StandardError
          # An unreachable peer cannot cancel the already delegated local return.
          nil
        ensure
          begin_return(reason)
        end
        status
      end

      # Explicit revocation cannot silently issue return commands.
      # @param reason [String]
      # @return [Hash] unsafe terminal receipt
      def revoke!(reason = 'revoked')
        owner_thread!
        return status if @phase == :finished

        @phase, @reason = :finished, reason
        @revoked = true
        begin
          @stop.call(reason)
        ensure
          publish_receipt(false)
        end
        status
      end

      # Called after exact native cleanup; arriving in the room is insufficient.
      # @return [Hash] immutable local handoff; shared success requires both
      def finish!
        owner_thread!
        return status if @phase == :finished
        return revoke!('local_authority_lost') unless @authority.call == true

        observed = @snapshot.call
        safe = @phase == :returning && @clock.call < @return_deadline && terminal_safe?(observed)
        @phase = :finished
        @reason = 'unsafe_handoff' unless safe
        publish_receipt(safe)
        status
      end

      # @return [Hash] local immutable status, even when the peer is unreachable
      def status
        Controller::Immutable.copy(identity: @identity, phase: @phase, reason: @reason,
                                   refuge_room: @refuge_room, hands: @hands, receipt: @receipt,
                                   work_deadline: @work_deadline, return_deadline: @return_deadline,
                                   hard_deadline: @hard_deadline)
      end

      private

      def owner_thread!
        raise ThreadError, 'group trial must run on its exact owner thread' unless Thread.current.equal?(@thread)
      end

      def observed_valid?(observed)
        observed.is_a?(Hash) && observed[:fresh] == true && observed[:session] == @identity[:session] &&
          observed[:connected] == true && observed[:alive] == true && observed[:stable] == true
      end

      def local_valid?
        observed = @snapshot.call
        !@revoked && @authority.call == true && observed_valid?(observed) && observed[:owner] == true
      rescue StandardError
        false
      end

      def drain_notifications
        pending = @inbox_mutex.synchronize { @inbox.shift(8) }
        pending.each do |target_id|
          break unless @phase == :working
          next unless target_id == @selected_target_id

          record_kill(target_id: target_id, confirmed: true)
        end
      end

      def start_safe?(observed)
        observed_valid?(observed) && @authority.call == true && observed[:owner] == true &&
          observed[:ready] == true && observed[:standing] == true && observed[:room_id] == @refuge_room &&
          observed[:hands].is_a?(Array) && observed[:hands].size == 2 &&
          observed[:hands].all? { |id| id.nil? || (id.is_a?(String) && id.match?(/\A[1-9]\d*\z/)) } &&
          (!@hands || observed[:hands] == @hands)
      end

      def terminal_safe?(observed)
        observed_valid?(observed) && observed[:ready] == true && observed[:room_id] == @refuge_room && observed[:standing] == true &&
          observed[:hands] == @hands && observed[:owner_released] == true && observed[:children_released] == true
      end

      def begin_return(reason)
        return if %i[returning finished].include?(@phase)
        return revoke!('local_authority_lost') unless local_valid?

        @phase, @reason = :returning, reason.to_s[0, 120]
        @return_deadline = [@clock.call + @return_seconds, @hard_deadline].min
        return revoke!('return_deadline') if @clock.call >= @return_deadline

        begin
          @session.request_return(@identity, reason: @reason)
        rescue StandardError
          # The surviving member's return cannot depend on hub availability.
          nil
        end
        @return.call(@reason)
      rescue StandardError
        revoke!('return_adapter_failed')
      end

      def publish_receipt(safe)
        @receipt = Controller::Immutable.copy(identity: @identity, safe: safe, reason: @reason,
                                              refuge_room: @refuge_room, hands: @hands)
        @session.finish(@identity, receipt: @receipt)
      rescue StandardError
        # The exact local receipt stays visible. Lost delivery cannot establish
        # shared success and cannot restart work or extend the return allowance.
        nil
      end
    end
  end
end
