# Runtime user messages

This contract defines the agent's runtime-generated `role=user` messages: retained events, handovers, and inference turns. Native model output and tool replies are encoded separately by the model adapter; [tool content](content.md) describes the text, images, and files returned by tools. See [message assembly](architecture.md#working-history-and-user-messages).

The [Input definitions and renderers](../packages/agent/src/input.zig) own the data and its model-facing presentation. All focuses use the same [system prompt](../packages/agent/src/system.md), which explains model interpretation; current identity, observations, and available tools identify each focus's circumstances and possible actions.

## Records and turns

The interfaces have two lifetimes:

| Interface | Shape | Lifetime and meaning |
| --- | --- | --- |
| `Input.Record` | `events` or `handover` | Observations and handovers retained in working history |
| `Input.Turn` | `current`, with observations or `summarize` | Current identity, observation time, and input for one inference |

An ordinary turn contains `current` and any newly delivered `events`. A compaction turn contains `current` and `summarize`, which asks for a summary and supplies sampled state for recollection. The runtime records admitted events and complete model/tool exchanges in working history.

`Text` denotes a free-form string. `Time` denotes a UTC RFC 3339 string with millisecond precision, such as `2026-11-06T12:00:01.000Z`. Records, events, and callback sources serialize as mappings containing one branch name and its payload. Focus roles serialize as enum values, `core` or `activity`.

Focus references remain stable across waiting, context unloading, and restart; ended activity references are not reused. Retained records identify the focus that admitted their events or produced their handover. A turn's `current.focus_id` identifies the focus performing this inference. Inherited records keep their original focus references, which can differ from the focus now reading them.

Tools that create focuses, commands, or attention arrangements take a short `name`. The runtime appends a number to produce a complete reference such as `practice-2`. Names may repeat; complete references establish identity. Callback references connect an arrangement with its pending state and arriving observation. Command references identify executions and remain control handles only within their originating runtime.

## Retained records

Retained records render as YAML user messages. Together with complete native model/tool exchanges, they form the focus's working history. See [persistent working history](architecture.md#persistent-working-history) for storage encoding and checkpoints.

### Event groups

