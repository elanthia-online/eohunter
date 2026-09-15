# frozen_string_literal: true

require 'drb/drb'
require 'json'
require 'ostruct'
require 'timeout'
require_relative 'engine_helper'

# Real loopback DRb crosses an OS process boundary. Pipes only orchestrate the
# synthetic owner; no Lich installation, game connection or game command exists.
RSpec.describe 'Strict group movement across processes' do
  def receive_message(pipe)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
    buffer = +''
    loop do
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      raise 'synthetic owner response timeout' unless remaining.positive? && IO.select([pipe], nil, nil, remaining)

      chunk = pipe.read_nonblock(4096, exception: false)
      next if chunk == :wait_readable
      raise 'synthetic owner closed its response pipe' unless chunk

      buffer << chunk
      raise 'oversized synthetic owner response' if buffer.bytesize > 16_384
      return JSON.parse(buffer, symbolize_names: true) if buffer.end_with?("\n")
    end
  end

  def send_message(pipe, value)
    pipe.write(JSON.generate(value) + "\n")
    pipe.flush
  end

  def request(value)
    send_message(@to_child, value)
    response = receive_message(@from_child)
    raise response[:error] if response[:error]

    response
  end

  def child_owner(input, output)
    start = receive_message(input)
    identity = { game: 'TEST', character: 'Bob', incarnation: 'child', connection_generation: 1, run_id: 'child-run' }.freeze
    member = EO::Engine::Group::Member.new(DRbObject.new_with_uri(start.fetch(:uri)), name: 'Bob',
                                          strict_movement: true, identity_reader: -> { identity }, deadline: 0.5)
    orders = {}
    send_message(output, pid: Process.pid)
    loop do
      command = receive_message(input)
      result = case command.fetch(:operation)
               when 'register' then { registered: member.register }
               when 'take'
                 taken = member.orders(room: 1)
                 taken.each { |order| orders[order.step_id] = order }
                 { orders: taken.map(&:step_id) }
               when 'ack'
                 order = orders.fetch(command.fetch(:step_id))
                 { accepted: member.ack_movement(order, owner_tick: command.fetch(:tick), room: 1, room_epoch: 80) }
               when 'exit'
                 send_message(output, exited: true)
                 break
               else raise 'unknown fixture operation'
               end
      send_message(output, result)
    end
    exit! 0
  rescue StandardError => error
    send_message(output, error: "#{error.class}: #{error.message}") rescue nil
    exit! 1
  end

  def start_peer(expected:)
    skip 'requires OS fork' unless Process.respond_to?(:fork)

    @time = [100.0]
    identity = { game: 'TEST', character: 'Lead', incarnation: 'parent', connection_generation: 1, run_id: 'parent-run' }.freeze
    @hub = EO::Engine::Group::Hub.new(strict_movement: true, identity_reader: -> { identity }, monotonic: -> { @time.first })
    @hub.open_hunt(leader: 'Lead', expected: expected)
    @leader = EO::Engine::Group::Leader.new(@hub, name: 'Lead', strict_movement: true, identity_reader: -> { identity },
                                          movement_idle: ->(_world) { true }, monotonic: -> { @time.first })
    @world = OpenStruct.new(room: OpenStruct.new(id: 1, count: 10, players: expected.map { |name| OpenStruct.new(noun: name) }),
                            me: OpenStruct.new(in_rt?: false, in_cast_rt?: false, dead?: false, muckled?: false), group_nouns: expected)
    @leader.complete_owner_tick(@world, 1, state: :running)
    child_input, @to_child = IO.pipe
    @from_child, child_output = IO.pipe
    @pid = fork do
      @to_child.close
      @from_child.close
      child_owner(child_input, child_output)
    end
    child_input.close
    child_output.close
    @server = DRb::DRbServer.new('druby://127.0.0.1:0', @hub)
    send_message(@to_child, uri: @server.uri)
    expect(receive_message(@from_child).fetch(:pid)).to eq(@pid)
    expect(@pid).not_to eq(Process.pid)
  end

  def reap_child
    return unless @pid

    status = Timeout.timeout(3) { Process.waitpid2(@pid).last }
    @pid = nil
    status
  end

  after do
    @to_child&.close unless @to_child&.closed?
    @from_child&.close unless @from_child&.closed?
    if @pid
      begin
        Process.kill('TERM', @pid)
        reap_child
      rescue Errno::ESRCH, Errno::ECHILD
        @pid = nil
      rescue Timeout::Error
        Process.kill('KILL', @pid)
        reap_child
      end
    end
    Timeout.timeout(3) { @server&.stop_service }
  end

  it 'keeps the full explicit roster even though the reporting process is online' do
    start_peer(expected: %w[Bob Ann])
    expect(request(operation: 'register')).to eq(registered: true)
    expect(@hub.members).to eq(['Bob'])
    expect(@leader.prepare_movement(1, room_epoch: 10)).to be_nil
    expect(@leader.movement_ready?(@world)).to be false
    expect(request(operation: 'take')).to eq(orders: [])
    expect(request(operation: 'exit')).to eq(exited: true)
    expect(reap_child.success?).to be true
    expect(@leader.consume_movement!(@world)).to be false
  end

  it 'round-trips exact preparation, rejects an old episode and loses quorum when the peer exits' do
    start_peer(expected: ['Bob'])
    expect(@leader.prepare_movement(1, room_epoch: 10)).to be_nil
    expect(request(operation: 'register')).to eq(registered: true)

    first = @leader.prepare_movement(1, room_epoch: 10)
    expect(request(operation: 'take')).to eq(orders: [first.step_id])
    expect(request(operation: 'ack', step_id: first.step_id, tick: 1)).to eq(accepted: true)
    expect(@leader.movement_ready?(@world)).to be true
    expect(@leader.consume_movement!(@world)).to be true
    expect(@leader.consume_movement!(@world)).to be false

    second = @leader.prepare_movement(1, room_epoch: 10)
    expect(request(operation: 'take')).to eq(orders: [second.step_id])
    expect(request(operation: 'ack', step_id: first.step_id, tick: 1)).to eq(accepted: false)
    expect(@leader.movement_ready?(@world)).to be false
    expect(request(operation: 'ack', step_id: second.step_id, tick: 2)).to eq(accepted: true)
    expect(request(operation: 'ack', step_id: second.step_id, tick: 2)).to eq(accepted: true)
    expect(@leader.movement_ready?(@world)).to be true

    expect(request(operation: 'exit')).to eq(exited: true)
    expect(reap_child.success?).to be true
    @time[0] += 1.1
    @leader.complete_owner_tick(@world, 2, state: :running)
    @hub.heartbeat!(room: 1)
    expect(@hub.members).to eq(['Bob'])
    expect(@leader.consume_movement!(@world)).to be false
  end
end
