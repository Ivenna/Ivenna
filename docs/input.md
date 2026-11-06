# Model input and response scope

Ivenna's YAML user messages contain retained records or a current request. Records preserve events, recalled communication, and handovers in working history. The request adds current state and, for summarization, instructions. These YAML messages sit alongside retained model output and tool replies; the [architecture guide](architecture.md#records-context-and-current-requests) describes that complete history and its adapter-owned continuation data.

The core's [Input](../packages/agent/src/input.zig) module defines the record and request structures and renders them as YAML. Shared [communication](../packages/agent_contracts/src/communication.zig) and [handover](../packages/agent_contracts/src/handover.zig) types supply their message and summary payloads. The [system prompt](../packages/agent/src/system.md) explains their meaning to the model.

## Retained records

A `Record` combines an event group with a list of context items:

| Field | Type | Meaning |
| --- | --- | --- |
| `session_id` | `u64` | Session receiving the record |
| `events` | `Event[]` | Events admitted together, in queue order; defaults to an empty array |
| `context` | `ContextItem[]` | Supporting material retained with the record; defaults to an empty array |

The events and context fields can coexist. Each activation records its selected group once in `events`; startup recollection and compaction create context-only records with `events: []`. Startup recollection records the latest core handover and recent received and sent messages. Compaction replaces earlier history with a handover.

Session identifiers are scoped to one kernel process. Forked history keeps the original records and their session identifiers. The current request identifies the session performing the inference.