An `events` record has `focus_id: Text` and `items: Event[]`. Each admission retains one group. Its first ordinary turn presents the new observations in `events`. Later requests carry that group in history. If earlier history needs compaction during admission, the handover represents that history and the new observations still appear in the turn. See [admission](architecture.md#activation-admission).

`Event` selects one branch:

| Branch | Payload | Meaning |
| --- | --- | --- |
| `startup` | `Startup` | Observation that a new runtime has begun |
| `input` | `IncomingMessage` | Observation of what correspondents said |
| `assignment` | `Assignment` | Initial work for a newly opened activity focus |
| `activity` | `ActivityReport` | One activity's newly admitted messages and ending information |
| `focus_message` | `FocusMessage` | Observation sent directly by the core |
| `focus_interrupted` | `FocusInterrupted` | Runtime observation that an activity could not continue reasoning |
| `callback` | `Callback` | A registered wakeup or host completion observation |
| `subscription` | `SubscriptionReport` | A listener's report to the focus that subscribed |

#### Incoming messages

Correspondence enters the core as an `input` observation of who said what; it implies no response obligation.

| Field | Type | Meaning |
| --- | --- | --- |
| `from` | `Text[]` | IDs of correspondents this message came from |
| `text` | `Text` | Complete message text |
| `observed_at` | `Time` | Runtime observation time |

`from` contains readable [correspondent IDs](communication.md#correspondents-and-ids) accepted by `send_message`. The observation time is sampled during intake, rather than when the correspondent wrote or sent the message. Restoring history preserves that time.

#### Startup and restart

`Startup.observed_at` records the time the runtime started. The runtime queues this event on restart for the core and for each activity with an unfinished activation or unread internal observations. For other restored activities it queues the event when they next have work. Newly opened activities start with an assignment. See [startup and interruption](architecture.md#startup-and-interruption).

#### Assignments and reports

An `Assignment` has `task: Text`, specifying what the activity should pursue within its inherited understanding. It is the activity's first new queued observation after [opening that focus](attention.md#opening-a-focus).

An `ActivityReport` groups newly admitted information from one activity:

| Field | Type | Meaning |
| --- | --- | --- |
| `from_focus` | `Text` | Source activity focus |
| `messages` | `ActivityMessage[]`, when nonempty | New assistant texts from this activity, in recorded order |
| `ended_at` | `Time`, when present | Time the runtime established focus completion |

Each `ActivityMessage` has `text: Text` and `observed_at: Time`. The time records when the runtime collected the complete model response, before its tools execute. It does not date the events described in the text. Message and ending times use the same UTC calendar format.

Messages and an ending can appear in the same report. An ending without further unread text omits `messages`; earlier admitted texts are not repeated. An explicitly empty assistant text remains a message with `text: ""`. Each report includes at least one message or an ending. An omitted `ended_at` means only that this report contains no ending; it does not establish that the source focus is still running.

Each ordinary activity inference that returns assistant text produces one message. Absent text records no message. Reasoning, tool replies, compaction output, and inherited history do not produce new messages. The text records what the activity expressed, not whether its proposed actions took effect.

One ordinary core input, including a tool continuation, can contain ordinary events and reports from several activities. Newly admitted messages for the same focus are grouped once, and groups follow the focus's first appearance in the selected observations. Each focus's message order and recorded times are preserved; the grouping does not encode the order between focuses. Persistence, restart, and later admission preserve the original message and ending times. The encoded request budget determines how much can enter one input.

The attention guide explains when the core reads these messages and what an ending means. See [activity expressions](attention.md#activity-expressions) and [activity completion](attention.md#activity-completion).

#### Activity interruptions

The runtime sends the core a `focus_interrupted` event when an activity has to pause reasoning.

| Field | Type | Meaning |
| --- | --- | --- |
| `focus_id` | `Text` | Activity whose reasoning was interrupted |
| `observed_at` | `Time` | Time the runtime recorded the interruption |
| `reason` | `Text` | Runtime explanation of why the activity could not continue |

The activity may have resumed or even ended by the time the core reads the event. See [interrupted reasoning](attention.md#interrupted-reasoning) for how an activity resumes.

#### Focus messages and callbacks

The core's `send_focus_message` produces a `FocusMessage`:

| Field | Type | Meaning |
| --- | --- | --- |
| `from_focus` | `Text` | Sending core focus, supplied by the runtime |
| `observed_at` | `Time` | Time the runtime accepted the message |
| `text` | `Text` | Observation or coordination message |

A focus message enters the selected recipient's ordinary event queue. See [reaching an existing focus](attention.md#reaching-an-existing-focus) for when the recipient can read it.

Registered observations arrive as `Callback` events for the focuses that arranged them:

| Field | Type | Meaning |
| --- | --- | --- |
| `callback_id` | `Text` | Complete reference returned when the observation was arranged |
| `source` | `Source` | `wakeup` or `host` with the originating `command_id` |
| `observed_at` | `Time` | Time the runtime observed the callback |
| `text` | `Text` | Supplied wakeup text or serialized host result or diagnostic |

A callback's observation time is sampled during intake, rather than at the wakeup deadline or host command's completion.

The ID matches the `callback_id` returned by `schedule_attention` or a `run_host_shell` handoff result. `Source` is a tagged union: `wakeup: {}` identifies a scheduled wakeup, while `host: {command_id: "build-17"}` identifies a host execution. Command and callback references are independent; a host completion callback uses the command's name as its prefix. The runtime supplies the source from the saved registration. Host completion text omits the result's `command_id` field; the association is supplied by `source.host.command_id`. See [callback delivery](attention.md#callback-observations) for destination retention and admission guarantees, and [host results](host.md#output-and-results) for the callback text's format.

A restored host source can identify an execution in an earlier runtime; its command ID is not a restored control handle. See [command lifetimes](host.md#command-lifetimes) for stored results and interruption observations after restart.

#### Subscription observations

Each `subscription` event carries one listener report addressed to the focus that subscribed. A turn can carry reports from several subscriptions or several reports from one subscription.

| Field | Type | Meaning |
| --- | --- | --- |
| `subscription_id` | `Text` | Complete reference returned at registration |
| `observed_at` | `Time` | Time the local reporter received the submission |
| `source_time` | `Time`, when supplied | Time the listener attributes to the upstream event |
| `text` | `Text` | Listener's account of what it observed |

The listener can include a source link, a revision, or a gap in coverage in `text`. See [subscription delivery and withdrawal](attention.md#subscriptions).

### Handovers

A `handover` record contains:

| Field | Type | Meaning |
| --- | --- | --- |
| `focus_id` | `Text` | Focus that produced this handover |
| `observed_at` | `Time` | Observation time of the state supplied to summarization |
| `summary` | `Text` | Understanding generated by the model |
| `state` | `State`, when nonempty | Program-owned state sampled for that summary inference |

#### Sampled state

A `State` can contain the following collections:

| Field | Type | Meaning |
| --- | --- | --- |
| `activities` | `Text[]` | Complete references of the core's existing activities, including sleeping activities |
| `callbacks` | `PendingCallback[]` | Observations arranged for the sampled focus and awaiting admission |
| `subscriptions` | `Text[]` | Complete references of the subscriptions active for this focus at the time of the sample, including those whose listeners have never reported |

The activity list omits the core itself and is empty for an activity focus. Empty collections are omitted. When all collections are empty, the entire `state` field is omitted.

A subscription withdrawn before the sample is absent from `subscriptions`. A report accepted before withdrawal can still arrive with that ID.

Each `PendingCallback` contains `callback_id: Text` and `source: Source`. A callback remains pending until its observation enters the history of the focus that arranged it, including after its result is published or queued. A pending host source identifies the execution being observed; it does not imply that its process is still running or its handle remains available. Observation text arrives separately as an event. The runtime routes and resumes registered observations without requiring the model to retain their IDs.

The handover's `observed_at`, or the compaction turn's `current.observed_at`, dates this state sample. An activity can end before its ending report enters the core's history, so a later sample can omit an activity whose ending has not yet been admitted. Reports retain their source and original times. Sending a focus message to an activity that has ended returns [`unknown_focus`](attention.md#results-and-errors).

For example, the summary can explain the work while sampled state retains the references:

```yaml
handover:
  focus_id: core-1
  observed_at: "2026-11-06T12:00:01.000Z"
  summary: A 20-minute practice outline is being prepared. Revisit the plan when it arrives.
  state:
    activities: [practice-2]
    subscriptions: [releases-1]
    callbacks:
      - callback_id: revisit-practice-5
        source:
          wakeup: {}
```

The runtime carries sampled state independently of the generated summary. Inherited handovers keep their producing focus. Earlier storage records follow the separate [history lifecycle](architecture.md#history-retention).

## Inference turns

Each inference ends its input with a turn:

| Field | Type | Meaning |
| --- | --- | --- |
| `current` | `Current` | Identity, role, and observation time of the focus performing this inference |
| `events` | `Event[]`, when nonempty | New events for an ordinary inference |
| `summarize` | Summary instructions and optional state | Compaction request, replacing ordinary observations |

`Current` contains `focus_id: Text`, `role: Role`, and `observed_at: Time`. Its time dates the current inference input. Events and handovers keep their own observation times and sources. A historical record's focus can differ from the focus identified by `current`.

An ordinary turn with no new events contains only `current` and continues from the preceding history.

`summarize` contains `instructions: Text` and, when nonempty, complete `state: State`. It asks for condensed understanding with current state available for recollection. Events waiting for admission remain outside this request.

For example, the [scheduled wakeup](attention.md#returning-later) and the [release listener's report](subscriptions.md#publish-an-observation) can reach the core in the same turn.

```yaml
current:
  focus_id: core-1
  role: core
  observed_at: "2026-11-10T18:00:01.000Z"
events:
  - callback:
      callback_id: revisit-practice-5
      source:
        wakeup: {}
      observed_at: "2026-11-10T18:00:00.500Z"
      text: Revisit the French practice plan.
  - subscription:
      subscription_id: releases-1
      observed_at: "2026-11-10T17:59:59.200Z"
      text: Stable release v2.4.0 is available
```

Each event carries the reference returned by the tool that arranged it. The release report gives the reporter's local receipt time. The listener supplied no source time, so the event omits `source_time`.

## Handover generation and replacement

A compaction inference receives the common system prompt, complete retained history, and a turn with `current` and `summarize`. Tools are disabled. Observations awaiting admission remain outside the request. The [handover instructions](../packages/agent/src/compaction.md) ask for a plain-text summary of the understanding and unfinished work worth carrying forward.

When the runtime asks for a revised summary, `summarize.instructions` explains what needs to change. The model sees the original history again. Only an accepted summary enters history, paired with the state and observation time supplied to that inference. The next ordinary turn adds its own identity, time, and newly admitted events.

See [bounded model context](architecture.md#bounded-model-context) for the acceptance checks, retry conditions, and handling of an input that still cannot fit.
