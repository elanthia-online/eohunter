# frozen_string_literal: true

# ============================================================================
# events (from forge events.rb)
# ============================================================================

#
# EO::Engine::Events - in-process pub/sub event bus with blocking await.
#
# The spine of the framework: parsers/hooks emit, actions await, the
# logger/recorder subscribe. Thread-safe: emissions typically arrive from
# Lich's downstream hook thread while awaits block the engine thread.
#
# Depends on nothing (pure Ruby) so it is fully spec-testable.
#
module EO::Engine
  # In-process pub/sub event bus with blocking await; see the file header.
  module Events
    # One emission: its `type` Symbol, the `data` Hash it carried, and the
    # Time `at` which it was emitted.
    #
    # @!attribute type
    #   @return [Symbol] the event name
    # @!attribute data
    #   @return [Hash] the emitter's payload
    # @!attribute at
    #   @return [Time] when it was emitted
    Event = Struct.new(:type, :data, :at, keyword_init: true)

    # A one-use subscription armed before sending a command. Captures the
    # first correlated event, including one emitted before +wait+ starts.
    class ArmedWait
      # @return [Symbol, nil] :confirmed, :timeout, :interrupted, :dead or :cancelled
      attr_reader :reason

      # @param types [Array<Symbol>] event names to capture
      # @param matcher [#call, nil] correlation filter, not a success test
      # @param remove [#call] removes this handle from the bus
      def initialize(types, matcher, remove)
        @types = types
        @matcher = matcher
        @remove = remove
        @mutex = Mutex.new
        @closed = false
      end

      # Wait with a monotonic deadline and stop checks at most 50 ms apart.
      # The timeout starts here, after the caller's send has finished.
      # Always releases the subscription, including when a stop check raises.
      #
      # @param timeout [Numeric] seconds to wait
      # @param interrupt [#call, nil] true when the engine is stopping
      # @yield an optional predicate answering whether the character died
      # @return [Event, nil] a correlated event, or nil; see +reason+
      # @raise [ArgumentError] unless timeout is finite, real and nonnegative
      def wait(timeout:, interrupt: nil)
        Events.validate_timeout!(timeout)
        deadline = clock_now + timeout
        loop do
          return nil if @mutex.synchronize { @closed }
          return finish(:interrupted) if interrupt&.call
          return finish(:dead) if block_given? && yield

          event = @mutex.synchronize { @event }
          return finish(:confirmed, event) if event

          remaining = deadline - clock_now
          return finish(:timeout) if remaining <= 0

          sleep([remaining, 0.05].min)
        end
      ensure
        cancel
      end

      # Release the subscription and discard any pending event. Safe to call
      # repeatedly, including after wait finishes or the bus resets.
      # @return [nil]
      def cancel
        @mutex.synchronize do
          @closed = true
          @reason ||= :cancelled
          @event = nil
        end
        @remove.call(self)
        nil
      end

      # Deliver a bus emission; a broken matcher is ignored as in +await+.
      # @api private
      # @param event [Event]
      # @return [void]
      def deliver(event)
        return unless @types.include?(event.type)
        return if @mutex.synchronize { @closed || @event }
        return if @matcher && !@matcher.call(event)

        @mutex.synchronize { @event ||= event unless @closed }
      rescue StandardError
        nil
      end

      private

      def clock_now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      def finish(reason, event = nil)
        @mutex.synchronize do
          return nil if @closed

          @closed = true
          @reason = reason
          event
        end
      end
    end

    @mutex = Mutex.new
    @subscribers = Hash.new { |h, k| h[k] = [] } # type => [callable, ...]
    @any_subscribers = []
    @waiters = [] # ArmedWait handles

    class << self
      # Validate a bounded wait before an action sends a consuming command.
      # Shared with ArmedWait so direct callers have the same deadline rules.
      #
      # @param timeout [Numeric] seconds to wait; zero permits an immediate check
      # @return [void]
      # @raise [ArgumentError] unless timeout is finite, real and nonnegative
      def validate_timeout!(timeout)
        return if timeout.is_a?(Numeric) && timeout.real? && timeout.finite? && !timeout.negative?

        raise ArgumentError, 'timeout must be a finite nonnegative real number'
      end

      # Subscribe to one or more event types (or :any). Returns the handler
      # (keep it if you want to unsubscribe).
      #
      # @param types [Array<Symbol>] the event types; none, or :any, means every event
      # @yield [event] on each matching emission, inline on the emitting thread
      # @yieldparam event [Event]
      # @return [Proc] the handler, for `off`
      # @raise [ArgumentError] without a block
      def on(*types, &block)
        raise ArgumentError, 'block required' unless block

        @mutex.synchronize do
          if types.empty? || types == [:any]
            @any_subscribers << block
          else
            types.each { |t| @subscribers[t] << block }
          end
        end
        block
      end

      # Unsubscribe a handler from every type it was registered under.
      #
      # @param handler [Proc] what `on` returned
      # @return [nil]
      def off(handler)
        @mutex.synchronize do
          @any_subscribers.delete(handler)
          @subscribers.each_value { |list| list.delete(handler) }
        end
        nil
      end

      # Emit an event. Subscribers run inline on the emitting thread; a
      # subscriber that raises is reported (if a reporter is set) but never
      # breaks other subscribers or the emitter.
      #
      # @param type [Symbol] the event name
      # @param data [Hash] the payload; waiters see it through `Event#data`
      # @return [Event] the event that was emitted
      def emit(type, data = {})
        event = Event.new(type: type, data: data, at: Time.now)
        handlers, waiters = @mutex.synchronize do
          [@subscribers[type].dup + @any_subscribers.dup, @waiters.dup]
        end
        handlers.each do |h|
          begin
            h.call(event)
          rescue StandardError => e
            report_subscriber_error(type, e)
          end
        end
        waiters.each { |waiter| waiter.deliver(event) }
        event
      end

      # Subscribe now so a command's immediate response cannot precede its
      # waiter. Earlier bus emissions are excluded; an upstream scanner can
      # still deliver an older game line late. Correlate payloads where possible.
      #
      # @param types [Array<Symbol>] event types to capture
      # @yield [event] optional correlation filter (not a success predicate)
      # @yieldparam event [Event]
      # @return [ArmedWait] a handle the caller must wait on or cancel
      def arm(*types, &matcher)
        remove = ->(handle) { @mutex.synchronize { @waiters.delete(handle) } }
        waiter = ArmedWait.new(types, matcher, remove)
        @mutex.synchronize { @waiters << waiter }
        waiter
      end

      # Block until an event of one of +types+ arrives (optionally passing
      # +matcher+, a callable given the event). Returns the Event, or nil on
      # timeout. This is what verified actions build on.
      #
      # @param types [Array<Symbol>] the event types to wait for
      # @param timeout [Numeric] seconds to wait
      # @yield [event] an optional filter; only a true answer releases the wait
      # @yieldparam event [Event]
      # @return [Event, nil] the first matching event, or nil on timeout
      def await(*types, timeout:, &matcher)
        arm(*types, &matcher).wait(timeout: timeout)
      end

      # Errors raised by subscribers are handed to this callable (e.g. the
      # logger); defaults to silent to keep the bus dependency-free.
      #
      # @return [#call, nil] called with (type, error)
      attr_accessor :error_reporter

      # Drop every subscriber and waiter (specs, and a fresh run of the script).
      #
      # @return [void]
      def reset!
        waiters = @mutex.synchronize do
          @subscribers.clear
          @any_subscribers.clear
          @waiters.shift(@waiters.length)
        end
        waiters.each(&:cancel)
      end

      private

      def report_subscriber_error(type, error)
        error_reporter&.call(type, error)
      end
    end
  end
end
