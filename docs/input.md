# Model input and inference operations

Ivenna presents working history as YAML records alongside retained model output and tool replies. Each inference appends a temporary YAML request with current state and an operation. This document defines those records and requests. The [architecture guide](architecture.md#records-context-and-current-requests) explains how they are assembled from stored history.

The [Input definitions](../packages/agent/src/input.zig) and shared [incoming-message type](../packages/agent_contracts/src/communication.zig) define these fields. The [system prompt](../packages/agent/src/system.md) explains their meaning to the model.

## Format and lifetimes

Records and requests are user messages. `Text` denotes a free-form string. Tagged unions serialize as a YAML mapping containing exactly one branch name and its payload; a branch with no payload uses an empty object (`{}`). This applies to record content, events, session roles, and request operations.

Both forms identify a `session_id`. Session identifiers survive with retained working contexts across restart. Forked history keeps the original records and their session identifiers; the current request identifies the session performing this inference.

Records form the retained working history together with model output and tool replies. A request applies only to its inference: its state and operation are discarded afterward and are not inherited by forks. Later inferences receive fresh requests after the retained history.

## Retained records

A `Record` identifies its source session and contains one kind of content:

| Field | Type | Meaning |
| --- | --- | --- |
| `session_id` | `u64` | Session that admitted the events or produced the handover |
| `content` | Tagged union | An event group or a compaction handover |

`content` selects one branch:

| Branch | Payload | Meaning |
| --- | --- | --- |
| `events` | `Event[]` | Events admitted together, in queue order |
| `handover` | `Handover` | Compacted understanding needed for continuation |

### Event groups

Each activation records its selected group once in `content.events`. Events stay in queue order, and arrivals during the activation remain queued for later processing. See [activation admission](architecture.md#activation-admission) for group selection.

`Event` contains one of these branches:

| Branch | Payload | Meaning |
| --- | --- | --- |
| `startup` | `Startup` | Observation that a new runtime has begun |
| `input` | `IncomingMessage` | Observation of what correspondents said |
| `assignment` | `Assignment` | Initial work for a fork |
| `report` | `Report` | A child activation's final text |

For example, two arrivals can enter the core as one event group, each preserving its own source, text, and observation time:

```yaml
session_id: 1
content:
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

#### Incoming messages

The shared `Communication.IncomingMessage` represents an observation of who said what. It does not imply that the words were addressed specifically to Ivenna or require a response. An admitted arrival appears as an `input` event in the receiving session's working history.

`IncomingMessage` contains:

| Field | Type | Meaning |
| --- | --- | --- |
| `from` | `Text[]` | IDs of participants this message came from |
| `text` | `Text` | Complete message text |
| `observed_at_unix_ms` | `i64` | Runtime observation time in Unix milliseconds |

`from` contains readable [correspondent IDs](communication.md#correspondents-and-ids) accepted by `send_message`. The timestamp records when the runtime observed the message. Restoring history preserves that observation time.

#### Startup and restart

At startup, each retained session queues a `startup` event before its unread assignments and reports. Normal FIFO budget admission selects the events for a fresh activation, which can include startup and unread work together. `Startup` carries `observed_at_unix_ms: i64`, the observation time at the beginning of this runtime in Unix milliseconds. A newly created fork begins with an assignment instead.

Earlier records, model output, and tool replies describe prior observations and actions. The current request's state describes the live runtime. Loading a historical tool exchange does not invoke its calls, and an interrupted action may already have had effects. Ivenna chooses how to continue from that evidence. See [startup and interruption](architecture.md#startup-and-interruption) for session reconstruction and unread events.

#### Assignments and reports

An `Assignment` contains:

| Field | Type | Meaning |
| --- | --- | --- |
| `task` | `Text` | Work for the receiving session to continue |
| `from_session` | `u64` | Direct parent that created the fork |

An assignment describes the caller activation's whole work, and the child inherits the caller's retained history. See [fork ownership](architecture.md#forks-and-work-ownership) for publication, queueing, and context lifetimes.

The new session receives its assignment as a one-event group:

```yaml
session_id: 2
content:
  events:
    - assignment:
        task: Update the French practice plan.
        from_session: 1
```

A `Report` carries a branch activation's combined result for its direct parent:

| Field | Type | Meaning |
| --- | --- | --- |
| `from_session` | `u64` | Child session that produced the result |
| `text` | `Text` | Combined result text; may be empty |

The identifiers in fork results and reports let the parent associate results with the child that produced them. A report can remain queued after the child's context is released.

### Handovers

A `Handover` contains `summary: Text`, the retained understanding needed to continue work. Compaction replaces earlier working history with one `content.handover` record:

```yaml
session_id: 1
content:
  handover:
    summary: Keep each practice session to 20 minutes, including ten minutes of listening.
```

## Current requests

Every inference appends one temporary `Request` after retained history:

| Field | Type | Meaning |
| --- | --- | --- |
| `session_id` | `u64` | Session performing this inference |
| `state` | `State` | Current session and execution counts |
| `operation` | Tagged union | Ordinary execution or summarization with its instructions |

### Current state and session roles

`State` contains `session` and `runtime`:

| Field | Meaning |
| --- | --- |
| `session.role` | Tagged union selecting the core or a branch with its parent |
| `session.active_children` | Direct child contexts retained under this session |
| `runtime.active_sessions` | Retained contexts, including the core |
| `runtime.running_sessions` | Sessions currently handling an activation |
| `runtime.queued_inputs` | Events waiting in session queues, excluding reserved report slots |

Counts describe the snapshot for this request; other sessions can continue acting while it is processed.

`Role` selects one branch:

| Branch | Payload | Meaning |
| --- | --- | --- |
| `core` | Empty object | Permanent coordination session with no parent |
| `branch` | `parent_session_id: u64` | Work session belonging to the session that forked it |

The serialized role `branch` denotes a work session. For example, a branch forked by session 1 has:

```yaml
role:
  branch:
    parent_session_id: 1
```

The role and parent relationship survive compaction and restart.

### Inference operations

`operation` selects one branch:

| Branch | Payload | Meaning |
| --- | --- | --- |
| `execute` | Empty object | Continue ordinary work using the retained history and current state |
| `summarize` | `instructions: Text` | Condense retained history into a handover according to these instructions |

During `execute`, an activation ends in either of two ways:

- A response without tool calls completes the selected group. Its text stays internal for the core or becomes one combined report to the branch's direct parent; a report may be empty. The broader task may remain open.
- A successful `fork_session` transfers the group's whole work to a child, and the caller returns to its queue. The [assignment and inherited history](#assignments-and-reports) let the child continue that work.

Text accompanying tool calls is retained with the model output and does not itself complete the activation or create a report. Outgoing communication uses the independent `send_message` tool and its explicit recipients.

For example, an ordinary core request can be:

```yaml
session_id: 1
state:
  session:
    role:
      core: {}
    active_children: 1
  runtime:
    active_sessions: 2
    running_sessions: 2
    queued_inputs: 0
operation:
  execute: {}
```

### Compaction and budgets

Compaction selects `operation.summarize` with instructions from the dedicated [summary resource](../packages/agent/src/compaction.md) and disables tools. This inference summarizes retained history without continuing its tasks. Its handover starts a replacement working history in a `content.handover` record. The session identity, role, and parent relationship remain the same. Ordinary work then continues with an `execute` request and fresh state. The [architecture guide](architecture.md#bounded-model-context) explains when compaction occurs and how its request is bounded.

Records, current state, operation, tools, and encoded content all contribute to the complete request budget, including summary instructions when present. Budget measurement uses the same assembled payload sent to the provider. The runtime admits whole observations; a single input that cannot fit after compaction fails with `ContextBudgetExhausted`.

See [tool content](content.md) for text and media returned by tools, and [persistent working history](architecture.md#persistent-working-history) for the stored records underlying this model-facing view.
