# frozen_string_literal: true

require 'ostruct'
require_relative 'engine_helper'

# Actions::Base: bigshot's send ladder with bounds, and the three
# confirmation shapes. The game is a scripted queue: each send pushes the
# replies scripted for that command.
RSpec.describe EO::Engine::Actions::Base do
  let(:me) do
    OpenStruct.new(dead?: false, in_rt?: false, in_cast_rt?: false, stunned?: false, webbed?: false)
  end
  let(:world) { OpenStruct.new(me: me) }
  let(:replies) { Hash.new { |h, k| h[k] = [] } }
  let(:sent) { [] }
  let(:slept) { [] }

  # A concrete action whose perform is chosen per example.
  let(:action_class) do
    Class.new(described_class) do
      attr_accessor :perform_block

      def preconditions = :ok

      def perform = perform_block.call(self)
    end
  end

  def build(interrupt: nil, **opts)
    action = action_class.new(world, interrupt: interrupt, **opts)
    queue = []
    allow(action).to receive(:game_send) { |cmd| sent << cmd; queue.concat(replies[cmd].shift || []); queue.first || :no_response }
    allow(action).to receive(:next_line) { queue.shift }
    allow(action).to receive(:unread_line) { |line| queue.unshift(line) }
    allow(action).to receive(:sleep) { |s| slept << s }
    allow(action).to receive(:live_target_ids).and_return(nil)
    # a clock that advances a little on every read, so deadlines can pass
    tick = 0.0
    allow(action).to receive(:clock_now) { tick += 0.01; Time.at(tick) }
    action
  end

  def ladder(action, command)
    action.send(:send_through_ladder, command)
  end

  # The refusal ladder itself is fput's (lich-5 #1587, specced there);
  # the engine's part is naming its answers.
  describe 'the send ladder' do
    it 'returns the answer line and leaves it for the confirmation step' do
      replies['attack #1'] << ['You swing a broadsword at a kobold!']
      action = build
      expect(ladder(action, 'attack #1')).to eq('You swing a broadsword at a kobold!')
      expect(action.send(:next_line)).to eq('You swing a broadsword at a kobold!')
    end

    it 'asks fput for the bounds: the cap, the deadline, the interrupt, named failures' do
      stopping = -> { false }
      action = action_class.new(world, interrupt: stopping)
      expect(action).to receive(:fput).with('attack #1', max_resends: described_class::MAX_RESENDS,
                                                         timeout: described_class::SEND_DEADLINE,
                                                         interrupt: stopping, resend_transient: false,
                                                         failures: :symbol).and_return('You swing')
      expect(ladder(action, 'attack #1')).to eq('You swing')
    end

    # fput's transient rung matches "don't seem" (global_defs.rb 1760), and
    # with resend_transient on it sleeps and sends again up to the cap. That
    # is right for a stun and wrong for a severed leg: the command went out
    # five times, came back :too_many_resends, and the repeated-failures
    # watchdog counted every one. bigshot reads the line once instead, as
    # part of its cmd_* dothistimeout match sets (4733, 5255).
    describe 'a refusal the ladder caught' do
      let(:action) { action_class.new(world) }

      def refuse_with(line)
        calls = []
        allow(action).to receive(:fput) do |_cmd, **opts|
          calls << opts[:resend_transient]
          calls.length == 1 ? :refused : 'You swing'
        end
        allow(action).to receive(:next_line).and_return(line)
        allow(action).to receive(:unread_line)
        [ladder(action, 'attack #1'), calls]
      end

      it 'is named, not resent, when the injury is permanent' do
        result, calls = refuse_with("You don't seem to be able to move your legs to do that.")
        expect(result).to be_a(EO::Engine::Actions::Result)
        expect(result.reason).to eq(:injured)
        expect(calls).to eq([false]) # sent once, never resent
      end

      it 'is named for a wounded arm too' do
        result, = refuse_with("You don't seem to be able to move your arms to do that.")
        expect(result.reason).to eq(:injured)
      end

      it 'is resent when it is the transient kind bs_put resends' do
        result, calls = refuse_with('You are still stunned.')
        expect(result).to eq('You swing')
        expect(calls).to eq([false, true]) # second pass resends
      end
    end

    it 'turns each of fput\'s failures into a failed Result' do
      %i[too_many_resends interrupted dead no_response].each do |reason|
        action = build
        allow(action).to receive(:game_send).and_return(reason)
        result = ladder(action, 'attack #1')
        expect(result).to be_a(EO::Engine::Actions::Result)
        expect(result.reason).to eq(reason)
      end
    end

    it 'treats no answer at all as :no_response' do
      action = build
      allow(action).to receive(:game_send).and_return(nil)
      expect(ladder(action, 'attack #1').reason).to eq(:no_response)
    end
  end

  describe '#send_and_match' do
    it 'succeeds on the first line matching the result regex' do
      replies['cman feint #1'] << ['You feint to the left of a kobold!', 'Roundtime: 3 sec.']
      action = build
      action.perform_block = ->(a) { a.send(:send_and_match, 'cman feint #1', /You feint|Roundtime/) }
      result = action.call
      expect(result).to be_success
      expect(result.line).to eq('You feint to the left of a kobold!')
    end

    it 'times out with :no_confirmation when nothing matches' do
      replies['cman feint #1'] << ['Something unexpected.']
      action = build
      action.perform_block = ->(a) { a.send(:send_and_match, 'cman feint #1', /You feint/, timeout: 0.05) }
      result = action.call
      expect(result.status).to eq(:timeout)
      expect(result.reason).to eq(:no_confirmation)
    end
    # The read loop is where an action spends most of its time, so both
    # escapes out of it matter: the engine stopping, and the character
    # dying while we wait. Deleting either line used to leave the whole
    # suite green.
    it 'gives up mid-read when the engine is stopping' do
      replies['cman feint #1'] << ['Something unexpected.']
      action = build
      stopping = false
      allow(action).to receive(:interrupted?) { stopping }
      action.perform_block = lambda do |a|
        stopping = true # the engine stops while we are reading
        a.send(:send_and_match, 'cman feint #1', /You feint/, timeout: 5)
      end

      result = action.call
      expect(result.status).to eq(:failed)
      expect(result.reason).to eq(:interrupted)
    end

    it 'gives up mid-read when the character dies' do
      replies['cman feint #1'] << ['Something unexpected.']
      action = build
      action.perform_block = lambda do |a|
        me[:dead?] = true # the swing that killed us landed while we waited
        a.send(:send_and_match, 'cman feint #1', /You feint/, timeout: 5)
      end

      result = action.call
      expect(result.status).to eq(:failed)
      expect(result.reason).to eq(:dead)
    end
  end

  describe '#send_and_observe' do
    it 'succeeds once the world shows the change' do
      replies['stand'] << ['You stand back up.']
      standing = [false, false, true]
      action = build
      action.perform_block = ->(a) { a.send(:send_and_observe, 'stand') { standing.shift } }
      expect(action.call).to be_success
    end

    it 'times out with :state_unchanged' do
      replies['stand'] << ['You are already standing.']
      action = build
      action.perform_block = ->(a) { a.send(:send_and_observe, 'stand', timeout: 0.05) { false } }
      expect(action.call.reason).to eq(:state_unchanged)
    end
  end

  describe '#send_and_await' do
    let(:events) { EO::Engine::Events }
    let(:action) { build }

    before do
      action.perform_block = ->(a) { a.send(:send_and_await, 'feed my crystal', :user_feed_result, timeout: 0) }
    end
    after { events.reset! }

    def expect_unsubscribed
      expect(events.instance_variable_get(:@waiters)).to be_empty
    end

    it 'arms before sending so an immediate answer is confirmed and stamped acted' do
      event = nil
      expect(action).to receive(:game_send).with('feed my crystal').once do
        event = events.emit(:user_feed_result, item: 'crystal', ok: true)
        'You feed the crystal.'
      end
      result = action.call
      expect(result).to have_attributes(status: :success, event: event)
      expect(result).to be_acted
      expect_unsubscribed
    end

    it 'correlates the response without filtering out a negative outcome' do
      action.perform_block = lambda do |a|
        a.send(:send_and_await, 'feed my crystal', :user_feed_result,
               timeout: 0, matcher: ->(event) { event.data[:item] == 'crystal' })
      end
      expect(action).to receive(:game_send).once do
        events.emit(:user_feed_result, item: 'amulet', ok: true)
        events.emit(:user_feed_result, item: 'crystal', ok: false)
        'The crystal refuses.'
      end
      result = action.call
      expect(result).to be_success
      expect(result.event.data).to eq(item: 'crystal', ok: false)
      expect_unsubscribed
    end

    it 'times out without retrying or accepting a pre-arm response' do
      events.emit(:user_feed_result, item: 'crystal', ok: true)
      expect(action).to receive(:game_send).with('feed my crystal').once.and_return('Waiting...')
      result = action.call
      expect(result).to have_attributes(status: :timeout, reason: :no_confirmation, event: nil)
      expect(result).to be_acted
      expect_unsubscribed
    end

    it 'preserves a ladder Result and its details even if an event arrived' do
      failure = EO::Engine::Actions::Result.new(status: :failed, reason: :injured, line: 'Too injured.')
      expect(action).to receive(:game_send).once do
        events.emit(:user_feed_result, ok: true)
        failure
      end
      expect(action.call).to equal(failure)
      expect(failure).to have_attributes(status: :failed, reason: :injured, line: 'Too injured.', acted: true)
      expect_unsubscribed
    end

    it 'preserves named ladder failures without waiting' do
      expect(action).to receive(:game_send).once.and_return(:no_response)
      expect(action.call).to have_attributes(status: :failed, reason: :no_response, acted: true)
      expect_unsubscribed
    end

    it 'reports an interrupt that arrives while sending' do
      stopping = false
      allow(action).to receive(:interrupted?) { stopping }
      expect(action).to receive(:game_send).once do
        stopping = true
        'Waiting...'
      end
      expect(action.call).to have_attributes(status: :failed, reason: :interrupted, acted: true)
      expect_unsubscribed
    end

    it 'reports death that arrives while sending' do
      expect(action).to receive(:game_send).once do
        me[:dead?] = true
        'Waiting...'
      end
      expect(action.call).to have_attributes(status: :failed, reason: :dead, acted: true)
      expect_unsubscribed
    end

    it 'cancels when sending raises' do
      expect(action).to receive(:game_send).once.and_raise('send failed')
      expect { action.call }.to raise_error('send failed')
      expect_unsubscribed
    end

    it 'rejects invalid timeouts before sending or arming' do
      expect(action).not_to receive(:game_send)
      expect(events).not_to receive(:arm)
      [Float::INFINITY, -Float::INFINITY, Float::NAN, -1, -0.01, Complex(1, 1), '1', nil, true].each do |timeout|
        action.perform_block = ->(a) { a.send(:send_and_await, 'feed my crystal', :user_feed_result, timeout: timeout) }
        expect { action.call }.to raise_error(ArgumentError, /timeout must be/)
      end
      expect_unsubscribed
    end

    it 'reports bus reset as cancellation rather than an elapsed timeout' do
      expect(action).to receive(:game_send).once do
        events.reset!
        'Waiting...'
      end
      expect(action.call).to have_attributes(status: :failed, reason: :cancelled, acted: true)
      expect_unsubscribed
    end
  end

  describe 'the engine interrupt' do
    after { described_class.interrupt = nil }

    # 46 call sites build actions, each forwarding an @interrupt it was
    # handed; nothing supplied a root one, so every interrupted? guard in
    # the engine was inert and stop! could not shorten a wait in flight.
    it 'is inherited by an action that was not given its own' do
      described_class.interrupt = -> { true }
      action = build
      action.perform_block = ->(_a) { raise 'must not perform: interrupted' }
      expect(action.call).to have_attributes(reason: :interrupted)
    end

    it 'yields to an interrupt passed explicitly' do
      described_class.interrupt = -> { true }
      action = build(interrupt: -> { false })
      action.perform_block = ->(_a) { EO::Engine::Actions::Result.new(status: :success) }
      expect(action.call).to be_success
    end
  end

  describe '#call' do
    # Every gate returns before perform, so the game heard nothing: the
    # action declined itself. :failed is for a command the game refused,
    # which is what the repeated-failures watchdog counts (runner.rb 215).
    # A muckled tick used to read as a failure, so five of them in five
    # ticks stopped a live hunt with nothing on the wire.
    it 'skips on a precondition without sending, and does not count as a failure' do
      action = build
      allow(action).to receive(:preconditions).and_return(:muckled)
      result = action.call
      expect(result.reason).to eq(:muckled)
      expect(result).to be_skipped
      expect(result).not_to be_failed
      expect(result).not_to be_acted
      expect(sent).to be_empty
    end

    it 'skips :target_gone after roundtime when the target left the live list' do
      action = build(target: OpenStruct.new(id: '7'))
      allow(action).to receive(:live_target_ids).and_return(['8'])
      action.perform_block = ->(_a) { raise 'must not perform' }
      result = action.call
      expect(result.reason).to eq(:target_gone)
      expect(result).to be_skipped
      expect(result).not_to be_failed
    end

    it 'skips while dead and while interrupted, both without sending' do
      dead = build
      me[:dead?] = true
      dead.perform_block = ->(_a) { raise 'must not perform' }
      expect(dead.call).to have_attributes(status: :skipped, reason: :dead)
      me[:dead?] = false

      stopping = build(interrupt: -> { true })
      stopping.perform_block = ->(_a) { raise 'must not perform' }
      expect(stopping.call).to have_attributes(status: :skipped, reason: :interrupted)
      expect(sent).to be_empty
    end

    it 'lets a collective word target through the live check, since it names no creature' do
      action = build(target: 'all')
      allow(action).to receive(:live_target_ids).and_return(['8'])
      action.perform_block = ->(_a) { EO::Engine::Actions::Result.new(status: :success) }
      expect(action.call).to be_success
    end

    it 'still checks a creature given by its bare id' do
      action = build(target: '7')
      allow(action).to receive(:live_target_ids).and_return(['8'])
      action.perform_block = ->(_a) { raise 'must not perform' }
      expect(action.call.reason).to eq(:target_gone)
    end

    it 'waits out hard roundtime but not cast roundtime by default' do
      action = build
      waited = []
      allow(action).to receive(:game_wait_rt) { |kind| waited << kind }
      action.perform_block = ->(_a) { EO::Engine::Actions::Result.new(status: :success) }
      expect(action.call).to be_success
      expect(waited).to eq([:hard])
    end

    it 'waits out cast roundtime too for a CombatRt action' do
      klass = Class.new(action_class) { include EO::Engine::Actions::CombatRt }
      action = klass.new(world)
      waited = []
      allow(action).to receive(:game_wait_rt) { |kind| waited << kind }
      action.perform_block = ->(_a) { EO::Engine::Actions::Result.new(status: :success) }
      expect(action.call).to be_success
      expect(waited).to eq(%i[hard cast])
    end

    it 'asks Lich to wait, capped and interruptible' do
      stopping = -> { false }
      action = action_class.new(world, interrupt: stopping)
      expect(action).to receive(:waitrt?).with(interrupt: stopping, cap: described_class::RT_SETTLE_CAP).and_return(false)
      action.send(:game_wait_rt, :hard)
      expect(action).to receive(:waitcastrt?).with(interrupt: stopping, cap: described_class::RT_SETTLE_CAP).and_return(false)
      action.send(:game_wait_rt, :cast)
    end
  end

  # The engine's fire budget counts commands the game received, and the
  # send seam is the only thing that knows. So Base stamps `acted` on the
  # way out of `call`, and nothing else may.
  describe 'the acted stamp' do
    it 'stamps a result whose perform sent a command, whatever the game answered' do
      replies['attack #1'] << ['You swing a broadsword at a kobold!']
      action = build
      action.perform_block = ->(a) { a.send(:send_and_match, 'attack #1', /swing/) }
      expect(action.call).to be_acted

      action = build
      allow(action).to receive(:game_send).and_return(:too_many_resends)
      action.perform_block = ->(a) { a.send(:send_and_match, 'attack #1', /swing/) }
      result = action.call
      expect(result).to be_failed
      expect(result).to be_acted
    end

    it 'does not stamp a perform that returned without sending, or a gate that refused before perform' do
      action = build
      action.perform_block = ->(_a) { EO::Engine::Actions::Result.new(status: :success, reason: :already_hidden) }
      expect(action.call).not_to be_acted
      expect(sent).to be_empty

      refused = action_class.new(world)
      allow(refused).to receive(:preconditions).and_return(:muckled)
      expect(refused.call).not_to be_acted
    end

    it 'starts each call clean, so one instance reused after a send does not carry the stamp' do
      replies['attack #1'] << ['You swing a broadsword at a kobold!']
      action = build
      action.perform_block = ->(a) { a.send(:send_and_match, 'attack #1', /swing/) }
      expect(action.call).to be_acted
      action.perform_block = ->(_a) { EO::Engine::Actions::Result.new(status: :success) }
      expect(action.call).not_to be_acted
    end

    it 'is set nowhere but Base: no behavior or action writes acted by hand' do
      root = File.expand_path('../../scripts', __dir__)
      offenders = Dir[File.join(root, '**', '*.{rb,lic}')].select do |path|
        next false if path.end_with?('eohunter/actions.rb')

        File.read(path) =~ /\bacted:\s|\.acted\s*=/
      end
      expect(offenders).to eq([])
      base = File.read(File.join(root, 'eohunter', 'actions.rb'))
      expect(base.scan(/\.acted\s*=/).size).to eq(1)
    end

    # @acted is the send flag, not the Result field above: an action may
    # set it where it reaches the game outside the ladder (Spell#cast,
    # Lich's move), and must, or the fire budget cannot see the command.
    # Each of these is a real send seam; the list is here so a new one is
    # a deliberate addition rather than an accident.
    it 'sets the send flag only at a seam that actually reaches the game' do
      root = File.expand_path('../../scripts', __dir__)
      seams = Dir[File.join(root, '**', '*.{rb,lic}')].each_with_object({}) do |path, found|
        count = File.read(path).scan(/@acted\s*=\s*true/).size
        found[File.basename(path)] = count if count.positive?
      end
      expect(seams).to eq('actions.rb' => 1, 'combat.rb' => 1, 'flee.rb' => 1, 'cleanse.rb' => 1)
    end
  end
end
