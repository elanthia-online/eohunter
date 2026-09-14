# Coordination library

`libeocoordination` supplies opt-in communication between independent Lich
processes without moving those characters into one Ruby process. Load it only
from a script that needs coordination:

```ruby
Script.loadlib('libeocoordination')
EO::Coordination.require_version('0.1.0')
```

Loading the library is inert. It does not open a listener, publish discovery,
start another script, or send a game command. A consumer explicitly creates and
owns every session, discovery adapter, and operation grant, and closes them in
its own lifecycle cleanup.

## Architectural boundary

Lich core remains responsible for parsing, native script lifecycle, and
execution guards. Its existing synchronous `SocketReadHook` and
`DownstreamHook` seams are sufficient for an external library to bracket a
completed parser dispatch: the former withdraws an older publication before
new input is queued, and the latter samples already-parsed native facts. The
projection registers at high downstream priority so presentation hooks cannot
transform or suppress the chunk before that passive sample is captured. It
returns the supplied chunk unchanged.

This library owns the optional coordination mechanics:

- bounded authenticated loopback transport;
- immutable read-only observation publication and consumption;
- discovery metadata over the existing ActiveSessions registry;
- receiver-issued operation tickets, duplicate suppression, and receipts;
- an owner-thread handoff that never invokes callbacks or game commands from a
  transport worker.

`EO::Coordination::ParserProjection` composes those two native hooks. It is
explicitly installed and owned by its consumer:

```ruby
projection = EO::Coordination::ParserProjection.new
projection.install!
sample = projection.call # `read` is the equivalent explicit-reader interface
# ...later, from lifecycle cleanup...
projection.close
```

It publishes only when the parser has caught up to the newest socket input.
Queued, currently parsing, disconnected, replaced-worker, or buffered input is
unknown (`nil`). The hook callbacks are passive: they never send commands or
start work. The projection contains native room, hand, roundtime, posture, and
health facts together with one connection ID, input sequence, and monotonic
receipt time. Consumers still own every readiness and movement decision.

The token and grant checks prevent accidental cross-session delivery, stale
work, and duplicate application among cooperating local processes. They are a
safety and idempotency protocol, not a sandbox against hostile code running as
the same operating-system user.

## Read-only observations

The owner constructs an explicitly enabled `EO::Coordination::Session`, starts
its endpoint, and publishes only after its controller has completed a coherent
owner tick. Consumers pin the complete session identity and apply conservative
age checks:

```ruby
session = EO::Coordination::Session.new(
  game: 'GS3', character: Char.name, run_id: run_id,
  read_token: read_token, enabled: true
)
session.start

client = EO::Coordination::Client.new(
  descriptor: session.descriptor,
  read_token: read_token,
  max_age: 1.0
)
snapshot = client.snapshot
```

Unknown, stale, mixed-generation, or non-advancing facts never become ready.
The library validates source bindings and uses the parser-bracketing projection
above when a consumer needs one coherent local cut.

`EO::Coordination::Discovery` publishes only the token-free descriptor through
`Lich::InternalAPI::ActiveSessions`. Credentials are exchanged separately.
Discovery is a hint: every resolution re-queries the registry, authenticates
the endpoint, and checks its complete identity.

## Controlled operations

`EO::Coordination::Operations::Grant` admits only operations named in an
explicit per-consumer schema. A peer first obtains a short-lived receiver ticket
and then submits the same request. Reusing a request ID is an idempotent retry;
changing its arguments is rejected.

Transport workers only validate and reserve requests. The owning script takes
work with `next_request(owner_tick:)`, performs its own local policy checks, and
settles the receipt after the action. Logical outcome and cleanup completion
remain distinct. There is no generic evaluation, arbitrary method invocation,
raw command forwarding, or automatic child-script launch in this library.

## Verification

The library specs run without a Lich checkout. Set `LICH_ROOT` to add the native
ActiveSessions discovery integration cases:

```sh
bundle exec rspec spec/eocoordination
LICH_ROOT=/path/to/lich-5 bundle exec rspec spec/eocoordination
```
