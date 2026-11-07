# Model input and response scope

Ivenna presents working history as YAML user messages alongside retained model output and tool replies. Each inference adds a temporary YAML request with current state and, for summarization, instructions. This document defines that model-facing form. The [architecture guide](architecture.md#records-context-and-current-requests) explains how it is assembled from stored history.

The [Input definitions](../packages/agent/src/input.zig) and shared [incoming-message type](../packages/agent_contracts/src/communication.zig) define these fields. The [system prompt](../packages/agent/src/system.md) explains their meaning to the model.

## Retained records

A `Record` contains an event group or a compaction handover:

| Field | Type | Meaning |
| --- | --- | --- |
| `session_id` | `u64` | Session that admitted the events or produced the handover |
| `events` | `Event[]` | Events admitted together, in queue order; defaults to an empty array |
| `handover` | `Handover` or null | Compacted understanding; omitted from YAML when null |

Each activation records its selected group once in `events`. Compaction replaces earlier history with a handover record with `events: []`.

Session identifiers survive with retained working contexts across restart. Forked history keeps the original records and their session identifiers. The current request identifies the session performing the inference and supplies its current execution state.

Each input keeps its own `from` IDs, text, and observation time within the admitted group. See [activation admission](architecture.md#activation-admission) for how the runtime selects a group and handles later arrivals.

## Events and handovers

`Event` contains one of these branches:

| Branch | Payload | Meaning |
| --- | --- | --- |
| `startup` | `Startup` | Observation that a new runtime has begun |
| `input` | `IncomingMessage` | Observation of what correspondents said |
| `assignment` | `Assignment` | Initial work for a fork |
| `report` | `Report` | A child activation's final text |

A `Handover` contains `summary: Text`, the retained understanding needed to continue work.

`Event` and `Response` are tagged unions. Their YAML representation is a mapping with one branch name and that branch's payload. `Text` denotes a free-form string.

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
```

Compaction can replace earlier history with a handover record:

```yaml
session_id: 1
events: []
handover:
  summary: Keep each practice session to 20 minutes, including ten minutes of listening.
```

## Incoming messages

The shared `Communication.IncomingMessage` represents an observation of who said what. It does not imply that the words were addressed specifically to Ivenna or require a response. An admitted arrival appears as an `input` event in the receiving session's working history.

`IncomingMessage` contains:

| Field | Type | Meaning |
| --- | --- | --- |
| `from` | `Text[]` | IDs of participants this message came from |
| `text` | `Text` | Complete message text |
| `observed_at_unix_ms` | `i64` | Runtime observation time in Unix milliseconds |

`from` contains readable [correspondent IDs](communication.md#correspondents-and-ids) accepted by `send_message`. The timestamp records when the runtime observed the message. Restoring history preserves that observation time.

The [whole-request budget](architecture.md#bounded-model-context) counts the complete message. The runtime admits whole observations; a single input that cannot fit after compaction fails with `ContextBudgetExhausted`.

## Startup and restart

At startup, each retained session queues a `startup` event before its unread assignments and reports. Normal FIFO budget admission selects the events for a fresh activation, which can include startup and unread work together. `Startup` carries `observed_at_unix_ms: i64`, the observation time at the beginning of this runtime in Unix milliseconds. A newly created fork begins with an assignment instead.

For example, a session can receive:

```yaml
session_id: 1
events:
  - startup:
      observed_at_unix_ms: 1793966400000
```

Earlier records, model output, and tool replies describe prior observations and actions. The current request's state describes the live runtime. Loading a historical tool exchange does not invoke its calls, and an interrupted action may already have had effects. Ivenna chooses how to continue from that evidence. See [startup and interruption](architecture.md#startup-and-interruption) for session reconstruction and unread events.

## Assignments and reports

An `Assignment` contains:

| Field | Type | Meaning |
| --- | --- | --- |
| `task` | `Text` | Work for the receiving session to continue |
| `from_session` | `u64` | Direct parent that created the fork |

An assignment describes the caller activation's whole work, and the child inherits the caller's retained history. See [fork ownership](architecture.md#forks-and-work-ownership) for publication, queueing, and context lifetimes.

The new session receives its assignment as a one-event group:

```yaml
session_id: 2
events:
  - assignment:
      task: Update the French practice plan.
      from_session: 1
```

A `Report` contains `from_session: u64` and `text: Text`, which may be empty. It carries a branch activation's combined result for its direct parent. The identifiers in fork results and reports let the parent associate results with the child that produced them. A report can remain queued after the child's context is released.

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
| `session.parent_session_id` | Session that created this fork, or null |
| `session.active_children` | Direct child contexts retained under this session |
| `runtime.active_sessions` | Retained contexts, including the core |
| `runtime.running_sessions` | Sessions currently handling an activation |
| `runtime.queued_inputs` | Events waiting in session queues, excluding reserved report slots |

The serialized role `branch` denotes a work session. Counts describe the snapshot for this request; other sessions can continue acting while it is processed.

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

Compaction uses the same request form with response `summary` and instructions from the dedicated [summary resource](../packages/agent/src/compaction.md), with tools disabled. The resulting handover starts a replacement working history in a record with an empty `events` list. The session identity remains the same; summary instructions and state stay temporary, and ordinary work continues in the replacement context. The [architecture guide](architecture.md#bounded-model-context) explains when compaction occurs and how its request is bounded.

Records, current state, instructions, tools, and encoded content all contribute to the complete [request budget](architecture.md#bounded-model-context). Budget measurement uses the same assembled payload sent to the provider.

See [tool content](content.md) for text and media returned by tools, and [persistent working history](architecture.md#persistent-working-history) for the stored records underlying this model-facing view.
