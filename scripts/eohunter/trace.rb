# frozen_string_literal: true

# ============================================================================
# trace (the debug log)
# ============================================================================

#
# EO::Engine::Trace - what the engine is thinking, as lines.
#
# bigshot has a debug mode: a global switch, four categories, a file
# mirror of the game feed, and a debug_msg at every decision. The engine
# already narrates every decision as an event on the bus, so the trace is
# a filtered subscriber: each event type belongs to a category, a
# Settings says which categories are on and where the lines go, and a
# Session turns the events (and, on request, every completed tick) into
# one line each for the sinks it was given.
#
# The engine knows nothing of Lich here: the sinks are callables taking a
# String, and the script (eohunter.lic) supplies the front-end and file
# ones, the game-feed mirror, and the CharSettings the Settings persist
# in. That keeps this file testable outside Lich with the rest.
#
module EO::Engine
  # The debug trace; see the file header.
  module Trace
    # Every event type the engine emits, by category. An event in none of
    # these lands under :engine, so a new event is never silently dropped.
    CATEGORIES = {
      combat: %i[engaged disengaged routine_action_started routine_action_resolved routine_unsupported
                 combat_blocked combat_blocked_departure incoming_swing ally_attacked force_roll
                 unarmed_followup unarmed_tier ammo_no_effect untargetable_learned],
      movement: %i[go2_status travel_blocked travel_started travel_arrived travel_failed travel_suspended entered_room out_of_bounds
                   fog_return tracked uncovered hidden_arrival],
      rest: %i[rest_started resting rested rest_finished rest_destination rest_retry rest_stuck rest_stranded
               rest_service_failed town_rest_complete final_loot_done overkill loot_script_started loot_stuck],
      group: %i[order followers_ready waiting_for_followers follower_lost loot_assigned hunt_over hunt_ended
                coordination_return_required],
      recovery: %i[fleeing cleansing cleansed cleanse_stuck died deader disarmed rooted out_of_mana
                   too_injured_for_wands no_fresh_wands maintain_stuck loadout_stuck buff_policy_status
                   preparation_failed],
      bounty: %i[bounty_hunt bounty_stage bounty_waiting bounty_removing bounty_script bounty_error
                 bounty_unsupported],
      engine: %i[engine_started engine_stopped engine_error watchdog_tripped preempted watch_error]
    }.freeze

    # The category names, in the order the help lists them.
    NAMES = CATEGORIES.keys.freeze

    # Lookup from event type to category, built once.
    CATEGORY_OF = CATEGORIES.each_with_object({}) { |(cat, types), h| types.each { |t| h[t] = cat } }.freeze

    # The widest a payload string is printed; the game's long lines are
    # in the feed mirror, not the event line.
    VALUE_WIDTH = 120

    # @param type [Symbol] an event type
    # @return [Symbol] its category; :engine for one the table does not know
    def self.category_of(type) = CATEGORY_OF.fetch(type, :engine)

    # What is on. A plain Hash with String keys, so it round-trips through
    # CharSettings unchanged:
    #
    #   'on'         => false   the master switch
    #   'categories' => ['combat', ...] or 'all'
    #   'tick'       => false   one line per completed tick
    #   'feed'       => false   the raw game feed mirrored into the file
    #   'file'       => false   write to the file as well as the front end
    #
    module Settings
      DEFAULT = { 'on' => false, 'categories' => 'all', 'tick' => false, 'feed' => false, 'file' => false }.freeze
      SWITCHES = %w[tick feed file].freeze
      ON = /\A(on|true|yes|1)\z/i
      OFF = /\A(off|false|no|0)\z/i

      # @param raw [Hash, nil] what CharSettings holds, possibly partial or nil
      # @return [Hash] a complete settings Hash, defaults filled in
      def self.from(raw)
        DEFAULT.merge((raw || {}).to_h.transform_keys(&:to_s)).slice(*DEFAULT.keys)
      end

      # The categories a settings Hash turns on.
      #
      # @param settings [Hash]
      # @return [Array<Symbol>] every name when 'categories' is 'all'
      def self.categories(settings)
        cats = settings['categories']
        return NAMES if cats.to_s == 'all'

        Array(cats).map(&:to_sym) & NAMES
      end

      # Whether a settings Hash shows this category.
      #
      # @param settings [Hash]
      # @param category [Symbol]
      # @return [Boolean]
      def self.shows?(settings, category) = settings['on'] == true && categories(settings).include?(category)

      # Apply the words of a `debug` command to a settings Hash.
      #
      #   (nothing) / status      unchanged
      #   on | off                the master switch
      #   all                     every category, and on
      #   <cat>[,<cat>] [on|off]  these categories on (or off); on also sets the master switch.
      #                           From 'all' the list replaces; from a list it adds.
      #   tick|feed|file [on|off] the switch, toggled when no on/off follows
      #
      # Launch words take the same grammar after the word `debug`, and
      # `debug=combat,group` means `debug combat,group on`.
      #
      # @param settings [Hash] the current settings
      # @param words [Array<String>] the command's words after `debug`
      # @return [Hash] the new settings
      # @raise [ArgumentError] naming the word it did not understand
      def self.apply(settings, words)
        out = from(settings)
        words = words.flat_map { |w| w.to_s.sub(/\Adebug=/i, '').split(',') }.map(&:strip).reject(&:empty?)
        return out if words.empty? || words == ['status']

        head, *rest = words
        state = rest.last
        flag = state.to_s =~ ON ? true : (state.to_s =~ OFF ? false : nil)
        rest = rest[0...-1] unless flag.nil?
        case head.downcase
        when ON then out['on'] = true
        when OFF then out['on'] = false
        when 'all'
          out['categories'] = 'all'
          out['on'] = true
        when *SWITCHES
          raise ArgumentError, "debug #{head}: expected on or off, not #{rest.join(' ')}" unless rest.empty?

          out[head.downcase] = flag.nil? ? !out[head.downcase] : flag
        else
          named = ([head] + rest).map { |w| w.downcase.to_sym }
          unknown = named - NAMES
          unless unknown.empty?
            raise ArgumentError, "debug: unknown word #{unknown.join(', ')}; one of #{NAMES.join(', ')}, #{SWITCHES.join(', ')}, on, off, all"
          end

          current = categories(out)
          wanted = if flag == false then current - named
                   elsif out['categories'].to_s == 'all' then named
                   else current | named
                   end
          out['categories'] = wanted.size == NAMES.size ? 'all' : wanted.map(&:to_s)
          out['on'] = true if flag != false
        end
        out
      end

      # One line saying what is on.
      #
      # @param settings [Hash]
      # @return [String]
      def self.describe(settings)
        s = from(settings)
        return 'debug off' unless s['on']

        cats = s['categories'].to_s == 'all' ? 'all' : categories(s).join(',')
        extras = SWITCHES.select { |k| s[k] }
        "debug on: #{cats.empty? ? 'no categories' : cats}#{extras.empty? ? '' : " + #{extras.join(', ')}"}"
      end
    end

    # One payload value as text: symbols and numbers bare, strings quoted
    # when they hold a space, arrays joined, hashes flattened one level.
    #
    # @param value [Object]
    # @return [String]
    def self.format_value(value)
      case value
      when nil then '-'
      when true, false, Symbol, Numeric then value.to_s
      when Time then value.strftime('%H:%M:%S')
      when Array then value.map { |v| format_value(v) }.join(',')
      when Hash then value.map { |k, v| "#{k}:#{format_value(v)}" }.join(',')
      else
        text = value.to_s.gsub(/\s+/, ' ').strip
        text = "#{text[0, VALUE_WIDTH - 3]}..." if text.length > VALUE_WIDTH
        text =~ /[\s=]/ || text.empty? ? text.inspect : text
      end
    end

    # A payload as `k=v k=v`.
    #
    # @param data [Hash]
    # @return [String]
    def self.format_data(data)
      data.to_h.map { |k, v| "#{k}=#{format_value(v)}" }.join(' ')
    end

    # One event as a line.
    #
    # @param event [Events::Event]
    # @param room [Object, nil] the room id at the time
    # @return [String]
    def self.format_event(event, room: nil)
      stamp(event.at, category_of(event.type), room, "#{event.type} #{format_data(event.data)}".rstrip)
    end

    # The line's fixed columns: time, category, room, then the text.
    #
    # @param at [Time]
    # @param category [Symbol]
    # @param room [Object, nil]
    # @param text [String]
    # @return [String]
    def self.stamp(at, category, room, text)
      format('%s %-8s %-6s %s', at.strftime('%H:%M:%S.%L'), category, room.nil? ? '-' : room.to_s, text)
    end

    # A subscription to the bus and the engine, writing lines to sinks.
    # Built once by the script; `configure` changes what it shows while
    # it runs, so a `;eohunter debug` from another invocation takes
    # effect within a tick without restarting the hunt.
    class Session
      # @return [Hash] the current settings (see Settings)
      attr_reader :settings

      # @param sinks [Array<#call>] each takes one String line
      # @param settings [Hash, nil] the initial settings
      # @param clock [#call] the current Time, for the tick line
      def initialize(sinks:, settings: nil, clock: -> { Time.now })
        @sinks = Array(sinks)
        @settings = Settings.from(settings)
        @clock = clock
        @room = nil
        @handler = nil
        @engine = nil
      end

      # Subscribe to every event, and to the engine's completed ticks.
      #
      # @param engine [Engine, nil] the running engine, for the tick line; nil for events alone
      # @return [self]
      def install!(engine = nil)
        @handler ||= Events.on(:any) { |event| on_event(event) }
        if engine && !@engine
          @engine = engine
          engine.on_tick_completed { |world, tick, status| on_tick(world, tick, status) }
        end
        self
      end

      # Drop the bus subscription. The engine callback stays registered
      # (the engine has no off) but writes nothing once settings are off.
      #
      # @return [void]
      def uninstall!
        Events.off(@handler) if @handler
        @handler = nil
      end

      # Change what is shown. Cheap when nothing changed, so the script
      # may call it every tick with whatever CharSettings holds.
      #
      # @param settings [Hash, nil]
      # @return [Boolean] true when the settings changed
      def configure(settings)
        fresh = Settings.from(settings)
        return false if fresh == @settings

        @settings = fresh
        true
      end

      # @return [Boolean] true while anything is written
      def on? = @settings['on'] == true

      # Whether this category is currently shown.
      #
      # @param category [Symbol]
      # @return [Boolean]
      def shows?(category) = Settings.shows?(@settings, category)

      # Write one line to every sink, if the trace is on. The sinks are
      # the script's (front end, file); a sink that raises is dropped for
      # this line only, never breaking the emitter.
      #
      # @param line [String]
      # @return [void]
      def write(line)
        return unless on?

        @sinks.each do |sink|
          begin
            sink.call(line)
          rescue StandardError
            nil
          end
        end
      end

      # A line not from an event (the header, a settings change), stamped
      # under :engine.
      #
      # @param text [String]
      # @return [void]
      def note(text) = write(Trace.stamp(@clock.call, :engine, @room, text))

      private

      def on_event(event)
        @room = event.data[:room] if event.type == :entered_room
        category = Trace.category_of(event.type)
        return unless shows?(category)

        write(Trace.format_event(event, room: @room))
      end

      # The arbiter's view of the tick: who held it and what came of it,
      # then every behavior above that declined and, when the behavior
      # says, why. bigshot cannot print this because it has no arbiter;
      # here it is the answer to "why is it doing that instead".
      def on_tick(world, tick, status)
        return unless on? && @settings['tick']

        @room = world.room.id if world.respond_to?(:room)
        result = @engine.respond_to?(:last_result) ? @engine.last_result : nil
        held = status[:behavior] || 'idle'
        outcome = if result.respond_to?(:status)
                    "status=#{result.status}#{result.reason ? " reason=#{result.reason}" : ''}#{result.line ? " line=#{Trace.format_value(result.line)}" : ''}"
                  else
                    'status=-'
                  end
        declined = Array(@engine.last_evaluations).reject { |_n, wanted| wanted }.map { |n, _| "#{n}=#{reason_of(n)}" }
        text = "tick ##{tick} holder=#{held} #{outcome}"
        text += " | declined: #{declined.join(' ')}" unless declined.empty?
        write(Trace.stamp(@clock.call, :engine, @room, text))
      end

      def reason_of(name)
        behavior = Array(@engine.respond_to?(:behaviors) ? @engine.behaviors : nil).find { |b| b.name == name }
        reason = behavior.respond_to?(:reason) ? behavior.reason : nil
        reason.nil? ? 'none' : Trace.format_value(reason)
      end
    end
  end
end