Each input keeps its own `from` IDs, text, and observation time within the admitted group. See [activation admission](architecture.md#activation-admission) for how the runtime selects a group and handles later arrivals.

## Events and context items

`Event` contains one of these branches:

| Branch | Payload | Meaning |
| --- | --- | --- |
| `input` | `IncomingMessage` | Observation of what correspondents said |
| `assignment` | `Assignment` | Initial work for a fork |
| `report` | `Report` | A child activation's final text |

`ContextItem` contains one of these branches:

| Branch | Payload | Meaning |
| --- | --- | --- |
| `received` | `IncomingMessage` | Previously received observation |
| `sent` | `SentMessage` | Message Ivenna previously sent, with its recipients |
| `handover` | `Handover` | Retained understanding for continuation |

Startup recollection supplies received and sent messages as context items. Recalled and generated summaries are handover items.

A `Handover` contains `summary: Text`, the retained understanding needed to continue work.

`Event`, `ContextItem`, and `Response` are tagged unions. Their YAML representation is a mapping with one branch name and that branch's payload. `Text` denotes a free-form string.

For example, two arrivals can enter the core as one event group:

```yaml
session_id: 1
events:
  - input:
      from: [operator]
      text: Keep practice sessions to 20 minutes.
      observed_at_unix_ms: 1793966400000
  - input:
      from: [operator]
      text: Include ten minutes of listening.
      observed_at_unix_ms: 1793966401000
context: []
```

Compaction can replace earlier history with a context-only handover record:

```yaml
session_id: 1
events: []
context:
  - handover:
      summary: Keep each practice session to 20 minutes, including ten minutes of listening.
```

## Incoming messages

The shared `Communication.IncomingMessage` represents an observation of who said what. It does not imply that the words were addressed specifically to Ivenna or require a response. A new arrival appears as an `input` event; recalled communication uses the `received` context branch.

`IncomingMessage` contains:

| Field | Type | Meaning |
| --- | --- | --- |
| `from` | `Text[]` | IDs of participants this message came from |
| `text` | `Text` | Complete message text |
| `observed_at_unix_ms` | `i64` | Runtime observation time in Unix milliseconds |

`from` contains readable [correspondent IDs](communication.md#correspondents-and-ids) accepted by `send_message`. The timestamp records when the runtime observed the message, including during recollection.

The [whole-request budget](architecture.md#bounded-model-context) counts the complete message. The runtime admits whole observations; a single input that cannot fit after compaction fails with `ContextBudgetExhausted`.

## Received and sent history

`Inbox.recent` returns shared `Communication.HistoryItem` values with a `received: IncomingMessage` or `sent: SentMessage` branch. The kernel incorporates each item into the matching `ContextItem` branch. These records distinguish what Ivenna observed from what it previously said to others.

`SentMessage` contains:

| Field | Type | Meaning |
| --- | --- | --- |
| `recipients` | `Text[]` | IDs of people or programs Ivenna sent the message to |
| `text` | `Text` | Complete sent message text |
| `observed_at_unix_ms` | `i64` | Runtime observation time in Unix milliseconds |

The timestamp records when the runtime observed the stored message. Observation timestamps in received and sent history do not establish when a message was sent or delivered.

For example, startup recollection can supply both sides of earlier communication:

```yaml
session_id: 1
events: []
context:
  - received:
      from: [alice]
      text: Please revise the practice schedule.
      observed_at_unix_ms: 1793966400000
  - sent:
      recipients: [alice]
      text: The revised schedule is ready for review.
      observed_at_unix_ms: 1793966401000
```

Outgoing messages use [the communication tool](communication.md#sending-a-message) with explicitly chosen recipient IDs. An activation's final text is a core result or a report to its parent.

## Assignments and reports

An `Assignment` contains:

| Field | Meaning |
| --- | --- |
| `task` | Work for the receiving session to continue |
| `from_session` | Direct parent that created the fork |

An assignment describes the caller activation's whole work, and the child inherits the caller's retained history. See [fork ownership](architecture.md#forks-and-work-ownership) for publication, queueing, and context lifetimes.

The new session receives its assignment as a one-event group:

```yaml
session_id: 2
events:
  - assignment:
      task: Update the French practice plan.
      from_session: 1
context: []
```

A `Report` contains `from_session: u64` and `text: Text`, which may be empty. It carries a branch activation's combined result for its direct parent. The identifiers in fork results and reports let the parent associate results with the child that produced them.

## Current requests

Every inference appends one temporary `Request` after retained history:

| Field | Type | Meaning |
| --- | --- | --- |
| `session_id` | `u64` | Session performing this inference |
| `state` | `State` | Current session, execution counts, and response destination |
| `instructions` | `Text` or null | Summary instructions; null for ordinary execution |

Each inference receives the retained records and model/tool exchanges followed by this fresh state snapshot. Constructing the request does not add another event record. Request state and summary instructions are discarded after inference; they are not appended to history or inherited by forks.

### State and response destinations

`State` contains `session`, `runtime`, and `response`:

| Field | Meaning |
| --- | --- |
| `session.role` | `core` or `branch` |
| `session.parent_generation` | Parent context generation copied when the fork was published, or null |
| `session.parent_session_id` | Session that created this fork, or null |
| `session.active_children` | Direct child contexts retained under this session |
| `runtime.active_sessions` | Retained contexts, including the core |
| `runtime.running_sessions` | Sessions currently executing work |
| `runtime.queued_inputs` | Deliveries waiting in queues |

`Response` contains one destination:

| Branch | Payload | Meaning |
| --- | --- | --- |
| `report` | `session_id: u64` | Return the branch result to its direct parent |
| `internal` | Empty object | Keep the core activation's result internal |
| `summary` | Empty object | Produce a handover for the summary operation |

These destinations identify how an ordinary activation's final text or a summary result is used. Outgoing communication uses the independent `send_message` tool and its explicit recipients.

For example, an ordinary core request can be:

```yaml
session_id: 1
state:
  session:
    role: core
    parent_generation: null
    parent_session_id: null
    active_children: 1
  runtime:
    active_sessions: 2
    running_sessions: 2
    queued_inputs: 0
  response:
    internal: {}
instructions: null
```

In ordinary execution, a response without tool calls completes the whole selected group. Its text becomes one combined parent report or core result, according to the current `response`; a branch report may be empty. Text accompanying tool calls is retained with the model output and does not itself complete the activation or create a report.

### Compaction and budgets

Compaction uses the same request form with response `summary` and instructions from the dedicated [summary resource](../packages/agent/src/compaction.md), with tools disabled. The resulting handover replaces history as a context-only record; the summary instructions and state remain temporary, and ordinary work continues in the replacement context. The [architecture guide](architecture.md#bounded-model-context) explains when compaction occurs and how its request is bounded.

Records, current state, instructions, tools, and encoded content all contribute to the complete [request budget](architecture.md#bounded-model-context). Budget measurement uses the same assembled payload sent to the provider.

For implementation details, [architecture](architecture.md) explains request assembly and ownership. Its [email boundary](architecture.md#email-boundary) and [internal mail state](architecture.md#internal-mail-state) sections describe address projection, consumption receipts, and handover storage. The [email addressing reference](communication.md#current-email-addressing) defines the current ID mapping and supported syntax. See [tool content](content.md) for text and media returned by tools.
