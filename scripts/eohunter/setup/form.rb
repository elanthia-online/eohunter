# frozen_string_literal: true

require 'yaml'

module EO
  module HunterSetup
    # What the editor window draws for each setting, and how a control's text
    # becomes a value and back.
    #
    # Kept apart from the window so it can be tested without a display: the
    # window only builds widgets for the kind named here and hands the text it
    # reads to #parse. Nothing here touches GTK.
    module Form
      # Settings the engine splits on commas. Stored as comma text, edited one
      # entry per line, because order matters for scripts and commands.
      LIST_CLEANERS = %w[split split_xx list rooms strict_rooms].freeze

      # Text longer than this is edited in a box of several lines.
      LONG_VALUE = 60

      module_function

      # The control a setting gets.
      #
      # @param editor [Editor] the editing session
      # @param field [Hash] a schema field descriptor
      # @return [Symbol] :equipment, :check, :choice, :list, :ruby, :text_block or :entry
      def kind(editor, field)
        key = field['key']
        return :equipment if editor.equipment_options(key)
        return :check if field['type'] == 'boolean'
        return :choice if Array(field['options']).any?
        return :entry if %w[integer number].include?(field['type'])
        return :ruby if Schema::RUBY_FIELDS.include?(key)
        return :list if list_field?(field)
        # A creature list stays a one-line box however long it gets: a box
        # that turned into a text block at the third name changed type under
        # the viewer, and the browser lost track of it.
        return :entry if Schema::CREATURE_LIST_KEYS.include?(key)
        return :text_block if structured?(field, editor.settings[key])

        :entry
      end

      # @param field [Hash] a schema field descriptor
      # @return [Boolean] whether it holds a comma list
      def list_field?(field)
        LIST_CLEANERS.include?(field['cleaner'].to_s) && Array(field['options']).empty?
      end

      # @param field [Hash] a schema field descriptor
      # @param value [Object] its current value
      # @return [Boolean] whether it needs more than one line
      def structured?(field, value)
        field['type'] == 'structured' || value.is_a?(Hash) || value.is_a?(Array) ||
          text(value).length > LONG_VALUE
      end

      # A value as the text a control shows.
      # @param value [Object]
      # @return [String]
      def text(value)
        case value
        when nil then ''
        when String then value
        when Hash, Array then YAML.dump(value).delete_prefix("---
")
        else value.to_s
        end
      end

      # A control's text as the value handed to Editor#on_change.
      #
      # Scalars go through as typed: the engine's own cleaners turn them into
      # numbers at validation, and an unset setting stays unset. A structured
      # setting is stored as data, so its YAML is parsed here; text that does
      # not parse is passed through as typed, and validation reports it.
      #
      # @param field [Hash] a schema field descriptor
      # @param input [String] what the control holds
      # @return [Object]
      def parse(field, input)
        return input unless field['type'] == 'structured'
        return '' if input.strip.empty?

        YAML.safe_load(input, permitted_classes: [Symbol])
      rescue Psych::Exception
        input
      end

      # A choice setting's options, with an unset entry first when the
      # schema offers none, so a setting can always be cleared.
      #
      # The schema gives options either as plain words or as value and label
      # pairs. A value that is none of them -- a Bigshot profile written by
      # hand, say -- is offered too, so opening a hunt never loses it.
      #
      # @param field [Hash] a schema field descriptor
      # @param value [Object] the setting's current value
      # @return [Array<Array(String, String)>] value and label pairs
      def choices(field, value = nil)
        value = Schema::ALIASES.dig(field['key'], value.to_s) || value
        options = Array(field['options']).map do |option|
          option.is_a?(Hash) ? [option['value'].to_s, (option['label'] || option['value']).to_s] : [option.to_s, option.to_s]
        end
        options = [['', '(unset)']] + options unless options.any? { |(id, _)| id.empty? }
        current = value.to_s
        unless current.empty? || chosen(options, current)
          options << [current, "#{current} (not a listed choice)"]
        end
        options
      end

      # Which option a value selects. Bigshot profiles were written by hand,
      # so `Offensive` selects `offensive`.
      #
      # @param options [Array<Array(String, String)>] from #choices
      # @param value [Object] the setting's current value
      # @return [String, nil] the option's value, or nil when none matches
      def chosen(options, value)
        text = value.to_s
        options.find { |(id, _)| id == text }&.first ||
          options.find { |(id, _)| id.casecmp?(text) }&.first
      end

      # The label, with its units when the schema names them.
      # @param field [Hash] a schema field descriptor
      # @return [String]
      def label(field)
        field['label'].to_s
      end

      # What a number is counted in, for the box's placeholder and tooltip.
      # @return [String] units, or ''
      def units(field)
        field['units'].to_s.strip
      end

      # What hovering a setting says: what it does, then where its value
      # comes from. An empty control does not mean the hunt has no value.
      #
      # @param editor [Editor] the editing session
      # @param field [Hash] a schema field descriptor
      # @return [String]
      def tooltip(_editor, field)
        help = field['help'].to_s.strip
        default = default_text(field)
        [help, default].reject(&:empty?).join(' ')
      end

      # The engine's default as a short sentence, or '' when it says nothing
      # worth reading: off, blank or empty.
      # @param field [Hash] a schema field descriptor
      # @return [String]
      def default_text(field)
        value = field['default']
        return '' if value.nil? || value == false || value == '' || value == [] || value == {}
        return 'On by default.' if value == true

        option = Array(field['options']).find { |entry| entry.is_a?(Hash) && entry['value'].to_s == value.to_s }
        shown = if option then option['label']
                elsif value.is_a?(Array) then value.join(', ')
                else text(value)
                end
        "Default: #{shown}."
      end

      # @param editor [Editor] the editing session
      # @param field [Hash] a schema field descriptor
      # @return [String] where the setting's effective value comes from
      def provenance(editor, field)
        key = field['key']
        return 'Set in this hunt' if editor.settings.key?(key)

        from = editor.provenance_for(key)
        return "From #{from.is_a?(String) ? from : from.inspect}" if from

        'Engine default'
      end

      # The last validation's messages for one setting.
      # @param editor [Editor] the editing session
      # @param key [String] native setting key
      # @return [Array<String>]
      def messages(editor, key)
        (editor.errors + editor.warnings).filter_map do |entry|
          next unless entry.is_a?(Hash) && (entry['key'] || entry[:key]) == key

          (entry['message'] || entry[:message]).to_s
        end
      end

      # A validation entry as one line.
      # @param entry [Hash, String]
      # @return [String]
      def message(entry)
        return entry.to_s unless entry.is_a?(Hash)

        key = entry['key'] || entry[:key]
        text = (entry['message'] || entry[:message] || entry.inspect).to_s
        key ? "#{key}: #{text}" : text
      end

      # A before or after value in the list of unsaved changes.
      # @param value [Object]
      # @param absent [String] what to say when there is none
      # @return [String]
      def change_text(value, absent)
        shown = text(value).strip
        shown.empty? ? absent : shown.lines.first.chomp + (shown.lines.size > 1 ? ' ...' : '')
      end
    end
  end
end
