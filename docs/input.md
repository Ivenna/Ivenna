# Runtime user messages

The agent renders retained events, handovers, and inference turns as YAML messages with the `user` role. This guide defines those messages and their fields. See [message assembly](architecture.md#working-history-and-user-messages).

Tools return their own text, images, and files. When the Responses adapter uses a user-role message to present an uploaded file, it identifies the tool call that supplied it. See [tool content](content.md) and [how tool results are encoded](architecture.md#tool-results).

All focuses use the same system prompt. The focus's current identity, observations, and available tools describe its own circumstances and possible actions. See the [input definitions and renderers](../packages/agent/src/input.zig) and the [system prompt](../packages/agent/src/system.md).

## Records and turns

| Interface | Shape | Lifetime and meaning |
| --- | --- | --- |
| `Input.Record` | `events` or `handover` | Observations and handovers retained in working history |
| `Input.Turn` | `current` with optional `events`, or `current` with `summarize` | Current identity, observation time, and input for one inference |

Newly admitted events enter working history as records. The runtime also retains complete model/tool exchanges when their rounds commit.

`Text` denotes a string. `Time` denotes a UTC RFC 3339 string with millisecond precision, such as `2026-11-06T12:00:01.000Z`. Records, events, and callback sources serialize as mappings containing one branch name and its payload. Focus roles serialize as enum values, `core` or `activity`.

Retained records identify the focus that admitted their events or produced their handover. Inherited records keep that focus ID. The turn's `current.focus_id` identifies the focus performing the current inference.

## Names and references

The `name` supplied when opening a focus, running a command, scheduling attention, subscribing, or creating a feed contains one to 32 Unicode code points, excludes ASCII controls, and includes at least one character besides an ASCII space. The runtime appends a numeric suffix, as in `practice-2`, so repeated names within a resource type produce distinct IDs.

Use the complete ID to identify the item. Focus IDs remain stable across waiting, context unloading, and restart. Ending an activity retires its ID permanently. A callback ID connects the arrangement, sampled pending state, and eventual observation. Command IDs remain usable as control handles within their originating runtime.

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
| `focus_message` | `FocusMessage` | Explicit message from a focus |
| `focus_interrupted` | `FocusInterrupted` | Runtime observation that an activity could not continue reasoning |
| `callback` | `Callback` | A registered wakeup or host completion observation |
| `subscription` | `SubscriptionReport` | A listener's report to the focus that subscribed |

#### Incoming messages

Correspondence enters the core as an `input` observation of who said what.

| Field | Type | Meaning |
| --- | --- | --- |
| `from` | `Text[]` | Correspondent IDs of the senders |
| `text` | `Text` | Complete message text |
| `observed_at` | `Time` | Time the runtime observed the message during intake |

The sender IDs attribute the observation. Outgoing correspondence uses registered recipients. See [correspondents and IDs](communication.md#correspondents-and-ids) and [how email text is presented](communication.md#incoming-email-text).

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

One ordinary core input, including a tool continuation, can contain events and reports from several activities. Newly admitted messages for the same focus are grouped once. Each group's position follows that focus's first appearance in the selected observations, and messages within it keep their original order. Use the observation times for messages and endings from different focuses. Those times survive waiting, persistence, and restart.

See [activity expressions](attention.md#activity-expressions) for when the core reads these messages and [activity completion](attention.md#activity-completion) for what an ending means.

#### Activity interruptions

The runtime sends the core a `focus_interrupted` event when an activity has to pause reasoning.

| Field | Type | Meaning |
| --- | --- | --- |
| `focus_id` | `Text` | Activity whose reasoning was interrupted |
| `observed_at` | `Time` | Time the runtime recorded the interruption |
| `reason` | `Text` | Runtime explanation of why the activity could not continue |

The activity may have resumed or even ended by the time the core reads the event. See [interrupted reasoning](attention.md#interrupted-reasoning) for how an activity resumes.

#### Focus messages and callbacks

A successful `send` to a focus queues a `FocusMessage`.

| Field | Type | Meaning |
| --- | --- | --- |
| `from_focus` | `Text` | Sending focus's `focus_id`, supplied by the runtime |
| `observed_at` | `Time` | Time the runtime accepted the message |
| `text` | `Text` | Observation or coordination message |

See [reaching an existing focus](attention.md#reaching-an-existing-focus) for queueing and delivery behavior.

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

Each `subscription` event carries one listener report to the focus that subscribed. Reports for that focus appear in acceptance order across its subscriptions.

| Field | Type | Meaning |
| --- | --- | --- |
| `subscription_id` | `Text` | ID returned by `subscribe`, shared by all reports for that subscription |
| `observed_at` | `Time` | Time recorded by `ivenna subscription publish` before saving the report |
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

The runtime supplies `summarize.state` for compaction and carries the same sample into the accepted `handover.state` alongside the model's summary. The corresponding `observed_at` dates the sample. Retained and inherited handovers keep their focus IDs, observation times, and samples.

| Field | Type | Core sample | Activity sample |
| --- | --- | --- | --- |
| `activities` | `Text[]` | IDs of existing activities, including sleeping and interrupted ones | — |
| `callbacks` | `PendingCallback[]` | Core's pending callbacks | This activity's pending callbacks |
| `subscriptions` | `Text[]` | Core's active subscription IDs | This activity's active subscription IDs |
| `feeds` | `Text[]` | IDs of open feeds created by the core or by activities that have ended | IDs of open feeds created by this activity |
| `correspondents` | `Text[]` | Registered outgoing correspondent IDs | — |

The renderer omits empty collections and omits `state` when every collection is empty. An activity's open feed can appear in a core sample once the activity ends, even while its ending observation is still queued. The sample draws from feeds that are open when queried. Readers can still access closed feeds by ID. See [activity completion](attention.md#activity-completion) and [reading feeds](communication.md#reading-feeds).

Active subscriptions include listeners that have yet to report. A report accepted before withdrawal can arrive after the ID has dropped out of a new sample.

Each `PendingCallback` contains `callback_id: Text` and `source: Source`. A callback remains pending until its observation enters the history of the focus that arranged it, including after the result is published or queued. A pending host source can identify a command that has already finished. Observation text arrives separately as an event. See [command lifetimes](host.md#command-lifetimes) for handle availability.

In this handover, the summary carries the reason to revisit the practice plan, and `state` carries the scheduled callback's ID and source.

```yaml
handover:
  focus_id: core-1
  observed_at: "2026-11-06T12:00:01.000Z"
  summary: A 20-minute practice outline is being prepared. Revisit the plan tomorrow.
  state:
    activities: [practice-2]
    callbacks:
      - callback_id: revisit-practice-5
        source:
          wakeup: {}
    subscriptions: [release-watch-1]
    feeds: [practice-updates-1]
    correspondents: [operator]
```

## Inference turns

Each inference ends its input with a turn.

| Field | Type | Meaning |
| --- | --- | --- |
| `current` | `Current` | Identity, role, and observation time |
| `events` | `Event[]`, when nonempty | New events for an ordinary inference |
| `summarize` | `instructions: Text` and optional `state: State` | Compaction request with any sampled state |

`current` has the same fields in ordinary and compaction turns.

| Field in `current` | Type | Meaning |
| --- | --- | --- |
| `focus_id` | `Text` | ID of the focus receiving the turn |
| `role` | `Role` | `core` or `activity` |
| `observed_at` | `Time` | Time the runtime sampled this turn |

An ordinary turn with no new events contains only `current`. The retained prefix can still include an earlier [state sample](#sampled-state) in a handover.

In this ordinary turn, a letter from `reviewer` and a release report reach the core together. See [incoming messages](#incoming-messages) and [how a listener reports observations](subscriptions.md#publish-an-observation).

```yaml
current:
  focus_id: core-1
  role: core
  observed_at: "2026-11-10T18:00:01.000Z"
events:
  - input:
      from:
        - reviewer
      observed_at: "2026-11-10T18:00:00.500Z"
      text: Please include changes to the example configuration in the release notes.
  - subscription:
      subscription_id: release-watch-1
      observed_at: "2026-11-10T17:59:59.200Z"
      text: Stable release v2.4.0 is available
```

## Handover generation and replacement

A compaction request contains the common system prompt, the history to summarize, and a turn with `current` and `summarize`. The [handover instructions](../packages/agent/src/compaction.md) ask for a plain-text summary. Tools are disabled, and observations awaiting admission stay queued. A tool result in this request can contain a short omission notice in place of an attachment. The result keeps its existing text, including any source description. If the runtime requests a revised summary, `summarize.instructions` includes the reason for revision.

An accepted summary becomes a `handover` with the sampled state and observation time of that attempt. The next ordinary request presents the handover, any observations and complete exchanges carried forward from the earlier history, and a turn with the focus's current identity, time, and newly admitted events.

See [bounded model context](architecture.md#bounded-model-context) for which history is summarized or carried forward and when a handover replaces it.
