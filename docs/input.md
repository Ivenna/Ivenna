# Runtime user messages

This contract defines runtime-generated `role=user` messages within the LLM conversation: retained observations and handovers, current execution facts, and inference purpose. Native model output and tool replies retain their own roles and formats. See [message assembly](architecture.md#working-history-and-user-messages).

The [Input definitions](../packages/agent/src/input.zig) define fields. All focuses use the same [system prompt](../packages/agent/src/system.md), which explains model interpretation; current state and available tools identify each focus's circumstances and possible actions.

## Records and turns

The interfaces have two lifetimes:

| Interface | Shape | Lifetime and meaning |
| --- | --- | --- |
| `Input.Record` | Either `events` or `handover` | Delivered observations or condensed understanding retained in working history |
| `Input.Turn` | `current` and `purpose` together | Fresh execution facts and purpose for one inference |

A turn's `purpose` selects either `work`, containing newly delivered `events`, or `summarize`, containing summary `instructions`. Current state accompanies either purpose. Admitted observations are stored as records, separately from the turn's temporary state and purpose.

`Text` denotes a free-form string. Tagged unions, including events, serialize as a mapping containing one branch name and its payload. Focus roles serialize as enum values, `core` or `activity`.

Focus references remain stable across waiting, context unloading, and restart. Finished activities leave the roster, and their references are not reused. Records identify the focus that admitted observations or produced a handover; a turn's `current.focus_id` identifies the focus performing this inference. Inherited records keep their original focus references, which can differ from the focus now reading them.

Tools that create focuses, commands, or attention arrangements take a short `name`. The runtime appends a number to produce a complete reference such as `practice-2`. Names may repeat; complete references establish identity. Callback references connect an arrangement with its pending state and arriving observation. Command references identify executions and remain control handles only within their originating runtime.

## Retained records

`Input.Record` selects `events` or `handover` and renders as a YAML user message. These records and complete native model/tool exchanges form the focus's working history. Past turns' temporary state and purpose are not retained. See [persistent working history](architecture.md#persistent-working-history) for storage encoding and checkpoints.

### Event groups

An `events` record has `focus_id: Text` and `items: Event[]`. Each admission retains one group. When delivered directly in a work turn, its items appear in `purpose.work.events` without duplicating the record in that request's prefix. Later history keeps the record without transient state. If compaction runs first, the handover instead carries the admitted observations. See [admission](architecture.md#activation-admission).

`Event` selects one branch:

| Branch | Payload | Meaning |
| --- | --- | --- |
| `startup` | `Startup` | Observation that a new runtime has begun |
| `input` | `IncomingMessage` | Observation of what correspondents said |
| `assignment` | `Assignment` | Initial work for a newly opened activity focus |
| `activity` | `ActivityReport` | One activity's newly admitted messages and ending information |
| `focus_message` | `FocusMessage` | Observation sent directly by the core |
| `callback` | `Callback` | A registered wakeup or host completion observation |

#### Incoming messages

Correspondence enters the core as an `input` observation of who said what; it implies no response obligation.

| Field | Type | Meaning |
| --- | --- | --- |
| `from` | `Text[]` | IDs of correspondents this message came from |
| `text` | `Text` | Complete message text |
| `observed_at_unix_ms` | `i64` | Runtime observation time in Unix milliseconds |

`from` contains readable [correspondent IDs](communication.md#correspondents-and-ids) accepted by `send_message`. The observation time is sampled during intake, rather than when the correspondent wrote or sent the message. Restoring history preserves that time.

#### Startup and restart

`Startup` carries `observed_at_unix_ms: i64`, the beginning of this runtime. The core and focuses with interrupted activations or unread internal observations receive startup immediately; dormant activities receive it when an event arrives. New activities start with an assignment. See [startup and interruption](architecture.md#startup-and-interruption).

#### Assignments and reports

An `Assignment` has `task: Text`, specifying what the activity should pursue within its inherited understanding. It is the activity's first new queued observation after [opening that focus](attention.md#opening-a-focus).

An `ActivityReport` groups newly admitted information from one activity:

| Field | Type | Meaning |
| --- | --- | --- |
| `from_focus` | `Text` | Source activity focus |
| `messages` | `ActivityMessage[]` | New assistant texts from this activity, in recorded order |
| `ended_at_unix_ms` | `?i64` | Time the runtime established focus completion, or `null` when this report includes no ending |

Each `ActivityMessage` has `text: Text` and `observed_at_unix_ms: i64`. The time records when the runtime collected the complete model response, before its tools execute. It does not date the events described in the text. Message and ending times use Unix milliseconds.

All three report fields are present. Messages and an ending can appear in the same report. An ending without further unread text has `messages: []` and a non-null `ended_at_unix_ms`; earlier admitted texts are not repeated. An explicitly empty assistant text remains a message with `text: ""`. A report with no messages and a null ending is omitted. A null ending means only that this report contains no ending; it does not establish that the source focus is still running.

Each ordinary activity inference that returns assistant text produces one message. Absent text records no message. Reasoning, tool replies, compaction output, and inherited history do not produce new messages. The text records what the activity expressed, not whether its proposed actions took effect.

One ordinary core input, including a tool continuation, can contain ordinary events and reports from several activities. Newly admitted messages for the same focus are grouped once, and groups follow the focus's first appearance in the selected observations. Each focus's message order and recorded times are preserved; the grouping does not encode the order between focuses. Persistence, restart, and later admission preserve the original message and ending times. The encoded request budget determines how much can enter one input.

Text alone does not activate the core. An ending does, even without new text, and establishes [focus completion](attention.md#activity-completion), not task success. Admission retains these observations in the core's history. Unadmitted information remains available for later admission.

#### Focus messages and callbacks

The core's `send_focus_message` produces a `FocusMessage`:

| Field | Type | Meaning |
| --- | --- | --- |
| `from_focus` | `Text` | Sending core focus, supplied by the runtime |
| `observed_at_unix_ms` | `i64` | Time the runtime accepted the message |
| `text` | `Text` | Observation or coordination message |

A focus message preserves its actual sender and enters the selected recipient's ordinary event queue. It can resume a sleeping recipient. It does not create a callback registration or arrange a reply.

Registered observations arrive as `Callback` events for the focuses that arranged them:

| Field | Type | Meaning |
| --- | --- | --- |
| `callback_id` | `Text` | Complete reference returned when the observation was arranged |
| `source` | `Source` | `wakeup` or `host` with the originating `command_id` |
| `observed_at_unix_ms` | `i64` | Time the runtime observed the callback |
| `text` | `Text` | Supplied wakeup text or serialized host result or diagnostic |

A callback's observation time is sampled during intake, rather than at the wakeup deadline or host command's completion.

The ID matches the `callback_id` returned by `schedule_attention` or a `run_host_shell` handoff result. `Source` is a tagged union: `wakeup: {}` identifies a scheduled wakeup, while `host: {command_id: "build-17"}` identifies a host execution. Command and callback references are independent; a host completion callback uses the command's name as its prefix. The runtime supplies the source from the saved registration. See [callback delivery](attention.md#callback-observations) for destination retention and admission guarantees, and [host results](host.md#output-and-results) for the callback text's format.

A restored host source can identify an execution in an earlier runtime; its command ID is not a restored control handle. See [command lifetimes](host.md#command-lifetimes) for stored results and interruption observations after restart.

### Handovers

A `handover` record has `focus_id: Text` and `summary: Text`. Compaction replaces earlier working history with this retained understanding:

```yaml
handover:
  focus_id: core-1
  summary: Keep each practice session to 20 minutes, including ten minutes of listening.
```

Compaction preserves the focus's identity and role. A handover's `focus_id` identifies its producing focus, including when inherited by an activity. Retention of earlier storage records follows the separate [history lifecycle](architecture.md#history-retention).

## Inference turns

Each inference ends its input with a turn containing both fields:

| Field | Type | Meaning |
| --- | --- | --- |
| `current` | `Current` | Current focus identity, role, observation time, pending callbacks, and roster |
| `purpose` | Tagged union | Ordinary work with delivered events, or summarization with instructions |

`purpose` selects one branch:

| Branch | Payload | Meaning |
| --- | --- | --- |
| `work` | `events: Event[]` | Continue ordinary work with these new observations |
| `summarize` | `instructions: Text` | Generate a handover from the complete retained message sequence |

`work.events` can be empty while continuing work after a tool exchange. The turn still supplies fresh current state. Activity text and runtime state changes do not independently schedule the core; a report with a non-null `ended_at_unix_ms` does.

### Current focus and roster

`Current` contains:

| Field | Type | Meaning |
| --- | --- | --- |
| `focus_id` | `Text` | Complete reference of the focus performing this inference |
| `role` | `Role` | Enum value `core` or `activity` |
| `observed_at_unix_ms` | `i64` | Time of this snapshot in Unix milliseconds |
| `callbacks` | `PendingCallback[]` | Observations arranged for this focus and awaiting admission |
| `focuses` | `FocusInfo[]` | Roster of all currently addressable focuses |

The snapshot is complete for these fields. Its observation time dates the snapshot, not the events delivered alongside it. Other focuses can act after sampling. Each `FocusInfo` contains:

| Field | Type | Meaning |
| --- | --- | --- |
| `focus_id` | `Text` | Complete stable focus reference |
| `role` | `Role` | `core` or `activity` |
| `status` | `running`, `waiting_for_tools`, `ready`, or `dormant` | Advancing an activation, waiting for tool replies, ready for scheduling, or sleeping |
| `queued_inputs` | `usize` | Queued events that require input for this focus, including activity endings for the core; excludes passive assistant reports |
| `pending_callbacks` | `usize` | Observations awaiting admission to this focus's history |

Queue counts exclude the current admission batch. A callback stays pending even after its result is published or queued; it leaves the list and count when its observation is admitted to history. Each `callbacks` item has `callback_id: Text` and `source: Source`. The complete reference links it to its arrangement in retained messages or a handover; the observation's text arrives separately as an event. A pending host source identifies the execution being observed; it does not imply that its process is still running or its handle remains available.

`ready` means work is waiting, subject to scheduling and capacity. Unread assistant reports alone do not make the core ready.

`waiting_for_tools` retains the current activation and context. Other focuses can advance, while new observations for this focus wait for the complete model/tool round.

For example, an ordinary core inference can receive a new observation with its current state:

```yaml
current:
  focus_id: core-1
  role: core
  observed_at_unix_ms: 1793966401000
  callbacks: []
  focuses:
    - focus_id: core-1
      role: core
      status: running
      queued_inputs: 0
      pending_callbacks: 0
purpose:
  work:
    events:
      - input:
          from: [operator]
          text: Keep each practice session to 20 minutes.
          observed_at_unix_ms: 1793966401000
      - activity:
          from_focus: practice-2
          messages:
            - text: The practice outline is ready.
              observed_at_unix_ms: 1793966400000
          ended_at_unix_ms: 1793966400500
      - activity:
          from_focus: vocabulary-3
          messages: []
          ended_at_unix_ms: 1793966400600
```

## Handover generation and replacement

A maintenance inference receives the common system prompt, retained user records and native model/tool exchanges, and a turn with `current` and `purpose.summarize.instructions`. Tools are disabled. The handover instructions come from [compaction.md](../packages/agent/src/compaction.md); events and activity reports waiting for admission remain outside this request.

A handover is accepted when it contains nonblank text without tool calls and the resulting ordinary request or admission candidate fits the request budget. If the first attempt fails these checks, the runtime makes one further summary inference over the original retained history. Retry feedback appears in `purpose.summarize.instructions`; both requests use the same system prompt and retained history. Rejected output never becomes a retained record.

An accepted handover replaces the working history. The next ordinary request assembles the same system prompt, the `handover` record, and a fresh work turn. Focus identity and role persist. If both attempts fail, the earlier history and unadmitted observations remain intact and execution stops. See [bounded model context](architecture.md#bounded-model-context) for generation, replacement, and admission budgets.
