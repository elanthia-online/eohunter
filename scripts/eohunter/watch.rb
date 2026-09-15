# frozen_string_literal: true

# ============================================================================
# watch (Lich's message and combat facts onto the engine's bus)
# ============================================================================

#
# EO::Engine::Watch - the engine's subscription to Lich's parser seam.
# Every game line the behaviors react to is a fact Lich already
# recognises: the message families of Combat::Messages (lich-5 #1586,
# a weapon knocked away, a curse, a trap, an ambusher, a bolt, a bless
# shrugged off, an arrow stuck, a charge counter, a spell mark), the
# UCS facts, and the attack events (an inbound swing, our own rolls).
# Watch subscribes once, names each fact the way the behaviors have
# always heard it, and adds what the moment knows that the line does
# not (our hands and room on a disarm, whether a shrugged item is ours).
#
# The one line Lich cannot know is the profile's own flee text; that is
# the last rule here, on a DownstreamHook installed only when a profile
# has one.
#
#   Watch.install!   # from eohunter, after loading
#
module EO::Engine
  # The engine's subscription to Lich's parser seam; see the file header.
  module Watch
    # The prefix of the names our Combat::Tracker handlers register under.
    NAME = 'eohunter'
    # A line rule of the script's own: `regex` against each line, `event`
    # to emit on a match, `data` an optional callable given the MatchData.
    #
    # @!attribute regex
    #   @return [Regexp]
    # @!attribute event
    #   @return [Symbol] the bus event to emit
    # @!attribute data
    #   @return [Proc, nil] given the MatchData, returns the event's payload Hash
    Rule = Struct.new(:regex, :event, :data, keyword_init: true)

    # Lich's event -> the engine's, when the names differ.
    RENAMED = { item_limit: :too_many_items }.freeze
    # ecleanse's hive trap kinds (set_hooks 1618)
    HIVE_KINDS = { apparatus: :hive_traps_apparatus, ground: :hive_traps_ground }.freeze

    @rules = []
    @mutex = Mutex.new
    @subscription_mutex = Mutex.new
    @handlers = {}

    class << self
      # A rule of the script's own (the profile's flee_message).
      #
      # @param regex [Regexp] matched against every game line
      # @param event [Symbol] the bus event to emit on a match
      # @yield [match] optional; builds the event's payload
      # @yieldparam match [MatchData]
      # @yieldreturn [Hash, nil] merged with `raw: line`
      # @return [Rule] the rule, for `off`
      def on(regex, event, &data)
        rule = Rule.new(regex: regex, event: event, data: data)
        @mutex.synchronize { @rules << rule }
        rule
      end

      # Remove one rule.
      #
      # @param rule [Rule] what `on` returned
      # @return [Rule, nil] the rule removed, or nil when it was not registered
      def off(rule)
        @mutex.synchronize { @rules.delete(rule) }
      end

      # Drop every rule of the script's own (specs, a profile reload).
      #
      # @return [void]
      def clear!
        @mutex.synchronize { @rules.clear }
      end

      # @return [Array<Rule>] a copy of the rules, safe to iterate
      def rules = @mutex.synchronize { @rules.dup }

      # --- Lich's facts, onto the bus -----------------------------------------

      # Every message event, renamed and completed where the behaviors
      # expect more than the line carries.
      #
      # @param type [Symbol] Lich's Combat::Messages event name
      # @param data [Hash] Lich's payload; copied, never mutated
      # @return [Events::Event] the event emitted
      def message(type, data)
        event = RENAMED.fetch(type, type)
        data = data.dup
        case type
        when :disarm_seen then data.merge!(disarm_data)
        when :hive_trap
          data[:kind] = HIVE_KINDS.fetch(data[:kind], data[:kind])
          data[:room_id] = room_id
        when :bless_shrugged then data[:mine] = mine?(data[:id], data[:noun])
        end
        Events.emit(event, data)
      end

      # The UCS facts the routines read (bigshot hunt_monitor 2387-2405).
      # A :position fact is the engine's :unarmed_tier; a :tierup is its
      # :unarmed_followup; other kinds are ignored.
      #
      # @bigshot hunt_monitor
      # @param data [Hash] Lich's :ucs payload (:kind, :tier or :value, :id)
      # @return [Events::Event, nil] the event emitted, or nil for another kind
      def ucs(data)
        case data[:kind]
        when :position then Events.emit(:unarmed_tier, tier: data[:tier].to_i, id: data[:id])
        when :tierup then Events.emit(:unarmed_followup, attack: data[:value].to_s, id: data[:id])
        end
      end

      # An attack event: a creature's swing at us is WaitForSwing's
      # :incoming_swing; another player's attack is an :ally_attacked for
      # the afterattack ally casts; each of our own resolutions is a
      # :force_roll (cmd_force 5713 reads the endroll).
      #
      # @bigshot cmd_force
      # @param event [Hash] Lich's :attack payload (:inbound, :foreign_caster,
      #   :foreign_target, :attacker, :resolutions)
      # @return [void]
      def attack(event)
        if event[:inbound]
          Events.emit(:incoming_swing, target_id: event.dig(:attacker, :id).to_s)
        elsif event[:foreign_caster]
          name = event[:attacker].respond_to?(:[]) ? event[:attacker][:name].to_s : ''
          Events.emit(:ally_attacked, name: name) unless name.empty?
        elsif !event[:foreign_target]
          Array(event[:resolutions]).each do |r|
            Events.emit(:force_roll, roll: r[:result].to_i) if r[:result]
          end
        end
      end

      # The rules of our own, against every line. A rule's data block that
      # raises is a :watch_error on the bus, and the other rules still run.
      #
      # @param line [String] one game line
      # @return [nil]
      def process(line)
        rules.each do |rule|
          m = rule.regex.match(line)
          next unless m

          data = rule.data ? rule.data.call(m) : {}
          Events.emit(rule.event, (data || {}).merge(raw: line))
        rescue StandardError => e
          Events.emit(:watch_error, event: rule.event, error: "#{e.class}: #{e.message}")
        end
        nil
      end

      # The DownstreamHook body: `process` each String line and pass it on
      # unchanged.
      #
      # @return [Proc]
      def hook_proc
        proc do |line|
          process(line) if line.is_a?(String)
          line
        end
      end

      # Subscribe to Lich's facts (the tracker on, attack events emitted),
      # refresh message subscriptions when definitions reload, and install
      # a hook when the script has rules of its own.
      #
      # @param name [String] the DownstreamHook name for the rules hook
      # @return [void]
      def install!(name: HOOK_NAME)
        @subscription_mutex.synchronize do
          tracker = ::Lich::Gemstone::Combat::Tracker
          tracker.enable! unless tracker.enabled?
          tracker.configure(emit_attacks: true) unless tracker.settings[:emit_attacks]
          @handlers.each_value { |h| tracker.off(h) }
          handlers = @handlers = {}
          handlers[:reload] = tracker.on(:definitions_reloaded, name: "#{NAME}:definitions_reloaded") do |_type, _data|
            refresh_messages(tracker, handlers)
          end
          subscribe_messages(tracker, handlers)
          handlers[:ucs] = tracker.on(:ucs, name: "#{NAME}:ucs") { |_type, data| ucs(data) }
          handlers[:attack] = tracker.on(:attack, name: "#{NAME}:attack") { |_type, data| attack(data) }
          ::DownstreamHook.remove(@installed) if @installed
          @installed = nil
          return if rules.empty?

          ::DownstreamHook.add(name, hook_proc, persist: false)
          @installed = name
        end
      end

      # Drop the tracker handlers and the rules hook, if one was installed.
      #
      # @return [void]
      def uninstall!
        @subscription_mutex.synchronize do
          tracker = ::Lich::Gemstone::Combat::Tracker
          @handlers.each_value { |h| tracker.off(h) }
          @handlers = {}
          ::DownstreamHook.remove(@installed) if @installed
          @installed = nil
        end
      end

      # @return [Boolean] true while tracker handlers are registered
      def installed? = @subscription_mutex.synchronize { @handlers.any? }

      private

      # Observers.emit snapshots callbacks before calling them; an old
      # reload callback must not recreate handlers after uninstall/reinstall.
      def refresh_messages(tracker, handlers)
        @subscription_mutex.synchronize do
          subscribe_messages(tracker, handlers) if @handlers.equal?(handlers)
        end
      end

      # Messages.events is authoritative; reload payloads need not list names.
      # Observers.on replaces the named handler across all its old event lists.
      def subscribe_messages(tracker, handlers)
        events = ::Lich::Gemstone::Combat::Messages.events
        if events.empty?
          tracker.off(handlers.delete(:messages)) if handlers[:messages]
        else
          handlers[:messages] = tracker.on(*events, name: "#{NAME}:messages") { |type, data| message(type, data) }
        end
      end

      # The disarm's moment (ecleanse set_hooks: the hands and the room).
      def disarm_data
        world = World.new
        { hands: world.hands, room_id: world.room.id, title: world.room.title }
      rescue StandardError
        { hands: nil, room_id: nil, title: nil }
      end

      def room_id
        World.new.room.id
      rescue StandardError
        nil
      end

      # bigshot hunt_monitor 2359: a shrugged item that is ours (in our
      # inventory or in hand).
      def mine?(id, noun)
        world = World.new
        world.me.inventory_ids.include?(id.to_s) || [world.hands.right, world.hands.left].any? { |h| h.noun.to_s == noun.to_s }
      rescue StandardError
        false
      end
    end
  end
end
