# Runtime user messages

This contract defines the structured `role=user` input produced by Ivenna's runtime: retained history records and the final turn supplied for each inference. Model output and tool replies keep their own roles and formats. Those messages, earlier observations, and handovers carry the understanding of work; a new turn adds current runtime facts and its purpose. See [inference assembly](architecture.md#working-history-and-user-messages) for the complete model request.

The [Input definitions](../packages/agent/src/input.zig) and shared [incoming-message type](../packages/agent_contracts/src/communication.zig) define the fields. The [system prompt](../packages/agent/src/system.md) explains their meaning to the model.

## Records and turns

The interfaces have two lifetimes:

| Interface | Shape | Lifetime and meaning |
| --- | --- | --- |
| `Input.Record` | Either `events` or `handover` | Delivered observations or condensed understanding retained in working history |
| `Input.Turn` | `current` and `purpose` together | Fresh execution facts and purpose for one inference |

A turn's `purpose` selects either `work`, containing newly delivered `events`, or `summarize`, containing summary `instructions`. Current state accompanies either purpose. Ordinary events are retained before inference; the turn's current state and purpose are not saved as history.

`Text` denotes a free-form string. Tagged unions, including events and session roles, serialize as a mapping containing one branch name and its payload. A branch with no payload uses an empty object (`{}`).

Session IDs remain registered across sleep, context unloading, and restart. Records identify the session that admitted observations or produced a handover. Forked history preserves those original IDs; a turn's `current.session_id` identifies the session performing this inference.

## Retained records

`Input.Record` selects `events` or `handover` and renders as a YAML user message. Native model output and tool replies retain their own roles and formats as complete exchanges. Together they form the working history that forks inherit, without past turns' temporary state or purpose. The [history codec](architecture.md#persistent-working-history) owns their storage encoding and checkpoints.

### Event groups

An `events` record has `session_id: u64` and `items: Event[]`. Each admission retains one FIFO group. For the next ordinary inference, that group's items appear in `purpose.work.events` alongside current state, without a duplicate record in the preceding messages. Subsequent history keeps the record without temporary state. If compaction occurs first, the already retained group participates in handover generation and the next work turn can instead continue from that handover with empty events. Observations still awaiting admission stay out of the summary. An activation can admit further groups between complete model/tool batches and later inferences. See [activation admission](architecture.md#activation-admission).

`Event` selects one branch:

| Branch | Payload | Meaning |
| --- | --- | --- |
| `startup` | `Startup` | Observation that a new runtime has begun |
| `input` | `IncomingMessage` | Observation of what correspondents said |
| `assignment` | `Assignment` | Initial work for a fork |
| `report` | `Report` | A branch activation's final text, delivered to its direct parent and the core |
| `session_message` | `SessionMessage` | Observation sent directly by another session |
| `callback` | `Callback` | A registered host completion or self-scheduled wakeup |
| `session_created` | `SessionCreated` | Core observation of a session created by a work session |

For example, two arrivals can enter the core together while preserving their individual sources and observation times:

```yaml
events:
  session_id: 1
  items:
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

The shared `Communication.IncomingMessage` represents an observation of who said what. It does not imply that the words were addressed specifically to Ivenna or require a response. Correspondence is admitted to the core as an `input` event.

| Field | Type | Meaning |
| --- | --- | --- |
| `from` | `Text[]` | IDs of participants this message came from |
| `text` | `Text` | Complete message text |
| `observed_at_unix_ms` | `i64` | Runtime observation time in Unix milliseconds |

`from` contains readable [correspondent IDs](communication.md#correspondents-and-ids) accepted by `send_message`. Restoring history preserves the original observation time.

#### Startup and restart

At startup, the core, interrupted work, and sessions with unread internal observations queue `startup` before that work. Other branches remain asleep until a real event arrives; their first activation in the new runtime prepends startup. FIFO budget admission can select startup and unread work together. `Startup` carries `observed_at_unix_ms: i64`, the observation time at the beginning of this runtime. A newly created fork begins with an assignment instead.

Earlier records, model output, and tool replies describe prior observations and actions. A turn's `current` describes the live runtime. Loading a historical tool exchange does not invoke its calls, and an interrupted action may already have had effects. See [startup and interruption](architecture.md#startup-and-interruption) for reconstruction and unread events.

#### Assignments and reports

An `Assignment` contains:

| Field | Type | Meaning |
| --- | --- | --- |
| `task` | `Text` | Work for the receiving session to continue |
| `from_session` | `u64` | Direct parent that created the fork |

An assignment describes the caller activation's work, and the child inherits its retained history. It is the new session's first queued event. For example:

```yaml
events:
  session_id: 2
  items:
    - assignment:
        task: Update the French practice plan.
        from_session: 1
