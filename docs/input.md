# Model input and response scope

Ivenna's YAML user messages contain retained records or a current request. Records preserve events, startup material, and handovers in working history. The request adds current state and, for summarization, instructions. These YAML messages sit alongside retained model output and tool replies; the [architecture guide](architecture.md#records-context-and-current-requests) describes that complete history and its adapter-owned continuation data.

The core's [Input](../packages/agent/src/input.zig) module defines the record and request structures and renders them as YAML. Shared [material](../packages/agent_contracts/src/material.zig) and [handover](../packages/agent_contracts/src/handover.zig) types supply their native payloads. The [system prompt](../packages/agent/src/system.md) explains their meaning to the model.

## Retained records

A `Record` combines an event group with a list of context items:

| Field | Type | Meaning |
| --- | --- | --- |
| `session_id` | `u64` | Session receiving the record |
| `events` | `Event[]` | Events admitted together, in queue order; defaults to an empty array |
| `context` | `ContextItem[]` | Supporting material retained with the record; defaults to an empty array |

The events and context fields can coexist. Each activation records its selected group once in `events`; startup recollection and compaction create context-only records with `events: []`. Startup recollection records the latest core handover and evidence from recent correspondence. Compaction replaces earlier history with a handover.

Session identifiers are scoped to one kernel process. Forked history keeps the original records and their session identifiers. The current request identifies the session performing the inference.

Each activation's record preserves its admitted event group and the order of those events in history. Each input keeps its own material, contacts, and provenance within that group. See [activation admission](architecture.md#activation-admission) for how the runtime selects a group and handles later arrivals.

## Events and context items

`Event` contains one of these branches:

| Branch | Payload | Meaning |
| --- | --- | --- |
| `input` | `Material` | Independently received content, contacts, and optional provenance |
| `assignment` | `Assignment` | Initial work for a fork |
| `report` | `Report` | A child activation's final text |

`ContextItem` contains either `evidence: Material` or `handover: Handover`. Startup correspondence is supplied as evidence items; recalled and generated summaries are handover items. Each evidence item keeps its own contacts and provenance.

A `Handover` contains `summary: Text` and `source: Resource | null`. The optional source identifies stored material behind the summary. Generated handovers use `source: null`.

`Event`, `ContextItem`, `MaterialContent`, and `Response` are tagged unions. Their YAML representation is a mapping with one branch name and that branch's payload. `Text` denotes a free-form string.

For example, two arrivals can enter the core as one event group:

```yaml
session_id: 1
events:
  - input:
      content:
        text: Keep practice sessions to 20 minutes.
      contacts: []
      source: null
  - input:
      content:
        text: Include ten minutes of listening.
      contacts: []
      source: null
context: []
```

Compaction can replace earlier history with a context-only handover record:

```yaml
session_id: 1
events: []
context:
  - handover:
      summary: Keep each practice session to 20 minutes, including ten minutes of listening.
      source: null
```

## Material and provenance

The shared `Material` type represents both incoming content and supporting evidence. Adapters supply new arrivals in an [Inbox.Incoming](../packages/agent_contracts/src/inbox.zig) envelope, which can also carry an opaque consumption receipt. The runtime keeps receipts for processing bookkeeping; only the material enters the YAML `input` event.

`Material` contains:

| Field | Type | Meaning |
| --- | --- | --- |
| `content` | `MaterialContent` | Material for the receiving session |
| `contacts` | `Contact[]` | Available recipients; defaults to an empty array |
| `source` | `Source` or null | Optional provenance |

`MaterialContent` has two branches:

| Branch | Payload | Meaning |
| --- | --- | --- |
| `text` | `Text` | Complete inline content |
| `excerpt` | `text: Text`, `full: Resource` | Included text and a reference to the full material |

The [whole-request budget](architecture.md#bounded-model-context) counts the inline text and resource-reference fields.

An optional `Source` contains:

| Field | Type | Meaning |
| --- | --- | --- |
| `reference` | `Text` | Reference identifying the source material |
| `description` | `Text` or null | Human-readable provenance |
| `observed_at_unix_ms` | `i64` or null | Observation time in Unix milliseconds, when known |
| `details` | `Resource` or null | Additional source material available for inspection |

A `Resource` has `file: Text` and `byte_length: usize`. It identifies a file and its content length. Work sessions can inspect that file through host tools when they need material omitted from the observation.

## Contacts and outgoing messages

[Communication](../packages/agent_contracts/src/communication.zig) defines a `Contact` with `reference: Text` and `description: Text | null` (default null). Its reference identifies a recipient for `send_message`; its description provides human-readable context. Contacts and source provenance are independent. Material can have either, both, or neither.

Outgoing messages use [the communication tool](communication.md#sending-a-message). Sending is an explicit external action; an activation's final text is a core result or a report to its parent.

## Assignments and reports

An `Assignment` contains:

| Field | Meaning |
| --- | --- |
| `task` | Work for the receiving session to continue |
| `from_session` | Direct parent that created the fork |
| `source_refs` | Source references carried by the transferred inputs and assignments; defaults to an empty array |

An assignment describes the caller activation's whole work, and the child inherits the caller's retained history. See [fork ownership](architecture.md#forks-and-work-ownership) for publication, queueing, and context lifetimes.

The new session receives its assignment as a one-event group:

```yaml
session_id: 2
events:
  - assignment:
      task: Update the French practice plan.
      from_session: 1
      source_refs: []
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

For implementation details, [architecture](architecture.md) explains request assembly and ownership. Its [email boundary](architecture.md#email-boundary-and-source-materials) and [internal mail state](architecture.md#internal-mail-state) sections describe the current correspondence projection and handover storage. See [tool content](content.md) for text and media returned by tools.
