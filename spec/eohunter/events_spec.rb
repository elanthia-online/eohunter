# frozen_string_literal: true

require_relative 'engine_helper'

RSpec.describe EO::Engine::Events do
  after { described_class.reset! }

  describe '.on / .emit' do
    it 'delivers events to type subscribers' do
      seen = []
      described_class.on(:swing_resolved) { |e| seen << e }
      described_class.emit(:swing_resolved, endroll: 142)
      expect(seen.size).to eq(1)
      expect(seen.first.data[:endroll]).to eq(142)
    end

    it 'does not deliver other types' do
      seen = []
      described_class.on(:swing_resolved) { |e| seen << e }
      described_class.emit(:ward_resolved, margin: 3)
      expect(seen).to be_empty
    end

    it 'delivers everything to :any subscribers' do
      seen = []
      described_class.on(:any) { |e| seen << e.type }
      described_class.emit(:a)
      described_class.emit(:b)
      expect(seen).to eq([:a, :b])
    end

    it 'isolates subscriber errors and reports them' do
      reported = []
      described_class.error_reporter = ->(type, err) { reported << [type, err.message] }
      described_class.on(:tick) { raise 'boom' }
      survivor = []
      described_class.on(:tick) { survivor << 1 }
      expect { described_class.emit(:tick) }.not_to raise_error
      expect(survivor).to eq([1])
      expect(reported).to eq([[:tick, 'boom']])
    ensure
      described_class.error_reporter = nil
    end

    it 'unsubscribes via .off' do
      seen = []
      handler = described_class.on(:tick) { seen << 1 }
      described_class.off(handler)
      described_class.emit(:tick)
      expect(seen).to be_empty
    end
  end

  describe '.await' do
    it 'returns an event emitted from another thread' do
      thread = Thread.new do
        sleep 0.05
        described_class.emit(:swing_resolved, target: '123')
      end
      event = described_class.await(:swing_resolved, timeout: 2)
      thread.join
      expect(event).not_to be_nil
      expect(event.data[:target]).to eq('123')
    end

    it 'applies the matcher block' do
      thread = Thread.new do
        sleep 0.02
        described_class.emit(:swing_resolved, target: 'wrong')
        sleep 0.02
        described_class.emit(:swing_resolved, target: 'right')
      end
      event = described_class.await(:swing_resolved, timeout: 2) { |e| e.data[:target] == 'right' }
      thread.join
      expect(event.data[:target]).to eq('right')
    end

    it 'returns nil on timeout and cleans up its waiter' do
      expect(described_class.await(:never, timeout: 0.1)).to be_nil
      expect(described_class.instance_variable_get(:@waiters)).to be_empty
    end
  end

  describe '.arm' do
    def waiters = described_class.instance_variable_get(:@waiters)

    it 'captures the first matching response before wait starts' do
      handle = described_class.arm(:answer, :other) { |event| event.data[:item] == 'crystal' }
      described_class.emit(:unrelated, item: 'crystal')
      described_class.emit(:answer, item: 'other')
      first = described_class.emit(:other, item: 'crystal', ok: false)
      described_class.emit(:answer, item: 'crystal', ok: true)
      expect(handle.wait(timeout: 1)).to equal(first)
      expect(handle.reason).to eq(:confirmed)
      expect(waiters).to be_empty
    end

    it 'excludes events emitted before arming, even when their subscribers arm a waiter' do
      handle = nil
      described_class.on(:answer) { handle = described_class.arm(:answer) }
      described_class.emit(:answer)
      expect(handle.wait(timeout: 0)).to be_nil
      expect(handle.reason).to eq(:timeout)
      expect(waiters).to be_empty
    end

    it 'uses a monotonic deadline and slices waits to at most 50 ms' do
      handle = described_class.arm(:answer)
      now = 100.0
      waits = []
      allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC) { now }
      allow(handle).to receive(:sleep) { |seconds| waits << seconds; now += seconds }
      expect(Time).not_to receive(:now)
      expect(handle.wait(timeout: 0.12)).to be_nil
      expect(waits.sum).to be_within(0.0001).of(0.12)
      expect(waits).to all(be <= 0.05)
      expect(handle.reason).to eq(:timeout)
      expect(waiters).to be_empty
    end

    it 'rejects unbounded or invalid timeouts and still releases the subscription' do
      [Float::INFINITY, -Float::INFINITY, Float::NAN, -1, -0.01, Complex(1, 1), '1', nil, true].each do |timeout|
        handle = described_class.arm(:answer)
        expect { handle.wait(timeout: timeout) }.to raise_error(ArgumentError, /timeout must be/)
        expect(waiters).to be_empty
      end
    end

    it 'checks interrupt during a wait and unsubscribes' do
      handle = described_class.arm(:answer)
      stopping = false
      allow(handle).to receive(:sleep) { stopping = true }
      expect(handle.wait(timeout: 1, interrupt: -> { stopping })).to be_nil
      expect(handle.reason).to eq(:interrupted)
      expect(waiters).to be_empty
    end

    it 'checks the death predicate during a wait and unsubscribes' do
      handle = described_class.arm(:answer)
      dead = false
      allow(handle).to receive(:sleep) { dead = true }
      expect(handle.wait(timeout: 1) { dead }).to be_nil
      expect(handle.reason).to eq(:dead)
      expect(waiters).to be_empty
    end

    it 'lets interrupt and death win over an already queued answer' do
      handle = described_class.arm(:answer)
      described_class.emit(:answer)
      expect(handle.wait(timeout: 1, interrupt: -> { true })).to be_nil
      expect(handle.reason).to eq(:interrupted)

      handle = described_class.arm(:answer)
      described_class.emit(:answer)
      expect(handle.wait(timeout: 1) { true }).to be_nil
      expect(handle.reason).to eq(:dead)
    end

    it 'cancels idempotently and discards pending and later events' do
      handle = described_class.arm(:answer)
      described_class.emit(:answer)
      expect(handle.cancel).to be_nil
      expect(handle.cancel).to be_nil
      described_class.emit(:answer)
      expect(handle.wait(timeout: 1)).to be_nil
      expect(handle.reason).to eq(:cancelled)
      expect(waiters).to be_empty
    end

    it 'can cancel during a wait' do
      handle = described_class.arm(:answer)
      allow(handle).to receive(:sleep) { handle.cancel }
      expect(handle.wait(timeout: 1)).to be_nil
      expect(handle.reason).to eq(:cancelled)
      expect(waiters).to be_empty
    end

    it 'cancels old handles on reset and leaves new handles usable' do
      old = described_class.arm(:answer)
      allow(old).to receive(:sleep) { described_class.reset! }
      expect(old.wait(timeout: 1)).to be_nil
      expect(old.reason).to eq(:cancelled)
      fresh = described_class.arm(:answer)
      answer = described_class.emit(:answer)
      expect(fresh.wait(timeout: 1)).to equal(answer)
      expect(waiters).to be_empty
    end

    it 'does not deliver a snapshotted emission to a cancelled waiter' do
      handle = described_class.arm(:answer)
      described_class.on(:answer) { handle.cancel }
      described_class.emit(:answer)
      expect(handle.wait(timeout: 1)).to be_nil
      expect(waiters).to be_empty
    end

    it 'ignores a broken matcher without breaking the emitter or other waiters' do
      broken = described_class.arm(:answer) { raise 'bad filter' }
      other = described_class.arm(:answer)
      event = described_class.emit(:answer)
      expect(other.wait(timeout: 1)).to equal(event)
      expect(broken.wait(timeout: 0)).to be_nil
      expect(waiters).to be_empty
    end

    it 'unsubscribes if an interrupt or death predicate raises' do
      handle = described_class.arm(:answer)
      expect { handle.wait(timeout: 1, interrupt: -> { raise 'stop failed' }) }.to raise_error('stop failed')
      expect(waiters).to be_empty
      handle = described_class.arm(:answer)
      expect { handle.wait(timeout: 1) { raise 'world failed' } }.to raise_error('world failed')
      expect(waiters).to be_empty
    end

    it 'cannot return a confirmed event twice' do
      handle = described_class.arm(:answer)
      event = described_class.emit(:answer)
      expect(handle.wait(timeout: 1)).to equal(event)
      expect(handle.wait(timeout: 1)).to be_nil
      expect(handle.reason).to eq(:confirmed)
    end
  end
end
