# frozen_string_literal: true

# ============================================================================
# tracking (bigshot's bandit hunting and Ranger tracking)
# ============================================================================

#
# Bandits never appear in the room feed, so bigshot hunts them by scraping
# a manual LOOK and manufacturing the quarry with GameObj.new_npc
# (bandit_track 9459), one last look before leaving each room (bs_wander
# 9375). Bandit mode also relaxes the rules that would otherwise stop a
# bandit fight: the target list is the bandit nouns on the quick routine
# (sort_npcs 8622), priority never switches, should_flee? answers
# no past always_flee_from and the ambusher hook is off.
# It is turned on by ";bigshot bounty" when the bounty says "suppress
# bandit activity" (set_bounty_eval 3824, 3357) and by nothing else.
#
# Rangers TRACK toward a named creature when off cooldown before every
# wander step (ranger_track 9488): a trail moves us and we stay; "You
# don't have to go far" means it is hidden here, so we stay when the room
# is ours and move when it is not; anything else moves on. A room with
# nothing hostile showing gets an UNCOVER: 609 open for a Ranger
# with it, else SEARCH. The creature is the script's free argument
# (";bigshot single giant rat", 3331).
#
# Here: Tracking::Policy from the script's options and the bounty text,
# Actions::Track, Actions::Uncover, and Wander takes
# the policy. Rules and line references in hunting-engine-plan.md,
# "Bandits and tracking".
#
module EO::Engine
  # bigshot's bandit hunting and Ranger tracking as a Policy: the bandit
  # toggle from the script's words or the bounty, the Ranger's quarry
  # from "track <creature>", and the bandit target list for Targets.
  #
  # @bigshot bandit_track
  # @bigshot ranger_track
  module Tracking
    # bigshot: the nouns a bandit fight is made of.
    #
    # @bigshot bandit nouns
    BANDIT_NOUNS = /bandit|brigand|robber|thug|thief|rogue|outlaw|mugger|marauder|highwayman/i

    # +bandits+: hunt bandits; +creature+: the Ranger's quarry, nil for none.
    Policy = Struct.new(:bandits, :creature, keyword_init: true) do
      # @param bandits [Boolean] hunt bandits
      # @param creature [String, nil] the Ranger's quarry
      def initialize(bandits: false, creature: nil) = super

      # The bandit toggle, as true or false.
      #
      # @return [Boolean]
      def bandits? = bandits ? true : false
      # The quarry with its whitespace trimmed; "" for none.
      #
      # @return [String]
      def creature_name = creature.to_s.strip
      # A quarry is named.
      #
      # @return [Boolean]
      def tracking? = !creature_name.empty?
    end

    class << self
      # ";eohunter <profile> [bandits] [track <creature>]" plus bigshot's
      # "bandits when the bounty says so" (3357, 3824), which Lich's
      # Bounty::Task answers with bandit?. +words+ are the script's
      # arguments after the profile.
      #
      # The quarry is the one named after `track` (bounty mode names
      # ebounty's creature the same way), else the profile's
      # track_creature when its track setting is on: a run can track
      # something else without editing the hunt.
      #
      # @param words [Array<String>]
      # @param task [Lich::Gemstone::Bounty::Task, nil] the current
      #   bounty, nil to skip the check
      # @param profile [#[], nil] the hunt's settings, for track and
      #   track_creature
      # @return [Policy]
      # @bigshot set_bounty_eval
      def policy_from(words, task: nil, profile: nil)
        words = Array(words).map(&:to_s)
        bandits = words.any? { |w| w =~ /\Abandits?\z/i } || bandit_task?(task)
        creature = nil
        if (i = words.index { |w| w =~ /\Atrack\z/i })
          creature = words[(i + 1)..].join(' ')
        end
        creature = profile['track_creature'] if creature.to_s.strip.empty? && profile && profile['track']
        creature = creature.to_s.strip
        Policy.new(bandits: bandits, creature: creature.empty? ? nil : creature)
      end

      # The bounty says "suppress bandit activity": Lich's Bounty::Task
      # answers bandit?; anything without that method answers false.
      #
      # @param task [Lich::Gemstone::Bounty::Task, nil]
      # @return [Boolean]
      def bandit_task?(task)
        task.respond_to?(:bandit?) && task.bandit? ? true : false
      end

      # sort_npcs 8622-8631 in bandit mode: only the bandit nouns, on the
      # quick routine. Targets::Policy anchors each key.
      #
      # @return [Hash{String => String}] one pattern key to 'quick'
      # @bigshot sort_npcs
      def bandit_targets = { "(?:#{BANDIT_NOUNS.source})" => 'quick' }
    end
  end

  module Actions
    # ranger_track: TRACK <creature>, read as the game answers.
    # :trail (we followed it; success), :here (hidden in this room;
    # success), else failed with the reason.
    #
    # @bigshot ranger_track
    class Track < Base
      # The game's answers to TRACK, by the reason each one becomes.
      RESULTS = {
        trail: /Your keen eye spots the beginnings of a trail and you rush to follow it/,
        here: /You don't have to go far\./,
        too_old: /was here, but the trail is clearly too old to be worth following\./,
        no_trace: /While you carefully study the area looking for tracks, you find no trace of what you are looking for\./,
        town: /You don't know how to track creatures within town\./,
        cooldown: /You haven't yet recovered from your previous tracking exploit\./
      }.freeze

      # @param world [World]
      # @param creature [String] the quarry, as TRACK takes it
      # @param opts [Hash] Base's keywords (interrupt)
      def initialize(world, creature:, **opts)
        super(world, **opts)
        @creature = creature.to_s
      end

      # Dead, no creature named, not a Ranger, or Tracking on cooldown
      # refuses the track.
      #
      # @return [Symbol] :ok, or the gate that refused
      def preconditions
        return :dead if me.dead?
        return :no_creature if @creature.strip.empty?
        return :not_a_ranger unless me.profession.to_s =~ /Ranger/i
        return :cooldown if me.cooldown_active?('Tracking')

        :ok
      end

      # TRACK after roundtime, the answer read against RESULTS.
      #
      # @return [Actions::Result] success with :trail or :here; failed
      #   with :too_old, :no_trace, :town, :cooldown or :unknown
      def perform
        result = send_and_match("track #{@creature}", Regexp.union(*RESULTS.values), timeout: 1)
        return result unless result.success?

        kind = RESULTS.find { |_k, rx| result.line =~ rx }&.first
        status = %i[trail here].include?(kind) ? :success : :failed
        Result.new(status: status, reason: kind || :unknown, line: result.line)
      end
    end

    # uncover: reveal what hides here, only when nothing hostile
    # shows. 609 open for a Ranger who can afford it, else SEARCH.
    #
    # @bigshot uncover
    class Uncover < Base
      # Dead, or anything in the target list, refuses the uncover.
      #
      # @return [Symbol] :ok, or the gate that refused
      def preconditions
        return :dead if me.dead?
        return :creatures_here unless @world.room.targets.empty?

        :ok
      end

      # INCANT 609 OPEN for a Ranger who knows and can afford it, else
      # SEARCH when the injuries allow one.
      #
      # @return [Actions::Result] success with :spell_609 or :searched;
      #   failed with :too_injured
      def perform
        s = @world.spell[609]
        # The ladder answers a failed Result for :dead, :interrupted,
        # :too_many_resends and :no_response. Discarding it reported an
        # uncover that never happened - the caller then treats the room as
        # searched, so a stopping engine or a dead character looked like a
        # clean search.
        if me.profession.to_s =~ /Ranger/i && s&.known? && s.affordable?
          sent = send_through_ladder('incant 609 open')
          return sent if sent.is_a?(Result) && !sent.success?

          settle_rt
          Result.new(status: :success, reason: :spell_609)
        else
          # Lich's Injured: head, nerves and eyes decide whether a SEARCH
          # can see anything; the cast branch is able_to_cast?'s business.
          return Result.new(status: :failed, reason: :too_injured) unless me.able_to_search?

          sent = send_through_ladder('search')
          return sent if sent.is_a?(Result) && !sent.success?

          settle_rt
          Result.new(status: :success, reason: :searched)
        end
      end
    end
  end
end
