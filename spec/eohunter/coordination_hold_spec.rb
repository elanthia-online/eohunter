# frozen_string_literal: true

require_relative 'engine_helper'
require_relative 'support/fake_world'

RSpec.describe EO::Engine::Coordination::HoldPilot do
  before(:context) do
    root = ENV['LICH_COORDINATION_ROOT']
    skip 'set LICH_COORDINATION_ROOT to the coordinated-operations checkout' if root.nil? || root.empty?
    require File.join(File.expand_path(root), 'lib/internal_api/coordination')
  end

  let(:world) { FakeWorld.new }
  let(:engine) { EO::Engine::Engine.new(world: world, behaviors: [], interval: 0) }
  let(:now) { [100.0] }
  let(:identity) do
    { game: 'GS3', character: 'Bob', incarnation: 'session-one',
      connection_generation: 0, run_id: 'pilot-one' }
  end
  let(:peer) { identity.merge(character: 'Alice', incarnation: 'peer-one', run_id: 'peer-pilot') }
  let(:session) { double('session', identity: identity) }
  let(:eligible) { ->(_world) { true } }
  let(:pilot) do
    described_class.new(engine: engine, session: session, peer: peer, safe_room: 1,
                        control_token: 'dedicated-control-test-token', eligible: eligible, clock: -> { now.first })
  end
  let(:descriptor) { pilot.start }
  let(:client) do
    Lich::InternalAPI::Coordination::Operations::Client.new(
      descriptor: descriptor, control_token: 'dedicated-control-test-token', local_identity: peer
    )
  end

  def submit(id = 'one', operation: 'hold', hold_id: nil)
    arguments = hold_id ? { 'hold_id' => hold_id } : {}
    client.submit(request_id: id, operation: operation, arguments: arguments).fetch(:payload)
  end

  def result(id = 'one') = client.result(request_id: id).fetch(:payload)

  def apply_hold(id = 'one')
    submit(id)
    engine.tick # native mailbox admission on a completed owner turn
    engine.tick # local application and completed-turn confirmation
    result(id)
  end

  def apply_release(id = 'release', hold_id: 'one')
    submit(id, operation: 'release', hold_id: hold_id)
    engine.tick
    engine.tick
    result(id)
  end

  after do
    pilot.close
    expect(world.sent_commands).to be_empty
    EO::Engine::Events.reset!
  end

  it 'is inert before start, even if constructed outside its declared room' do
    pilot
    world.id = 99
    engine.tick
    expect(engine.stopping?).to be false
  end

  it 'takes only on a completed owner tick, then confirms the local hold on the next' do
    expect(submit).to include(state: 'pending', owner_tick: nil)
    engine.tick
    expect(result).to include(state: 'running', owner_tick: 1, cleanup: 'pending')
    expect(engine.paused?).to be false

    engine.tick
    expect(result).to include(state: 'settled', outcome: 'succeeded', owner_tick: 2,
                              cleanup: 'pending', result: { engine_state: 'held' })
    expect(engine.paused?).to be true
  end

  it 'releases only the exact settled hold and completes both receipts' do
    apply_hold
    release = apply_release
    expect(release).to include(state: 'settled', outcome: 'succeeded', cleanup: 'complete',
                               result: { engine_state: 'running' })
    expect(result).to include(outcome: 'succeeded', cleanup: 'complete')
    expect(engine.paused?).to be false
  end

  it 'keeps a manual pause made during the remote hold' do
    apply_hold
    engine.pause!
    expect(apply_release).to include(result: { engine_state: 'held' })
    expect(engine.paused?).to be true
    engine.resume!
    expect(engine.paused?).to be false
  end

  it 'does not let manual resume clear the peer hold' do
    engine.pause!
    apply_hold
    engine.resume!
    expect(engine.paused?).to be true
  end

  it 'stops and completes cleanup when the fixed hold lease expires' do
    apply_hold
    now[0] += described_class::HOLD_SECONDS
    engine.tick
    expect(engine.stop_reason).to eq(:hold_lease_expired)
    expect(result).to include(outcome: 'succeeded', cleanup: 'complete')
    expect(engine.paused?).to be false
  end

  it 'denies a second hold and a release for another hold without changing local state' do
    apply_hold
    submit('two')
    engine.tick
    engine.tick
    expect(result('two')).to include(state: 'settled', outcome: 'failed', reason: 'already_held')
    submit('release', operation: 'release', hold_id: 'not-our-hold')
    engine.tick
    engine.tick
    expect(result('release')).to include(state: 'settled', outcome: 'failed', reason: 'hold_mismatch')
    expect(engine.paused?).to be true
  end

  it 'serializes queued releases so only one can release a hold' do
    apply_hold
    submit('release-a', operation: 'release', hold_id: 'one')
    submit('release-b', operation: 'release', hold_id: 'one')
    4.times { engine.tick }
    expect(result('release-a')).to include(outcome: 'succeeded')
    expect(result('release-b')).to include(outcome: 'failed', reason: 'hold_mismatch')
    expect(engine.stopping?).to be false
  end

  it 'fails closed on reconnect and does not revive old work' do
    apply_hold
    allow(session).to receive(:identity).and_return(identity.merge(connection_generation: 1))
    engine.tick
    expect(engine.stop_reason).to eq(:authority_or_safety_lost)
    expect(client.result(request_id: 'one')).to eq(ok: false, error: 'identity_mismatch')
    expect(client.submit(request_id: 'new', operation: 'hold')).to include(ok: false)
  end

  it 'stops on safety loss without resuming an existing manual hold' do
    apply_hold
    engine.pause!
    world.id = 2
    engine.tick
    expect(engine.stop_reason).to eq(:authority_or_safety_lost)
    expect(engine.paused?).to be true
    expect(result[:cleanup]).to eq('complete')
  end

  [nil, false].each do |unknown|
    it "requires positive local eligibility, not #{unknown.inspect}" do
      allow(eligible).to receive(:call).and_return(unknown)
      submit
      engine.tick
      expect(engine.stopping?).to be true
      expect(result).to include(state: 'revoked', outcome: 'cancelled')
    end
  end

  it 'fails closed on a local reader exception' do
    allow(eligible).to receive(:call).and_raise('disconnected')
    submit
    engine.tick
    expect(engine.stop_reason).to eq(:owner_check_failed)
    expect(result).to include(state: 'revoked', outcome: 'cancelled')
  end

  it 'marks revocation separately from owner cleanup' do
    apply_hold
    pilot.revoke
    expect(result[:cleanup]).to eq('pending')
    expect(engine.stopping?).to be false
    engine.tick
    expect(engine.stopping?).to be true
    expect(result[:cleanup]).to eq('complete')
  end

  it 'closes the listener only after owner cleanup' do
    apply_hold
    pilot.close
    expect(engine.stopping?).to be true
    expect(engine.paused?).to be false
    expect(client.result(request_id: 'one')[:ok]).to be false
  end

  it 'reports unknown when a local effect occurs but the owner turn aborts before confirmation' do
    submit
    engine.tick
    engine.on_tick { engine.stop!(:local_stop) }
    engine.tick
    expect(result).to include(state: 'running', cleanup: 'pending')
    engine.tick
    expect(result).to include(state: 'settled', outcome: 'unknown', cleanup: 'complete')
  end

  it 'refuses to attach to an engine with hunting behaviors' do
    active = EO::Engine::Engine.new(world: world, behaviors: [EO::Engine::Behavior.new], interval: 0)
    expect do
      described_class.new(engine: active, session: session, peer: peer, control_token: 'token',
                          safe_room: 1, eligible: eligible)
    end.to raise_error(ArgumentError, /empty engine/)
  end

  it 'does not execute owner teardown from a transport thread' do
    descriptor
    error = Thread.new do
      pilot.close
    rescue ThreadError => e
      e
    end.value
    expect(error).to be_a(ThreadError)
    expect(engine.stopping?).to be false
  end

  it 'applies and reconciles through native operations across two real processes' do
    skip 'requires fork' unless Process.respond_to?(:fork)
    client
    parent_read, child_write = IO.pipe
    child_read, parent_write = IO.pipe
    pid = fork do
      parent_read.close
      parent_write.close
      begin
        raise 'admission' unless submit[:state] == 'pending'
        child_write.puts('pending')
        2.times { raise 'owner handshake' unless child_read.gets&.strip == 'tick' }
        raise 'hold confirmation' unless result[:outcome] == 'succeeded'
        raise 'release admission' unless submit('release', operation: 'release', hold_id: 'one')[:state] == 'pending'
        child_write.puts('release_pending')
        2.times { raise 'owner handshake' unless child_read.gets&.strip == 'tick' }
        raise 'release confirmation' unless result('release').dig(:result, :engine_state) == 'running'
        child_write.puts('passed')
        exit! 0
      rescue StandardError => e
        child_write.puts("failed: #{e.message}")
        exit! 1
      end
    end
    child_read.close
    child_write.close
    expect(parent_read.gets&.strip).to eq('pending')
    2.times do
      engine.tick
      parent_write.puts('tick')
    end
    expect(parent_read.gets&.strip).to eq('release_pending')
    2.times do
      engine.tick
      parent_write.puts('tick')
    end
    expect(parent_read.gets&.strip).to eq('passed')
    expect(Process.wait2(pid).last.success?).to be true
    pid = nil
  ensure
    [parent_read, parent_write, child_read, child_write].compact.each { |io| io.close unless io.closed? }
    if pid
      Process.kill('TERM', pid) rescue Errno::ESRCH
      Process.wait(pid) rescue Errno::ECHILD
    end
  end
end
