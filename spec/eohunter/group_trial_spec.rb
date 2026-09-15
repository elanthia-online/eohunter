# frozen_string_literal: true

require_relative 'engine_helper'
require_relative '../../scripts/eohunter/group_trial'

RSpec.describe EO::Engine::GroupTrial do
  let(:time) { [100.0] }
  let(:clock) { -> { time.first } }
  let(:identities) do
    [{ character: 'First', session: 'session-one', run_id: 'run-one' },
     { character: 'Second', session: 'session-two', run_id: 'run-two' }]
  end
  let(:session) do
    described_class::Session.new(identities: identities, refuge_room: 1000,
                                 work_seconds: 10, return_seconds: 15,
                                 startup_seconds: 5, freshness_seconds: 2, clock: clock)
  end

  def participant(index, transport: session)
    state = { session: identities[index][:session], room_id: 1000, fresh: true,
              connected: true, alive: true, stable: true, owner: true,
              ready: true, standing: true, hands: ["#{index + 10}", nil] }
    calls = []
    authority = [true]
    instance = described_class::Participant.new(
      session: transport, identity: identities[index], snapshot: -> { state.dup },
      authority: -> { authority.first }, start: -> { calls << :start },
      return_to_refuge: ->(reason) { calls << [:return, reason] },
      stop: ->(reason) { calls << [:stop, reason] }, clock: clock
    )
    { instance: instance, state: state, calls: calls, authority: authority }
  end

  def activated_pair
    first, second = participant(0), participant(1)
    first[:instance].tick
    second[:instance].tick
    [first, second]
  end

  def finish(member)
    member[:state].update(room_id: 1000, owner: false, owner_released: true, children_released: true)
    member[:instance].finish!
  end

  it 'does not start or allow sends until both exact members report ready' do
    first = participant(0)
    first[:instance].tick
    expect(first[:calls]).to be_empty
    expect(first[:instance].commands_permitted?).to be(false)
    second = participant(1)
    first[:instance].tick
    second[:instance].tick
    expect(first[:calls]).to eq([:start])
    expect(second[:calls]).to eq([:start])
    expect(first[:instance].commands_permitted?).to be(true)
  end

  it 'rejects foreign session identities and changing original hand pins' do
    participant(0)
    expect do
      session.report(identities.first.merge(session: 'successor'), ready: true, hands: ['10', nil])
    end.to raise_error(described_class::Invalid, /foreign/)
    expect do
      session.report(identities.first, ready: true, hands: ['11', nil])
    end.to raise_error(described_class::Invalid, /equipment/)
  end

  it 'rejects missing equipment and non-refuge startup without invoking callbacks' do
    [nil, [nil], ['', nil]].each do |hands|
      expect do
        described_class::Participant.new(session: session, identity: identities.first,
                                         snapshot: -> { { hands: hands } }, authority: -> { true },
                                         start: -> { raise 'must not start' }, return_to_refuge: ->(*) {}, stop: ->(*) {})
      end.to raise_error(described_class::Invalid, /refuge/)
    end
  end

  it 'rechecks original hands between readiness and activation' do
    first, second = participant(0), participant(1)
    first[:state][:hands] = ['99', nil]
    first[:instance].tick
    second[:instance].tick
    expect(first[:calls]).not_to include(:start)
    expect(first[:instance].status[:phase]).to eq(:returning)
    expect(second[:calls]).not_to include(:start)
  end

  it 'returns both members after one confirmed kill and proves both handoffs' do
    first, second = activated_pair
    first[:instance].select_target(target_id: '777')
    first[:instance].record_kill(target_id: '777', confirmed: true)
    expect(second[:instance].commands_permitted?).to be(false)
    second[:instance].tick
    expect(first[:calls].last).to eq([:return, 'kill_limit'])
    expect(second[:calls].last).to eq([:return, 'kill_limit'])
    finish(first)
    expect(session.status[:success]).to be(false)
    finish(second)
    expect(session.status).to include(complete: true, success: true, target_id: '777')
  end

  it 'does not count target disappearance or duplicate late kills as new work' do
    first, = activated_pair
    first[:instance].select_target(target_id: '777')
    expect do
      first[:instance].record_kill(target_id: '777', confirmed: false)
    end.to raise_error(described_class::Invalid, /evidence/)
    first[:instance].record_kill(target_id: '777', confirmed: true)
    first[:instance].record_kill(target_id: '777', confirmed: true)
    expect(session.status[:target_id]).to eq('777')
    expect(first[:calls].count { |call| call.is_a?(Array) && call.first == :return }).to eq(1)
  end

  it 'returns after an ordinary stop but never reports the work as a pass' do
    first, second = activated_pair
    first[:instance].request_stop
    second[:instance].tick
    finish(first)
    finish(second)
    expect(session.status).to include(complete: true, success: false, reason: 'ordinary_stop')
  end

  it 'does not certify a refuge handoff when the current safety/readiness check fails' do
    first, second = activated_pair
    first[:instance].select_target(target_id: '777')
    first[:instance].record_kill(target_id: '777', confirmed: true)
    second[:instance].tick
    first[:state][:ready] = false
    finish(first)
    finish(second)
    expect(first[:instance].status[:receipt]).to include(safe: false, reason: 'unsafe_handoff')
    expect(session.status).to include(complete: true, success: false)
  end

  it 'ends work at the work deadline while retaining local return authority' do
    first, second = activated_pair
    5.times do
      time[0] += 2
      first[:instance].tick
      second[:instance].tick
    end
    expect(first[:instance].status).to include(phase: :returning, reason: 'work_deadline')
    expect(first[:instance].commands_permitted?).to be(true)
    expect(second[:instance].commands_permitted?).to be(true)
  end

  it 'allows a ten-minute outing without extending the separate return allowance' do
    extended = described_class::Session.new(identities: identities, refuge_room: 1000,
                                            work_seconds: 600, return_seconds: 120,
                                            freshness_seconds: 2, clock: clock)
    first = participant(0, transport: extended)
    second = participant(1, transport: extended)
    first[:instance].tick
    second[:instance].tick
    299.times do
      time[0] += 2
      first[:instance].tick
      second[:instance].tick
    end
    expect(extended.status).to include(phase: :working, work_remaining: 2)
    time[0] += 2
    first[:instance].tick
    second[:instance].tick
    expect(first[:instance].status).to include(phase: :returning, reason: 'work_deadline',
                                               return_deadline: 820.0)
    expect(first[:instance].commands_permitted?).to be(true)
    expect(second[:instance].commands_permitted?).to be(true)
  end

  it 'rejects work beyond ten minutes and return beyond two minutes' do
    [[601, 120], [600, 121]].each do |work, recovery|
      expect do
        described_class::Session.new(identities: identities, refuge_room: 1000,
                                     work_seconds: work, return_seconds: recovery, clock: clock)
      end.to raise_error(described_class::Invalid, /budget/)
    end
  end

  it 'returns the survivor when the peer stops reporting without awaiting a remote model' do
    first, = activated_pair
    time[0] += 3
    first[:instance].tick
    expect(first[:instance].status).to include(phase: :returning, reason: 'peer_lost')
    expect(first[:instance].commands_permitted?).to be(true)
    finish(first)
    expect(session.status).to include(complete: false, success: false)
  end

  it 'uses a local return even when the shared-state adapter becomes unavailable' do
    first, = activated_pair
    allow(session).to receive(:report).and_raise(IOError)
    first[:instance].tick
    expect(first[:instance].status[:phase]).to eq(:returning)
    expect(first[:instance].commands_permitted?).to be(true)
  end

  it 'does not let a failed shared stop request abort local recovery' do
    first, = activated_pair
    allow(session).to receive(:request_return).and_raise(IOError)
    expect { first[:instance].request_stop }.not_to raise_error
    expect(first[:instance].status[:phase]).to eq(:returning)
    expect(first[:instance].commands_permitted?).to be(true)
  end

  it 'allows only observation checks from native child threads, without owner callbacks' do
    first, = activated_pair
    expect(Thread.new { first[:instance].commands_permitted? }.value).to be(true)
    expect(first[:calls]).to eq([:start])
  end

  it 'releases startup without starting work when a partner never arrives' do
    first = participant(0)
    time[0] += 5
    first[:instance].tick
    expect(first[:calls]).to eq([[:return, 'startup_timeout']])
    finish(first)
    expect(session.status[:success]).to be(false)
  end

  it 'does not return on explicit revocation and retains an unsafe receipt' do
    first, = activated_pair
    first[:authority][0] = false
    first[:instance].tick
    expect(first[:calls]).to eq([:start, [:stop, 'local_authority_lost']])
    expect(first[:instance].commands_permitted?).to be(false)
    expect(first[:instance].status[:receipt][:safe]).to be(false)
  end

  it 'denies further commands at return expiry instead of extending recovery' do
    first, = activated_pair
    first[:instance].request_stop
    time[0] += 15
    expect(first[:instance].commands_permitted?).to be(false)
    first[:instance].tick
    expect(first[:instance].status).to include(phase: :finished, reason: 'return_deadline')
    expect(first[:instance].status[:receipt][:safe]).to be(false)
  end

  it 'cannot create a new recovery allowance after the absolute outing deadline' do
    first, = activated_pair
    time[0] += 31
    first[:instance].tick
    expect(first[:calls]).not_to include([:return, 'work_deadline'])
    expect(first[:instance].status).to include(phase: :finished, reason: 'return_deadline')
  end

  it 'requires fresh equipment restoration and exact owner and child release' do
    [:fresh, :standing, :owner_released, :children_released].each do |field|
      isolated = described_class::Session.new(identities: identities, refuge_room: 1000,
                                              work_seconds: 10, return_seconds: 15, clock: clock)
      first = participant(0, transport: isolated)
      first[:instance].request_stop
      first[:state].update(owner: false, owner_released: true, children_released: true)
      first[:state][field] = false
      expect(first[:instance].finish![:receipt][:safe]).to be(false)
    end
  end

  it 'does not let an arbitrary thread trigger owner callbacks' do
    first, = activated_pair
    error = Thread.new do
      first[:instance].tick
    rescue ThreadError => raised
      raised
    end.value
    expect(error).to be_a(ThreadError)
    expect(first[:calls]).to eq([:start])
  end

  it 'does not activate an old barrier after one member stops reporting' do
    first, second = participant(0), participant(1)
    time[0] += 3
    first[:instance].tick
    second[:instance].tick
    expect(first[:calls]).not_to include(:start)
    expect(second[:calls]).not_to include(:start)
    expect(session.status).to include(reason: 'peer_lost', success: false)
  end

  it 'never extends delayed activation past its original startup deadline' do
    first, second = participant(0), participant(1)
    time[0] += 6
    first[:instance].tick
    second[:instance].tick
    expect(first[:calls]).not_to include(:start)
    expect(second[:calls]).not_to include(:start)
    expect(first[:instance].status[:reason]).to eq('startup_timeout')
  end

  it 'queues native observer kills without game callbacks and applies only on the owner tick' do
    first, second = activated_pair
    first[:instance].select_target(target_id: '777')
    queued = Thread.new do
      first[:instance].enqueue_kill(target_id: '777', session: identities.first[:session], confirmed: true)
    end.value
    expect(queued).to be(true)
    expect(first[:calls]).to eq([:start])
    expect(session.status[:target_id]).to be_nil
    first[:instance].tick
    second[:instance].tick
    expect(session.status[:target_id]).to eq('777')
    expect(first[:calls].last).to eq([:return, 'kill_limit'])
  end

  it 'ignores a different creatures death and refuses death without target assignment' do
    first, = activated_pair
    expect do
      first[:instance].record_kill(target_id: '777', confirmed: true)
    end.to raise_error(described_class::Invalid, /selected/)
    first[:instance].select_target(target_id: '777')
    first[:instance].enqueue_kill(target_id: '888', session: identities.first[:session], confirmed: true)
    first[:instance].tick
    expect(session.status).to include(phase: :working, target_id: nil)
  end

  it 'bounds observer notifications and rejects a prior session without callbacks' do
    first, = activated_pair
    first[:instance].select_target(target_id: '777')
    8.times do
      expect(first[:instance].enqueue_kill(target_id: '777', session: identities.first[:session], confirmed: true)).to be(true)
    end
    expect(first[:instance].enqueue_kill(target_id: '777', session: identities.first[:session], confirmed: true)).to be(false)
    expect(first[:instance].enqueue_kill(target_id: '777', session: 'old-session', confirmed: true)).to be(false)
    expect(first[:calls]).to eq([:start])
  end

  it 'latches local authority loss even if the local reader later returns true' do
    first, = activated_pair
    first[:authority][0] = false
    expect(first[:instance].commands_permitted?).to be(false)
    first[:authority][0] = true
    expect(first[:instance].commands_permitted?).to be(false)
    first[:instance].tick
    expect(first[:instance].status[:receipt][:safe]).to be(false)
  end

  context 'with the native Lich execution guard' do
    before do
      root = ENV['LICH_EXECUTION_GUARD_ROOT']
      skip 'set LICH_EXECUTION_GUARD_ROOT to exercise the separately installed native execution guard' unless root

      require File.join(root, 'lib/common/script_execution_guard')
    end

    it 'requires a new return guard after work denial, because the old guard remains latched' do
      first, second = activated_pair
      native = Lich::Common::ScriptExecutionGuard
      work_guard = native.new(->(_wire) { first[:instance].commands_permitted? })
      expect(work_guard.checkpoint!).to be(true)
      second[:instance].request_stop
      expect { work_guard.checkpoint! }.to raise_error(native::Interrupted)
      work_guard.close!
      first[:instance].tick
      expect(first[:instance].status[:phase]).to eq(:returning)
      expect { work_guard.checkpoint! }.to raise_error(native::Interrupted)
      return_guard = native.new(->(_wire) { first[:instance].commands_permitted? })
      expect(return_guard.checkpoint!).to be(true)
    end

    it 'cannot revive an explicitly revoked local grant with a fresh return guard' do
      first, = activated_pair
      native = Lich::Common::ScriptExecutionGuard
      first[:instance].request_stop
      first[:authority][0] = false
      old_guard = native.new(->(_wire) { first[:instance].commands_permitted? })
      expect { old_guard.checkpoint! }.to raise_error(native::Interrupted)
      first[:authority][0] = true
      new_guard = native.new(->(_wire) { first[:instance].commands_permitted? })
      expect { new_guard.checkpoint! }.to raise_error(native::Interrupted)
      first[:instance].tick
      expect(first[:instance].status[:receipt][:safe]).to be(false)
    end
  end
end
