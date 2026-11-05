# Model input and response scope

Ivenna supplies content, contacts, assignments, reports, and runtime state as typed observations. [Input](../packages/agent/src/input.zig) defines and renders them as YAML user messages; the [system prompt](../packages/agent/src/system.md) explains their structure and meaning to the model. Task text and source material remain free-form strings within those types.

## Frame envelope

A `Frame` has two fields:

| Field | Type | Meaning |
| --- | --- | --- |
| `session_id` | `u64` | Session receiving the observation |
| `observation` | `Observation` | Exactly one named observation branch |

`Observation`, `Content`, `Background`, and `Response` are tagged unions. Their YAML representation is a mapping with one branch name and that branch's payload. `Text` below denotes a free-form string.

Session identifiers are scoped to one kernel process. A fork inherits earlier frames with their original session identifiers. The latest runtime observation identifies the current session and state.

## Observation branches

| Branch | Payload | Meaning |
| --- | --- | --- |
| `input` | `Input` | Independently received content, contacts, optional provenance, and supporting context |
| `assignment` | `Assignment` | Initial work for a fork |
| `report` | `Report` | A child activation's final text |
| `handover` | `Handover` | Working understanding for continuation |
| `background` | `items: Background[]` | Evidence and handovers supplied as context |
| `runtime` | `State` | Current execution state and response destination |
| `context_compaction` | `instructions: Text`, `state: State` | Summary task with current state |

Reports carry activation results; the broader task can remain open.

## Content, source, and context

`Input` contains:

| Field | Type | Meaning |
| --- | --- | --- |
| `content` | `Content` | Material for the receiving session |
| `contacts` | `Contact[]` | Available recipients; defaults to an empty array |
| `source` | `Source` or null | Optional provenance |
| `context` | `Background[]` | Supporting material; defaults to an empty array |

`Content` has two branches:

| Branch | Payload | Meaning |
| --- | --- | --- |
| `text` | `Text` | Complete inline content |
| `excerpt` | `text: Text`, `full: Resource` | Included text and a reference to the full material |

Both representations count toward the [whole-request budget](architecture.md#bounded-model-context).

An optional `Source` contains:

| Field | Type | Meaning |
| --- | --- | --- |
| `reference` | `Text` | Reference identifying the source material |
| `description` | `Text` or null | Human-readable provenance |
| `observed_at_unix_ms` | `i64` or null | Observation time in Unix milliseconds, when known |
| `details` | `Resource` or null | Additional source material available for inspection |

A `Resource` has `file: Text` and `byte_length: usize`. It identifies a file and its content length. Work sessions can inspect that file through host tools when they need material omitted from the observation.

An `Evidence` record has `content: Content`, `contacts: Contact[]` (default empty), and `source: Source | null`. `Background` contains either `evidence: Evidence` or `handover: Handover`. Both `Input.context` and startup `background.items` use these types to supply context for current work.

The [email boundary](architecture.md#email-boundary-and-source-materials) defines how correspondence becomes content and source resources.

## Contacts and outgoing messages

[Communication](../packages/agent/src/communication.zig) defines a `Contact` with `reference: Text` and `description: Text | null` (default null). Its reference identifies a recipient for `send_message`; its description provides human-readable context. Contacts and source provenance are independent. Input can have either, both, or neither.

Outgoing messages use [the communication tool](communication.md#sending-a-message). Sending is an explicit external action; an activation's final text is a core result or a report to its parent.

## Assignments and handovers

An `Assignment` contains:

| Field | Meaning |
| --- | --- |
| `task` | Work for the receiving session to continue |
| `from_session` | Direct parent that created the fork |
| `source_refs` | References to relevant source material; defaults to an empty array |

`fork_session` gives the child this assignment with a copy of the caller's working context. The child handles it in its own activation; the caller's activation ends when work is handed off. See [fork ownership](architecture.md#forks-and-work-ownership) for publication, queueing, and context lifetimes.

A `Report` contains `from_session: u64` and `text: Text`, which may be empty. Each branch activation's final text is queued for its direct parent. The parent handles it as a later activation in its own context; the arrival does not interrupt its current work. The identifiers in fork results and reports let the parent associate results with the child that produced them.

A `Handover` contains `summary: Text` and `source: Resource | null`. Generated summaries can have `source: null`; a recalled handover can reference its stored material. This type carries working understanding. Persistent lookup uses execution state keys, as described in [internal mail state](architecture.md#internal-mail-state).

## Current state and response destinations

`State` contains `session`, `runtime`, and `response`:

| Field | Meaning |
| --- | --- |
| `session.role` | `core` or `branch` |
| `session.parent_generation` | Generation of inherited context, or null |
| `session.parent_session_id` | Session that created this fork, or null |
| `session.active_children` | Child contexts retained under this session |
| `runtime.active_sessions` | Retained contexts, including the core |
| `runtime.running_sessions` | Sessions currently executing work |
| `runtime.queued_inputs` | Deliveries waiting in queues |

`Response` contains one destination:

| Branch | Payload | Meaning |
| --- | --- | --- |
| `report` | `session_id: u64` | Return the branch result to its direct parent |
| `internal` | Empty object | Complete core work |
| `summary` | Empty object | Produce a handover for the summary operation |

These destinations govern activation results. Outgoing communication uses the independent `send_message` tool and its explicit recipients.

Each ordinary request ends with a fresh `runtime` observation in its request view. These snapshots do not accumulate in retained history. For compaction, `context_compaction.state` supplies current state with response `summary`. Instructions come from the dedicated [summary resource](../packages/agent/src/compaction.md), and the model request disables tools.

A response without tool calls ends the current activation. Available final text becomes its parent report, core result, or summary, according to the current `response`.

See [architecture](architecture.md) for session, delivery, and internal-state ownership, and [tool content](content.md) for text and media returned by tools.
