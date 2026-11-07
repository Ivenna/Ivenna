# Runtime user messages

This contract defines runtime-generated `role=user` messages within the LLM conversation: retained observations and handovers, current execution facts, and inference purpose. Native model output and tool replies retain their own roles and formats. See [message assembly](architecture.md#working-history-and-user-messages).

The [Input definitions](../packages/agent/src/input.zig) define fields and the [system prompt](../packages/agent/src/system.md) explains model interpretation.

## Records and turns

The interfaces have two lifetimes:

| Interface | Shape | Lifetime and meaning |
| --- | --- | --- |
| `Input.Record` | Either `events` or `handover` | Delivered observations or condensed understanding retained in working history |
| `Input.Turn` | `current` and `purpose` together | Fresh execution facts and purpose for one inference |

A turn's `purpose` selects either `work`, containing newly delivered `events`, or `summarize`, containing summary `instructions`. Current state accompanies either purpose. Admitted observations are stored as records, separately from the turn's temporary state and purpose.

`Text` denotes a free-form string. Tagged unions, including events, serialize as a mapping containing one branch name and its payload. Session roles serialize as enum values, `core` or `activity`.

Session IDs remain registered across sleep, context unloading, and restart. Records identify the session that admitted observations or produced a handover; a turn's `current.session_id` identifies the session performing this inference. Inherited records keep their original session IDs, which can differ from the session now reading them.

## Retained records

`Input.Record` selects `events` or `handover` and renders as a YAML user message. These records and complete native model/tool exchanges form the session's working history. Past turns' temporary state and purpose are not retained. See [persistent working history](architecture.md#persistent-working-history) for storage encoding and checkpoints.

### Event groups

An `events` record has `session_id: u64` and `items: Event[]`. Each admission retains a FIFO group. When delivered directly in a work turn, its items appear in `purpose.work.events` without duplicating the record in that request's prefix. Later history keeps the record without transient state. If compaction runs first, the handover instead carries the admitted observations. See [admission](architecture.md#activation-admission).

`Event` selects one branch:

| Branch | Payload | Meaning |
| --- | --- | --- |
| `startup` | `Startup` | Observation that a new runtime has begun |
| `input` | `IncomingMessage` | Observation of what correspondents said |
| `assignment` | `Assignment` | Initial work for a newly created activity session |
| `report` | `Report` | An activity activation's final text, delivered to the core |
| `session_message` | `SessionMessage` | Observation sent directly by the core |
| `callback` | `Callback` | A registered host completion or self-scheduled wakeup |

#### Incoming messages

Correspondence enters the core as an `input` observation of who said what; it implies no response obligation.

| Field | Type | Meaning |
| --- | --- | --- |
| `from` | `Text[]` | IDs of correspondents this message came from |
| `text` | `Text` | Complete message text |
| `observed_at_unix_ms` | `i64` | Runtime observation time in Unix milliseconds |

`from` contains readable [correspondent IDs](communication.md#correspondents-and-ids) accepted by `send_message`. Restoring history preserves the original observation time.

#### Startup and restart

`Startup` carries `observed_at_unix_ms: i64`, the beginning of this runtime. The core and sessions with interrupted activations or unread internal observations queue startup immediately; dormant activity sessions prepend it when an event arrives. New activity sessions start with an assignment. See [startup and interruption](architecture.md#startup-and-interruption).

#### Assignments and reports

An `Assignment` has `task: Text`, specifying what the activity should pursue within its inherited understanding. It is the activity's first new queued observation after the [fork](communication.md#forking-an-activity-session).

A `Report` delivers an activity activation's final text to the core automatically:

| Field | Type | Meaning |
| --- | --- | --- |
| `from_session` | `u64` | Activity session that produced the report |
| `text` | `Text` | Final text; may be empty |

#### Session messages and callbacks

The core's `send_session_message` produces a `SessionMessage`:

| Field | Type | Meaning |
| --- | --- | --- |
| `from_session` | `u64` | Sending core session, supplied by the runtime |
| `observed_at_unix_ms` | `i64` | Time the runtime accepted the message |
| `text` | `Text` | Observation or coordination message |

Background host completions and scheduled wakeups arrive as `Callback` observations for the sessions that invoked the host tool or scheduled the wakeup:

| Field | Type | Meaning |
| --- | --- | --- |
| `id` | `u64` | Registered callback identity |
| `source` | `host` or `wakeup` | Kind of event source |
| `observed_at_unix_ms` | `i64` | Time the runtime observed the callback |
| `text` | `Text` | Host outcome or the supplied wakeup text |

A host callback ID matches its `activity_id`; a wakeup ID matches its `callback_id`. Destinations survive sleep, context unloading, and restart. A registered callback ID is admitted at most once. Host results can report interrupted activity with unknown effects; see [background commands](host.md#background-commands) and [session communication](communication.md#session-communication-and-wakeups).

### Handovers

A `handover` record has `session_id: u64` and `summary: Text`. Compaction replaces earlier working history with this retained understanding:

```yaml
handover:
  session_id: 1
  summary: Keep each practice session to 20 minutes, including ten minutes of listening.
```

Compaction preserves the session's identity and role. A handover's `session_id` identifies its producing session, including when inherited by an activity. Retention of earlier storage records follows the separate [history lifecycle](architecture.md#history-retention).

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
| `session.role` | Enum value `core` or `activity` |
| `session.callbacks` | Pending callback registrations for this session |
| `runtime.observed_at_unix_ms` | Time of this snapshot in Unix milliseconds |
| `runtime.registered_sessions` | Registered sessions, including dormant sessions and the core |
| `runtime.running_sessions` | Sessions currently handling an activation |
| `runtime.queued_inputs` | Events waiting in session queues, excluding reserved report slots |
| `runtime.sessions` | `SessionInfo[]` roster for all registered sessions |

The snapshot is complete for these fields. Counts reflect admission: delivered callbacks are no longer pending, while queued events remain counted. Other sessions can act after sampling. Each `SessionInfo` contains:

| Field | Type | Meaning |
| --- | --- | --- |
| `session_id` | `u64` | Stable session ID |
| `role` | `Role` | `core` or `activity` |
| `status` | `running`, `ready`, or `dormant` | Executing, awaiting an activation, or sleeping |
| `queued_inputs` | `usize` | Events waiting in this session's queue |
| `pending_callbacks` | `usize` | Registrations awaiting admission to this session's history |
| `last_active_unix_ms` | `i64` | Most recent activation start or end; `0` before its first activation |

Each `session.callbacks` item is a `PendingCallback` with `id: u64`, `session_id: u64`, and `source` selecting `host` or `wakeup`. Its result text arrives separately as an event.

`ready` means work is waiting, subject to scheduling and capacity. Core attention can produce this status with `queued_inputs: 0`.

For example, an ordinary core inference can receive a new observation with its current state:

```yaml
current:
  session_id: 1
  state:
    session:
      role: core
      callbacks: []
    runtime:
      observed_at_unix_ms: 1793966401000
      registered_sessions: 1
      running_sessions: 1
      queued_inputs: 0
      sessions:
        - session_id: 1
          role: core
          status: running
          queued_inputs: 0
          pending_callbacks: 0
          last_active_unix_ms: 1793966401000
purpose:
  work:
    events:
      - input:
          from: [operator]
          text: Keep each practice session to 20 minutes.
          observed_at_unix_ms: 1793966401000
```

## Handover generation and replacement

A maintenance inference receives the retained LLM messages—the system prompt, user records, native model output, and tool replies—plus a turn with `current` and `purpose.summarize.instructions`. Tools are disabled. Instructions come from [compaction.md](../packages/agent/src/compaction.md); events waiting for admission remain outside this request, and core attention stays pending.

After the handover passes validation, it replaces the retained messages. The next ordinary request contains the system prompt, a `handover` record, and a fresh work turn. Session identity and role persist. See [bounded model context](architecture.md#bounded-model-context) for generation, replacement, and admission budgets.