```

A `Report` carries a branch activation's combined result to its direct parent and the core, with one delivery when the parent is the core:

| Field | Type | Meaning |
| --- | --- | --- |
| `from_session` | `u64` | Work session that produced the result |
| `text` | `Text` | Combined result text; may be empty |

The source ID associates a report with its work session, including when the core receives a nested fork's report. That session remains addressable after reporting. See [fork ownership](architecture.md#forks-and-work-ownership) for publication and report destinations.

When a work session creates a child, the core receives a `SessionCreated` observation:

| Field | Type | Meaning |
| --- | --- | --- |
| `session_id` | `u64` | Newly registered work session |
| `parent_session_id` | `u64` | Session that created it |
| `task` | `Text` | Initial assignment |

The core's own forks are already recorded in its tool exchanges and produce no duplicate creation event. These observations and reports preserve the understanding of work; the temporary roster supplies separate execution facts.

#### Session messages and callbacks

`send_session_message` produces a `SessionMessage`:

| Field | Type | Meaning |
| --- | --- | --- |
| `from_session` | `u64` | Actual sending session, supplied by the runtime |
| `observed_at_unix_ms` | `i64` | Time the runtime accepted the message |
| `text` | `Text` | Observation or coordination message |

The text remains a source-attributed observation. Relaying another session's or correspondent's words does not change the actual sender. The receiver relates it to its own understanding; sending confirms acceptance rather than agreement or task completion.

Background host completions and scheduled wakeups arrive as `Callback` observations for the sessions that invoked the host tool or scheduled the wakeup:

| Field | Type | Meaning |
| --- | --- | --- |
| `id` | `u64` | Registered callback identity |
| `source` | `host` or `wakeup` | Kind of event source |
| `observed_at_unix_ms` | `i64` | Time the runtime observed the callback |
| `text` | `Text` | Host outcome or the supplied wakeup text |

A host callback's ID matches its returned `activity_id`; a wakeup's ID matches the returned `callback_id`. Destinations remain fixed across forks and restart. Duplicate delivery of an admitted callback creates no further event.

A host callback reports the stored result or an interrupted activity with an unknown outcome; the command is not replayed. See [background commands](host.md#background-commands) for result text and media omissions, and [session communication and wakeups](communication.md#session-communication-and-wakeups) for arguments and delivery outcomes.

### Handovers

A `handover` record has `session_id: u64` and `summary: Text`. Compaction replaces earlier working history with this retained understanding:

```yaml
handover:
  session_id: 1
  summary: Keep each practice session to 20 minutes, including ten minutes of listening.
