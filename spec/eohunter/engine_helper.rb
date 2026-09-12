# frozen_string_literal: true

# Loads scripts/eohunter/engine.rb (and its parts) outside Lich, once per
# rspec process.
require 'rspec'

# The parts name Script and Lich::Messaging; neither is exercised by these
# specs, but the constants must resolve.
module Lich
  module Messaging
    def self.msg(_kind, _text); end unless respond_to?(:msg)
  end

  # Cleanse pulses mana through Lich's Mana.pulse (lich-5 #1580); the
  # specs never reach the game, so it answers "not pulsed".
  module Gemstone
    module Mana
      def self.pulse(*) = false unless respond_to?(:pulse)
    end

    # Watch subscribes to Lich's parser seam (lich-5 #1586). The stand-in
    # records the handlers so a spec can feed them facts.
    module Combat
      module Messages
        def self.events = %i[disarm_seen sanctum_transform itchy_curse infected_wound hive_trap entangled ambusher bolted rooted unrooted
                             item_limit bless_shrugged bless_expired arrow_stuck aiming bond_return haze_703 rebuke_1614 swift_justice
                             arcane_reflex weapon_reaction] unless respond_to?(:events)
      end

      module Tracker
        class << self
          def handlers = @handlers ||= {}
          def names = @names ||= {}
          def settings = @settings ||= { emit_attacks: false }
          def enabled? = @enabled ||= false
          def enable! = @enabled = true
          def configure(opts) = settings.merge!(opts)

          def on(*types, name: nil, &block)
            if name
              off(name)
              names[name.to_s] = block
            end
            types = [:any] if types.empty?
            types.each { |t| (handlers[t.to_sym] ||= []) << block }
            block
          end

          def off(handler_or_name)
            handler = handler_or_name.is_a?(Proc) ? handler_or_name : names.delete(handler_or_name.to_s)
            names.delete_if { |_, h| h == handler }
            handlers.each_value { |list| list.delete(handler) } if handler
            nil
          end

          # A fact from Lich, to whoever subscribed.
          def emit(type, data)
            (Array(handlers[type]).dup + Array(handlers[:any]).dup).each { |h| h.call(type, data) }
          end

          def reset! = (@handlers = {}; @names = {}; @enabled = false; @settings = { emit_attacks: false })
        end
      end
    end
  end
end

class Script
  def self.current; end unless respond_to?(:current)
end

# Lich's roundtime waits (lich-5 #1587), which Actions::Base#game_wait_rt
# calls; the specs have no roundtime to wait out, and the few that check
# the waiting stub game_wait_rt itself.
def waitrt?(**) = false unless respond_to?(:waitrt?, true)
def waitcastrt?(**) = false unless respond_to?(:waitcastrt?, true)

load File.expand_path('../../scripts/eohunter/engine.rb', __dir__) unless defined?(EO::Engine::Engine)
