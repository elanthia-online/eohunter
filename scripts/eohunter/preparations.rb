# frozen_string_literal: true

module EO::Engine
  # Profile-owned commands confirmed by Lich's named message events (issue #106).
  # Scheduling belongs to the existing routine modifiers and prep lists.
  class Preparations
    # Names stay unambiguous in the routine language and named event bus.
    NAME = /\A[a-z][a-z0-9_]*\z/
    # A confirmation cannot hold the engine tick indefinitely.
    MAX_TIMEOUT = 30
    # The only fields accepted in a preparation definition.
    FIELDS = %w[perform result match expect timeout].freeze

    # A validated command and its correlation/success criteria.
    Entry = Struct.new(:perform, :result, :match, :expect, :timeout, keyword_init: true)

    # @param raw [Hash] named preparation definitions from a profile
    # @raise [ArgumentError] for malformed or ambiguous definitions
    def initialize(raw = {})
      raise ArgumentError, 'preparations must be a mapping' unless raw.is_a?(Hash)

      @entries = raw.each_with_object({}) do |(name, definition), entries|
        name = identifier(name, 'name')
        raise ArgumentError, "duplicate preparation #{name}" if entries.key?(name)

        entries[name] = parse(definition, name)
      end.freeze
    end

    # @param name [String] the name in a prepare word
    # @return [Entry, nil] nil means an unknown preparation
    def [](name) = @entries[name.to_s]

    # @return [Boolean] true when the profile defines no preparations
    def empty? = @entries.empty?

    # Recognize the complete word; a malformed prepare word is an error,
    # never an arbitrary command sent to the game.
    # @param text [String] command without routine modifiers
    # @return [String, nil] preparation name, or nil for another word
    # @raise [ArgumentError] for malformed prepare words
    def self.name(text)
      return nil unless text.to_s.match?(/\Aprepare\b/i)
      return nil if text.to_s.match?(/\Aprepare\s+\d+(?:\s.*)?\z/i)

      match = /\Aprepare\s+([a-z][a-z0-9_]*)\z/i.match(text.to_s)
      raise ArgumentError, "invalid preparation word: #{text}" unless match

      match[1].downcase
    end

    # Compare scalar fields, including key presence; absent is not null.
    # Numbers compare by value across numeric types; other scalars stay strict.
    # String and symbol payload keys name the same field, as in Lich events.
    # @param data [Hash] the event payload
    # @param fields [Hash{Symbol => Object}] required scalar values
    # @return [Boolean]
    def self.matches?(data, fields)
      return false unless data.is_a?(Hash)

      fields.all? do |key, value|
        actual = data.key?(key) ? key : key.to_s
        next false unless data.key?(actual)

        observed = data[actual]
        if observed.is_a?(Numeric) && value.is_a?(Numeric)
          observed == value
        else
          observed.eql?(value)
        end
      end
    end

    private

    def identifier(value, label)
      unless (value.is_a?(String) || value.is_a?(Symbol)) && NAME.match?(value.to_s)
        raise ArgumentError, "preparations #{label} must be a lowercase identifier"
      end

      value.to_s.dup.freeze
    end

    def parse(raw, name)
      raise ArgumentError, "preparation #{name} must be a mapping" unless raw.is_a?(Hash)

      definition = raw.each_with_object({}) do |(key, value), fields|
        key = identifier(key, 'field')
        raise ArgumentError, "preparation #{name}: unknown or duplicate field #{key}" if !FIELDS.include?(key) || fields.key?(key)

        fields[key] = value
      end
      command = definition['perform']
      unless command.is_a?(String) && !command.strip.empty? && !command.match?(/[\x00-\x1f\x7f;]/)
        raise ArgumentError, "preparation #{name} perform must be one nonblank game command"
      end
      timeout = definition.fetch('timeout', Actions::Base::DEFAULT_TIMEOUT)
      unless timeout.is_a?(Numeric) && timeout.real? && timeout.finite? && timeout.positive? && timeout <= MAX_TIMEOUT
        raise ArgumentError, "preparation #{name} timeout must be finite and within (0, #{MAX_TIMEOUT}] seconds"
      end

      Entry.new(perform: command.strip.freeze, result: identifier(definition['result'], 'result').to_sym,
                match: scalar_fields(definition.fetch('match', {})), expect: scalar_fields(definition.fetch('expect', {})),
                timeout: timeout).freeze
    rescue ArgumentError => error
      raise ArgumentError, "preparation #{name}: #{error.message}"
    end

    def scalar_fields(raw)
      raise ArgumentError, 'preparation match and expect must be scalar mappings' unless raw.is_a?(Hash)

      raw.each_with_object({}) do |(key, value), fields|
        key = identifier(key, 'payload key').to_sym
        scalar = value.nil? || value == true || value == false || value.is_a?(String) || value.is_a?(Symbol) ||
                 (value.is_a?(Numeric) && value.real? && value.finite?)
        raise ArgumentError, "preparation payload #{key} must be a scalar with a unique key" if !scalar || fields.key?(key)

        fields[key] = value.is_a?(String) ? value.dup.freeze : value
      end.freeze
    end
  end

  # Game commands with the shared action contract.
  module Actions
    # One profile command, armed before sending and confirmed by a named fact.
    # A failed required preparation returns through the existing rest lifecycle;
    # replaying a possibly consumed item would require a player's decision.
    class Prepare < Base
      # @param world [World] live named-event availability and character state
      # @param name [String] profile preparation name
      # @param preparations [Preparations, nil] validated profile definitions
      # @param opts [Hash] shared action keywords
      def initialize(world, name:, preparations:, **opts)
        super(world, **opts)
        @name = name
        @entry = preparations&.[](name)
      end

      # Preserve the action outcome and acted stamp; signal a terminal failure.
      # Ordinary pre-send gates remain skips and do not start recovery.
      # @return [Result] confirmed, denied, unknown or declined outcome
      def call
        result = super
        Events.emit(:preparation_failed, name: @name, status: result.status, reason: result.reason) if result.failed?
        result
      end

      private

      def preconditions
        return :dead if me.dead?
        return :muckled if me.muckled?

        :ok
      end

      def perform
        return Result.new(status: :failed, reason: :unknown_preparation) unless @entry
        return Result.new(status: :failed, reason: :unknown_event) unless @world.message_events.include?(@entry.result)

        matcher = ->(event) { Preparations.matches?(event.data, @entry.match) }
        result = send_and_await(@entry.perform, @entry.result, timeout: @entry.timeout, matcher: matcher)
        return result unless result.success?

        result.status = :failed unless Preparations.matches?(result.event.data, @entry.expect)
        result.reason = result.success? ? :prepared : :denied
        result
      end
    end
  end
end