```

The session identity, role, and parent relationship remain unchanged. Retention of earlier storage records follows the separate [history lifecycle](architecture.md#history-retention).

## Inference turns

Each inference ends its input with a turn containing both fields:

| Field | Type | Meaning |
| --- | --- | --- |
| `current` | `Current` | `session_id: u64` and a fresh `state: State` |
| `purpose` | Tagged union | Ordinary work with delivered events, or summarization with instructions |

`purpose` selects one branch:

| Branch | Payload | Meaning |
| --- | --- | --- |
| `work` | `events: Event[]` | Continue ordinary work with these new observations |
| `summarize` | `instructions: Text` | Generate a handover from the complete retained message sequence |

`work.events` can be empty, including after a tool exchange or when the core is scheduled to reconsider concurrent attention without a new event. The turn still supplies fresh current state. The attention signal stays internal; it introduces no revision field or historical notice.

### Current state and session roles

`State` contains `session` and `runtime`:

| Field | Meaning |
| --- | --- |
| `session.role` | Tagged union selecting the core or a branch with its parent |
| `session.child_sessions` | Registered direct children of this session |
| `session.callbacks` | Pending callback registrations for this session |
| `runtime.observed_at_unix_ms` | Time of this snapshot in Unix milliseconds |
| `runtime.registered_sessions` | Registered sessions, including dormant sessions and the core |
| `runtime.running_sessions` | Sessions currently handling an activation |
| `runtime.queued_inputs` | Events waiting in session queues, excluding reserved report slots |
| `runtime.sessions` | `SessionInfo[]` roster for all registered sessions |

Every turn supplies the complete snapshot of this finite runtime projection: the fields above, the session roster, and the caller's pending callbacks. In a work turn, pending counts reflect the events in that turn having been admitted: delivered callbacks are no longer listed as pending, while events left in queues remain counted. Task meaning, reasoning, tool outcomes, and earlier observations remain in preceding messages, handovers, and autonomous memory; the snapshot supplies execution facts rather than that understanding. Other sessions can act while the snapshot is processed. Each `SessionInfo` contains:

| Field | Type | Meaning |
| --- | --- | --- |
| `session_id` | `u64` | Stable session ID |
| `role` | `Role` | Core or branch with its parent |
| `status` | `running`, `ready`, or `dormant` | Executing, awaiting an activation, or sleeping |
| `queued_inputs` | `usize` | Events waiting in this session's queue |
| `pending_callbacks` | `usize` | Registrations awaiting admission to this session's history |
| `last_active_unix_ms` | `i64` | Most recent activation start or end; `0` before its first activation |

Each `session.callbacks` item is a `PendingCallback` with `id: u64`, `session_id: u64`, and `source` selecting `host` or `wakeup`. It identifies an expected observation; its text arrives separately as an event.

A `ready` session has work waiting; starting its activation still depends on scheduling and capacity. A `ready` core can have `queued_inputs: 0` when an internal attention signal has scheduled it to reconsider state.

`Role` selects `core: {}` or `branch: {parent_session_id: u64}`. This relationship survives compaction and restart. For example, an ordinary core inference can receive a new observation with its current state:

```yaml
current:
  session_id: 1
  state:
    session:
      role:
        core: {}
      child_sessions: 1
      callbacks: []
    runtime:
      observed_at_unix_ms: 1793966401000
      registered_sessions: 2
      running_sessions: 1
      queued_inputs: 0
      sessions:
        - session_id: 1
          role:
            core: {}
          status: running
          queued_inputs: 0
          pending_callbacks: 0
          last_active_unix_ms: 1793966401000
        - session_id: 2
          role:
            branch:
              parent_session_id: 1
          status: dormant
          queued_inputs: 0
          pending_callbacks: 1
          last_active_unix_ms: 1793966400000
purpose:
  work:
    events:
      - input:
          from: [operator]
          text: Keep each practice session to 20 minutes.
          observed_at_unix_ms: 1793966401000
```

An ordinary activation ends when a response has no tool calls and no further events or core attention signal require another inference. Final core text stays internal; a branch's final text becomes reports to its direct parent and the core. Task success is a separate judgment. A successful fork instead transfers the activation's work and inherited understanding to a child, leaving unadmitted events and existing callback destinations with the caller. See [activation completion](architecture.md#activation-completion-and-sleep).

## Handover generation and replacement

Compaction has two stages with different model inputs. First, a maintenance inference reads the complete retained LLM message sequence: the system prompt, user history records, native model output, and tool replies, followed by a turn whose purpose is `summarize`. Generating a handover does not clear or replace those messages. Earlier turns' temporary state and purpose are not part of that retained sequence.

For example, a summary request can describe one core session with an event still waiting:

```yaml
current:
  session_id: 1
  state:
    session:
      role:
        core: {}
      child_sessions: 0
      callbacks: []
    runtime:
      observed_at_unix_ms: 1793966402000
      registered_sessions: 1
      running_sessions: 1
      queued_inputs: 1
      sessions:
        - session_id: 1
          role:
            core: {}
          status: running
          queued_inputs: 1
          pending_callbacks: 0
          last_active_unix_ms: 1793966401000
purpose:
  summarize:
    instructions: Preserve goals, commitments, evidence, uncertainty, and next steps.
```

The runtime supplies instructions from [compaction.md](../packages/agent/src/compaction.md) and disables tools. The model returns only handover text, without continuing tasks or responding to events. Waiting events are not added to this summary turn; summarization neither admits them nor satisfies a pending core attention signal.

Only after successful generation and validation does the runtime replace the retained sequence with the system prompt and a `handover` record. The next ordinary inference uses that replacement history plus a new turn with fresh `current` and `purpose.work`. Earlier messages are not reinserted into that new request. Session identity and relationships persist. See [bounded model context](architecture.md#bounded-model-context) for budgets and the replacement boundary.

Ordinary and summary inferences each use their configured [complete-request byte budget](running.md#configuration). History, temporary messages, tool declarations, instructions, and encoded content all contribute as applicable. Measurement uses the same assembled payload sent to the provider. Whole observations are admitted; a single event that cannot fit after compaction fails with `ContextBudgetExhausted`.
