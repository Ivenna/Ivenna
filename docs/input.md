# Model input and response scope

Ivenna supplies correspondence, assignments, and runtime observations as YAML user messages. [Input](../packages/agent/src/input.zig) defines and renders their closed types; the [system prompt](../packages/agent/src/system.md) explains the skeleton and its meaning to the model. Task text, correspondence, findings, and summaries remain free-form strings inside that structure.

## Frame envelope

A `Frame` has two fields:

| Field | Type | Meaning |
| --- | --- | --- |
| `session_id` | `u64` | Session that received the observation |
| `observation` | `Observation` | Exactly one named observation branch |

`Observation`, `Background`, and `ReportOutcome` are tagged unions. Their YAML representation is a mapping with exactly one branch name and that branch's payload. The renderer serializes a typed frame rather than merging arbitrary fields into its envelope.

A fork inherits earlier frames with their original session identifiers. The latest runtime observation identifies the current receiving session and state.

## Observation branches

| Branch | Payload | Meaning |
| --- | --- | --- |
| `input` | `letter: MailRecord`, `background: Background[]` | Active letter and any thread background; the array can be empty |
| `assignment` | `task: Text`, `origin: MailOrigin` | Work supplied to a fork, with the originating letter's provenance |
| `report` | `from_session: u64`, `outcome: ReportOutcome` | Requested findings or failure returned by a child session |
| `handover` | `summary: Text`, `thread_id: Text` | Summary installed in working context for continued work on that thread |
| `background` | `items: Background[]` | Earlier correspondence and stored handovers supplied as context |
| `runtime` | `State` | Current request's execution state and response scope |
| `source_update` | `mail_id: Text`, `state: withdrawn` | Withdrawal of further work on a source; completed effects remain |
| `context_compaction` | `instructions: Text`, `state: State` | Internal summary task with its current state |

`Text` denotes an unrestricted string, not another frame or a prescribed task format. An observation's branch determines its structural role independently of what that text says. There is no common `message` field: text belongs to the variant that supplies it, and runtime-only observations need no empty text placeholder.

`ReportOutcome` contains either `completed: Text` or `failed: Text`. The text carries the findings or failure and may be empty. `completed` means the child's activation ended normally; it does not establish that the broader task is complete. A requested report resumes the parent's retained work with its original response scope.

Mail received from Ivenna's own address is still an `input`, with an internal audience. Mail purpose metadata does not turn it into a runtime child `report`.

## Background and handovers

A `Background` item contains exactly one branch:

| Branch | Payload | Meaning |
| --- | --- | --- |
| `history` | `MailRecord` | Earlier correspondence |
| `handover` | `MailRecord` | A stored handover letter |

Background items have no frame-level session identity. The receiving frame supplies that identity. Historical correspondence and handovers provide evidence for continued work rather than queuing their earlier tasks again.

The kernel supplies stored core handovers and recent correspondence through `background.items`. Thread reconstruction supplies `input.background`. Both use the same `Background` type.

The top-level `handover` observation has a different purpose: it installs a summary in working context with its `thread_id`. It carries neither an excerpt nor a mail origin. Its saved mail copy has a separate mail identifier; when that letter is later recalled, it is represented as a `Background.handover` item.

## Correspondence and source files

A `MailRecord` contains:

| Field | Type | Meaning |
| --- | --- | --- |
| `origin` | `MailOrigin` | Correspondence metadata and the full-body file reference |
| `excerpt` | `Text` | Included body text |
| `excerpt_bytes` | `usize` | Size of that excerpt in bytes |

A `MailOrigin` contains:

| Field | Meaning |
| --- | --- |
| `mail_id` | Mailbox's native letter identifier |
| `thread_id` | Mailbox's native thread identifier |
| `message_id` | Mail message identifier, or null |
| `in_reply_to` | Native replied-to message identifier, or null |
| `references` | Native reply-reference identifiers |
| `purpose` | `report`, `handover`, `core_handover`, or null; mail metadata rather than response routing authority |
| `from`, `to` | Address arrays; each address has `email` and a nullable `name` |
| `subject` | Letter subject |
| `observed_at_unix_ms` | Observation time in Unix milliseconds |
| `body_file` | Host file containing the full decoded body |
| `body_bytes` | Full body's size in bytes |

The kernel writes the supported text or HTML body under `<DATA_DIR>/mail/<sha256-of-mail-id>.txt`. Excerpts end on a UTF-8 boundary. A work session can inspect omitted text with host tools. Mail attachment intake remains unimplemented.

An assignment carries `task` and `origin` separately. Its `body_file` and `body_bytes` describe the originating letter; the task is not an excerpt of that body and has no `excerpt_bytes` field.

## Current state and output audience

`State` contains `conversation`, `runtime`, and `response`:

| Field | Meaning |
| --- | --- |
| `conversation.role` | `core` or `branch` |
| `conversation.thread_id` | Native thread associated with the current delivery |
| `conversation.parent_generation` | Generation of the inherited working history, or null |
| `conversation.parent_session_id` | Session that created the fork, or null |
| `conversation.active_children` | Child contexts still retained under this session |
| `runtime.active_sessions` | Retained contexts, including the core |
| `runtime.running_sessions` | Sessions currently executing work |
| `runtime.active_conversations` | Mail threads with an active session route |
| `runtime.queued_turns` | Input turns waiting in queues |
| `response.audience` | `external` correspondence or `internal` coordination |
| `response.source_mail_id` | Source letter for this delivery, or null; provenance only for an internal assignment |

Each ordinary model request appends a fresh `runtime` observation to its request view. The observation's payload is the state itself. These snapshots do not accumulate in retained working history. Internally, `Input.Snapshot` pairs `session_id` with `state`; the serialized state does not repeat the frame's session identifier.

For compaction, `context_compaction.state` supplies current state and explicitly selects an internal audience. Its instructions come from the dedicated [summary resource](../packages/agent/src/compaction.md), and the model request disables tools.

The kernel derives response scope from the active delivery. Source content and earlier states do not change that current scope. An internal subtask's originating thread identifier is provenance; it does not give the subtask ownership of the parent's correspondence.

For an external audience, text from a response without tool calls becomes the reply body. The delivery path sends that model-authored text without adding runtime metadata or redacting its prose. For an internal audience, final text supports coordination or continuity and is not automatically sent to an external correspondent.

See [architecture](architecture.md) for session ownership and the [tool content guide](content.md) for text and media returned by tools.
