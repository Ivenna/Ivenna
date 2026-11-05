# Model input and response scope

Ivenna supplies content, assignments, findings, and runtime state as typed observations. [Input](../packages/agent/src/input.zig) defines and renders them as YAML user messages; the [system prompt](../packages/agent/src/system.md) explains their structure and meaning to the model. Task text and source material remain free-form strings within those types.

## Frame envelope

A `Frame` has two fields:

| Field | Type | Meaning |
| --- | --- | --- |
| `session_id` | `u64` | Session receiving the observation |
| `observation` | `Observation` | Exactly one named observation branch |

`Observation`, `Content`, `Background`, `Response`, and `ReportOutcome` are tagged unions. Their YAML representation is a mapping with one branch name and that branch's payload. `Text` below denotes a free-form string.

A fork inherits earlier frames with their original session identifiers. The latest runtime observation identifies the current session and state.

## Observation branches

| Branch | Payload | Meaning |
| --- | --- | --- |
| `input` | `Input` | Content with optional provenance and supporting context |
| `assignment` | `Assignment` | Work supplied by another session |
| `report` | `from_session: u64`, `outcome: ReportOutcome` | Requested findings or failure from a child |
| `handover` | `Handover` | Working understanding for continuation |
| `background` | `items: Background[]` | Evidence and handovers supplied as context |
| `runtime` | `State` | Current execution state and response destination |
| `work_update` | `state: withdrawn` | Withdrawal of further work on the current activation |
| `context_compaction` | `instructions: Text`, `state: State` | Summary task with current state |

A work update concerns the active delivery. It leaves completed effects in place and does not cancel descendant sessions. `ReportOutcome` contains `completed: Text` or `failed: Text`; its text may be empty. These outcomes describe the child's activation, while the broader task can remain open.

## Content, source, and context

`Input` contains:

| Field | Type | Meaning |
| --- | --- | --- |
| `content` | `Content` | Material for the receiving session |
| `source` | `Source` or null | Optional provenance |
| `context` | `Background[]` | Supporting material; defaults to an empty array |

`Content` has two branches:

| Branch | Payload | Meaning |
| --- | --- | --- |
| `text` | `Text` | Complete inline content |
| `excerpt` | `text: Text`, `full: Resource` | Included text and a reference to the full material |

The whole-request budget applies to either representation. The email boundary ends excerpts on UTF-8 boundaries and supplies a resource when material exceeds its excerpt budget.

An optional `Source` contains:

| Field | Type | Meaning |
| --- | --- | --- |
| `reference` | `Text` | Reference identifying the source material |
| `description` | `Text` or null | Human-readable provenance |
| `observed_at_unix_ms` | `i64` or null | Observation time in Unix milliseconds, when known |
| `details` | `Resource` or null | Additional source material available for inspection |

A `Resource` has `file: Text` and `byte_length: usize`. It identifies a file and its content length. Work sessions can inspect that file through host tools when they need material omitted from the observation. Content can also be supplied entirely inline, with `source: null`.

An `Evidence` record has `content: Content` and `source: Source | null`. `Background` contains either `evidence: Evidence` or `handover: Handover`. Both `Input.context` and startup `background.items` use these types. They supply context for continued work rather than starting earlier tasks again.

The [email boundary](architecture.md#email-boundary-and-source-materials) defines how correspondence becomes content and source resources. Its capture and storage details are separate from these payload types.

## Assignments and handovers

An `Assignment` contains:

| Field | Meaning |
| --- | --- |
| `task` | Work for the receiving session to continue |
| `from_session` | Session that issued the assignment |
| `source_refs` | References to relevant source material; defaults to an empty array |

The assignment supplies work independently of any inherited observations. Its response destination arrives in current runtime state.

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
| `reply` | `audience: Text[]` | Address the stated audience |
| `report` | `session_id: u64` | Return requested findings to this session |
| `internal` | Empty object | Complete internal work |
| `summary` | Empty object | Produce a handover for the summary operation |

The audience describes who the result addresses. The execution layer retains its delivery target separately; source descriptions and references provide provenance without selecting a response destination.

Each ordinary request ends with a fresh `runtime` observation in its request view. These snapshots do not accumulate in retained history. For compaction, `context_compaction.state` supplies current state with response `summary`. Instructions come from the dedicated [summary resource](../packages/agent/src/compaction.md), and the model request disables tools.

A response without tool calls ends the current activation. Available final text becomes its reply, requested report, internal result, or summary. Source content and earlier states do not redefine the current destination.

See [architecture](architecture.md) for session, delivery, and internal-state ownership, and [tool content](content.md) for text and media returned by tools.
