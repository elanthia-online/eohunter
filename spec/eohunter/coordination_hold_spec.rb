# frozen_string_literal: true

require_relative 'engine_helper'
require_relative 'support/fake_world'

RSpec.describe EO::Engine::Coordination::HoldPilot do
  before(:context) do
    root = ENV['LICH_COORDINATION_ROOT']
    skip 'set LICH_COORDINATION_ROOT to the paired native transport checkout' if root.nil? || root.empty?
    require File.join(File.expand_path(root), 'lib/internal_api/coordination')
  end

  let(:world) { FakeWorld.new }
  let(:engine) { EO::Engine::Engine.new(world: world, behaviors: [], interval: 0) }
  let(:now) { [100.0] }
  let(:identity) { { game: 'GS3', character: 'Bob', incarnation: 'session-one', connection_generation: 0, run_id: 'pilot-one' } }
  let(:peer) { identity.merge(character: 'Alice', incarnation: 'peer-one', run_id: 'peer-pilot') }
  let(:session) { double('session', identity: identity) }
  let(:eligible) { ->(_world) { true } }
  let(:pilot) do
    described_class.new(engine: engine, session: session, peer: peer, safe_room: 1,
                        control_token: 'dedicated-control-test-token', eligible: eligible, clock: -> { now.first })
  end
  let(:descriptor) { pilot.start }
  let(:transport) do
    Lich::InternalAPI::ActiveSessions::Client.new(host: descriptor[:host], port: descriptor[:port],
                                                  auth_token: 'dedicated-control-test-token', timeout: 0.25,
                                                  max_frame_bytes: 16_384)
  end

  def request(command, id = 'one', **extra)
    transport.request(command, { protocol_version: 1, identity: identity, peer: peer, request_id: id }.merge(extra))
  end

  def reserve(id = 'one', operation: 'hold', hold_id: nil)
    request('ticket', id, operation: operation, hold_id: hold_id).fetch(:payload)
  end

  def submit(id = 'one', operation: 'hold', hold_id: nil)
    token = reserve(id, operation: operation, hold_id: hold_id).fetch(:ticket)
    request('submit', id, ticket: token).fetch(:payload)
  end

  def result(id = 'one') = request('result', id).fetch(:payload)

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

  it 'only applies a pending request on the owner and confirms after the completed tick' do
    expect(submit).to include(state: 'pending', owner_tick: nil)
    expect(engine.paused?).to be false
    during = nil
    engine.on_tick { during = result }
    engine.tick
    expect(during).to include(state: 'applying', owner_tick: nil)
    expect(result).to include(state: 'applied', engine_state: 'held', owner_tick: 1, cleanup: 'pending')
    expect(engine.paused?).to be true
  end

  it 'releases only the exact applied hold after a second completed tick' do
    submit
    engine.tick
    expect(submit('release-one', operation: 'release', hold_id: 'one')[:state]).to eq('pending')
    expect(engine.paused?).to be true
    engine.tick
    expect(result('release-one')).to include(state: 'applied', engine_state: 'running', owner_tick: 2)
    expect(result).to include(cleanup: 'complete', released_by: 'release-one', cleanup_owner_tick: 2)
    expect(engine.paused?).to be false
  end

  it 'keeps a manual pause made during the remote hold' do
    submit
    engine.tick
    engine.pause!
    submit('release', operation: 'release', hold_id: 'one')
    engine.tick
    expect(result('release')).to include(state: 'applied', engine_state: 'held')
    expect(engine.paused?).to be true
    engine.resume!
    expect(engine.paused?).to be false
  end

  it 'does not let manual resume clear the peer hold' do
    engine.pause!
    submit
    engine.tick
    engine.resume!
    expect(engine.paused?).to be true
  end

  it 'replays a duplicate receipt without applying or renewing the hold' do
    token = reserve.fetch(:ticket)
    request('submit', ticket: token)
    engine.tick
    first = result
    now[0] += 10
    expect(request('submit', ticket: token)[:payload]).to eq(first.merge(owner_age: 10.0))
    now[0] += 5
    engine.tick
    expect(engine.stop_reason).to eq(:hold_lease_expired)
    expect(result).to include(state: 'applied', cleanup: 'complete', cleanup_reason: 'hold_lease_expired')
  end

  it 'rejects ID reuse with different arguments and never refreshes the issuance deadline' do
    first = reserve
    now[0] += 4
    expect(reserve).to include(ticket: first[:ticket], remaining_seconds: 1.0)
    expect(request('ticket', operation: 'release', hold_id: 'different')).to include(ok: false, error: 'request_conflict')
    now[0] += 1
    expect(request('submit', ticket: first[:ticket])[:payload][:state]).to eq('expired')
    engine.tick
    expect(engine.paused?).to be false
  end

  it 'expires an admitted request if the owner did not run before the deadline' do
    submit
    now[0] += 5
    engine.tick
    expect(result).to include(state: 'expired', reason: 'ticket_expired')
    expect(engine.paused?).to be false
  end

  it 'retains all tombstones and refuses capacity rather than forgetting request IDs' do
    described_class::CAPACITY.times { |i| reserve("request-#{i}") }
    now[0] += 6
    expect(request('ticket', 'overflow', operation: 'hold', hold_id: nil)).to include(ok: false, error: 'grant_capacity')
    expect(reserve('request-0')[:state]).to eq('expired')
  end

  it 'refuses another hold and an unrelated release' do
    submit
    engine.tick
    submit('two')
    engine.tick
    expect(result('two')).to include(state: 'failed', reason: 'already_held')
    submit('release', operation: 'release', hold_id: 'not-our-hold')
    engine.tick
    expect(result('release')).to include(state: 'failed', reason: 'hold_mismatch')
    expect(engine.paused?).to be true
  end

  it 'serializes queued releases, so only one can release a hold' do
    submit
    engine.tick
    submit('release-a', operation: 'release', hold_id: 'one')
    submit('release-b', operation: 'release', hold_id: 'one')
    engine.tick
    engine.tick
    expect(result('release-a')[:state]).to eq('applied')
    expect(result('release-b')).to include(state: 'failed', reason: 'hold_mismatch')
    expect(engine.stopping?).to be false
  end

  it 'does not collapse an admitted hold and release into the same turn' do
    submit
    submit('release', operation: 'release', hold_id: 'one')
    engine.tick
    expect(result[:state]).to eq('applied')
    expect(result('release')[:state]).to eq('pending')
    expect(engine.paused?).to be true
    engine.tick
    expect(engine.paused?).to be false
  end

  it 'fails closed on a reconnect and does not revive old requests' do
    submit
    engine.tick
    allow(session).to receive(:identity).and_return(identity.merge(connection_generation: 1))
    engine.tick
    expect(engine.stop_reason).to eq(:authority_or_safety_lost)
    expect(result[:cleanup]).to eq('complete')
    expect(request('ticket', 'new', operation: 'hold', hold_id: nil)[:error]).to eq('grant_closed')
  end

  it 'rejects a wrong peer, target incarnation, protocol, operation and extra arguments' do
    expect(request('result', peer: peer.merge(run_id: 'old'))[:error]).to eq('identity_mismatch')
    expect(request('result', identity: identity.merge(incarnation: 'old'))[:error]).to eq('identity_mismatch')
    expect(request('result', protocol_version: 2)[:error]).to eq('protocol_mismatch')
    expect(request('ticket', operation: 'go2', hold_id: nil)[:error]).to eq('unsupported_operation')
    expect(request('ticket', operation: 'hold', hold_id: nil, command: 'attack')[:error]).to eq('invalid_request')
    expect(request('eval')[:error]).to eq('unsupported_command')
  end

  it 'rejects a read token and an incorrect ticket' do
    port = descriptor[:port]
    reader = Lich::InternalAPI::ActiveSessions::Client.new(host: '127.0.0.1', port: port,
                                                           auth_token: 'read-only-token', timeout: 0.25,
                                                           max_frame_bytes: 16_384)
    expect(reader.request('ticket')[:ok]).to be false
    reserve
    expect(request('submit', ticket: 'wrong')[:error]).to eq('invalid_ticket')
    expect(engine.paused?).to be false
  end

  it 'stops on safety loss without resuming an existing manual hold' do
    submit
    engine.tick
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
      expect(result[:state]).to eq('failed')
      expect(engine.stopping?).to be true
    end
  end

  it 'fails closed on a reader exception' do
    allow(eligible).to receive(:call).and_raise('disconnected')
    submit
    engine.tick
    expect(engine.stop_reason).to eq(:owner_check_failed)
    expect(result[:state]).to eq('failed')
  end

  it 'keeps a stopped owner observation aging even when receipts are read' do
    submit
    engine.tick
    now[0] += 2
    expect(result).to include(owner_tick: 1, owner_age: 2.0)
    now[0] += 1
    expect(result).to include(owner_tick: 1, owner_age: 3.0)
  end

  it 'rejects a queued hold when a creature arrives in the declared safe room' do
    submit
    world.npcs << FakeWorld::FakeNpc.new('1', 'rat', 'a rat', nil)
    engine.tick
    expect(result[:state]).to eq('failed')
    expect(engine.stop_reason).to eq(:authority_or_safety_lost)
  end

  %i[dead? in_rt? in_cast_rt?].each do |check|
    it "requires known false for #{check}" do
      submit
      world.me[check] = nil
      engine.tick
      expect(result[:state]).to eq('failed')
      expect(engine.stopping?).to be true
    end
  end

  it 'marks revocation separately from owner cleanup' do
    submit
    engine.tick
    pilot.revoke
    expect(result[:cleanup]).to eq('pending')
    expect(engine.stopping?).to be false
    engine.tick
    expect(engine.stopping?).to be true
    expect(result[:cleanup]).to eq('complete')
  end

  it 'closes the listener and stops on explicit owner teardown' do
    submit
    engine.tick
    pilot.close
    expect(engine.stopping?).to be true
    expect(engine.paused?).to be false
    expect(request('result')[:ok]).to be false
  end

  it 'does not confirm an action when another start callback aborts the turn' do
    submit
    engine.on_tick { engine.stop!(:local_stop) }
    engine.tick
    expect(result[:state]).to eq('applying')
    engine.tick
    expect(result).to include(state: 'failed', cleanup: 'complete')
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

  it 'applies and reconciles across two real processes with no game commands' do
    skip 'requires fork' unless Process.respond_to?(:fork)
    transport
    parent_read, child_write = IO.pipe
    child_read, parent_write = IO.pipe
    pid = fork do
      parent_read.close
      parent_write.close
      begin
        raise 'admission' unless submit[:state] == 'pending'
        child_write.puts('pending')
        raise 'owner handshake' unless child_read.gets&.strip == 'tick'
        raise 'hold confirmation' unless result[:state] == 'applied'
        raise 'release admission' unless submit('release', operation: 'release', hold_id: 'one')[:state] == 'pending'
        child_write.puts('release_pending')
        raise 'owner handshake' unless child_read.gets&.strip == 'tick'
        raise 'release confirmation' unless result('release')[:engine_state] == 'running'
        child_write.puts('passed')
        exit! 0
      rescue StandardError => e
        child_write.puts("failed: #{e.message}")
        exit! 1
      end
    end
    child_read.close
    child_write.close
    expect(IO.select([parent_read], nil, nil, 3)).not_to be_nil
    expect(parent_read.gets&.strip).to eq('pending')
    expect(engine.paused?).to be false
    engine.tick
    parent_write.puts('tick')
    expect(IO.select([parent_read], nil, nil, 3)).not_to be_nil
    expect(parent_read.gets&.strip).to eq('release_pending')
    expect(engine.paused?).to be true
    engine.tick
    parent_write.puts('tick')
    expect(IO.select([parent_read], nil, nil, 3)).not_to be_nil
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
