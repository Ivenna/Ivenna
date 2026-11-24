# Runtime user messages

The agent renders observations, handovers, and inference turns as YAML messages with the `user` role. The turn identifies the focus making the current inference. Retained records preserve their source and observation times. See [message assembly](architecture.md#working-history-and-user-messages).

Tools return their own text, images, and files. When the Responses adapter uses a user-role message to present an uploaded file, it identifies the tool call that supplied it. See [tool content](content.md) and [how tool results are encoded](architecture.md#tool-results).

All focuses use the same system prompt. The focus's current identity, observations, and available tools describe its own circumstances and possible actions. See the [input definitions and renderers](../packages/agent/src/input.zig) and the [system prompt](../packages/agent/src/system.md).

## Records and turns

| Interface | Shape | Lifetime and meaning |
| --- | --- | --- |
| [`Input.Record`](#retained-records) | `events` or `handover` | Observations and handovers retained in working history |
| [`Input.Turn`](#inference-turns) | `current` with optional `events`, or `current` with `summarize` | Focus identity and input for one inference |

Newly admitted events enter working history as records. The runtime also retains complete model/tool exchanges when their rounds commit.

`Text` denotes a string. `Time` denotes a UTC RFC 3339 string with millisecond precision, such as `2026-11-06T12:00:01.000Z`. Records, events, and callback sources are mappings with one key for the branch name and its payload as the value.

Retained records identify the focus that admitted their events or produced their handover. Inherited records keep that focus ID. The turn's `current.focus_id` identifies the focus performing the current inference.

## Names and references

The `name` supplied when opening a focus or channel, running a command, scheduling attention, or subscribing contains one to 32 Unicode code points, excludes ASCII controls, and includes at least one character besides an ASCII space. The runtime appends a numeric suffix, as in `practice-2`, so repeated names within a resource type produce distinct IDs.

Use the complete ID to identify the item. Focus IDs remain stable across waiting, context unloading, and restart. Ending an activity retires its ID permanently. A callback ID connects the arrangement, sampled pending state, and eventual observation. Command IDs control host commands. Channel IDs address open channels. Both are scoped to the issuing runtime.

## Retained records

Retained records and complete model/tool exchanges form the focus's working history. See [persistent working history](architecture.md#persistent-working-history) for storage encoding and checkpoints.

### Event groups

An `events` record has `focus_id: Text` and `items: Event[]`. The ordinary turn that admits the observations presents them in `events`. Later requests carry the admitted group in history. See [admission](architecture.md#activation-admission).

Each `Event` selects one branch.

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

#### Startup and restart

The core receives `startup` on first launch and every restart. The runtime resumes restored activities with unfinished activations or unread internal observations and gives them `startup` first. Other restored activities receive it when they next have work. Newly opened activities begin with an assignment. See [startup and interruption](architecture.md#startup-and-interruption).

| Field | Type | Meaning |
| --- | --- | --- |
| `observed_at` | `Time` | Time the runtime started |
| `correspondents` | `Text[]`, supplied to the core | All outgoing correspondent IDs registered for this runtime |

`correspondents: []` records an empty registration. An omitted field leaves registration unspecified. An activity can still see an earlier core list in inherited history. The latest dated list from startup or compaction gives the last observed registration. Sending checks the current registration when the tool runs. See [sampled state](#sampled-state) and [outgoing correspondence](communication.md#writing-to-a-correspondent).

#### Incoming messages

Correspondence enters the core as an `input` observation of who said what.

| Field | Type | Meaning |
| --- | --- | --- |
| `from` | `Text[]` | Correspondent IDs of the senders |
| `text` | `Text` | Complete message text |
| `observed_at` | `Time` | Time the runtime observed the message during intake |

Use `from` to attribute the observation. See [correspondents and IDs](communication.md#correspondents-and-ids) and [how email text is presented](communication.md#incoming-email-text).

#### Assignments and reports

An `Assignment` has `task: Text`, specifying what the activity should pursue within its inherited understanding. It is the activity's first new queued observation after [opening that focus](attention.md#opening-a-focus).

An `ActivityReport` groups a single activity's newly admitted messages and ending.

| Field | Type | Meaning |
| --- | --- | --- |
| `from_focus` | `Text` | Source activity focus |
| `messages` | `ActivityMessage[]`, when nonempty | New assistant texts from this activity, in recorded order |
| `ended_at` | `Time`, when present | Time the runtime established focus completion |

Each `ActivityMessage` has `text: Text` and `observed_at: Time`. The time dates the collection of the complete model response, before its tools execute.

Each report contains at least one message or an ending. When no unread messages accompany an ending, the report omits `messages`. An explicitly empty assistant text remains a message with `text: ""`. Use `ended_at` as evidence of completion when it appears.

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

#### Focus messages

A successful `send` to a focus queues a `FocusMessage`.

| Field | Type | Meaning |
| --- | --- | --- |
| `from_focus` | `Text` | Sending focus's `focus_id`, supplied by the runtime |
| `observed_at` | `Time` | Time the runtime accepted the message |
| `text` | `Text` | Observation or coordination message |

See [reaching an existing focus](attention.md#reaching-an-existing-focus) for queueing and delivery behavior.

#### Callback observations

Each `callback` carries a registered observation to the focus that arranged it.

| Field | Type | Meaning |
| --- | --- | --- |
| `callback_id` | `Text` | Complete reference returned when the observation was arranged |
| `source` | `Source` | `wakeup` or `host` with the originating `command_id` |
| `observed_at` | `Time` | Time the runtime observed the callback |
| `text` | `Text` | Supplied wakeup text or serialized host result or diagnostic |

A callback's observation time dates its intake. The wakeup deadline or command completion can be earlier.

The ID matches the `callback_id` returned by `schedule_attention` or a `run_host_shell` handoff. A source of `wakeup: {}` identifies a scheduled wakeup. A source of `host: {command_id: "build-17"}` identifies a host execution. A host completion's callback reference uses the command's name with its own numeric suffix. The runtime supplies the command ID in `source.host.command_id`. See [callback delivery](attention.md#callback-observations) and [host results](host.md#output-and-results).

A restored host source can identify an execution in an earlier runtime. The command ID serves as a control handle within the originating runtime. See [command lifetimes](host.md#command-lifetimes) for stored results and interruption observations after restart.

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

A `handover` record contains these fields.

| Field | Type | Meaning |
| --- | --- | --- |
| `focus_id` | `Text` | Focus that produced this handover |
| `observed_at` | `Time` | Observation time of the state supplied to summarization |
| `summary` | `Text` | The model's account of what to carry forward from the summarized history |
| `state` | `State`, when present | Runtime state sampled for that summary inference |

#### Sampled state

`current.observed_at` dates the state supplied in `summarize.state`. In an accepted handover, `observed_at` keeps that time and `state` keeps the supplied sample alongside the summary. Inherited handovers keep their original focus ID, time, and sample.

| Field | Type | Core sample | Activity sample |
| --- | --- | --- | --- |
| `activities` | `Text[]` | IDs of existing activities, including sleeping and interrupted ones | — |
| `callbacks` | `PendingCallback[]` | Core's pending callbacks | This activity's pending callbacks |
| `subscriptions` | `Text[]` | Core's active subscription IDs | This activity's active subscription IDs |
| `channels` | `Text[]` | All open channel IDs | IDs of channels opened by this activity that are still open |
| `correspondents` | `Text[]` | Registered outgoing correspondent IDs | — |

The core's `correspondents` list is present even when empty. The renderer omits other empty collections and omits `state` when it has no fields to render. See [startup and restart](#startup-and-restart) for how to interpret the list.

Active subscriptions include listeners that have yet to report. A report accepted before withdrawal can arrive after the ID has dropped out of a new sample.

The `channels` list reflects the sample time. A retained handover can still show an ID after its channel closes. A restart restores the channels its checkpoint recorded, so a retained ID can address an open channel again. See [channel send outcomes](communication.md#sending-to-a-channel).

Each `PendingCallback` contains `callback_id: Text` and `source: Source`. A callback remains pending until its observation enters the history of the focus that arranged it, including after the result is published or queued. A pending host source can identify a command that has already finished. Observation text arrives separately as an event. See [command lifetimes](host.md#command-lifetimes) for handle availability.

In this handover, the summary carries the practice plan forward. `state` keeps the wakeup reference alongside the other sampled IDs.

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
    channels: [task-input-18]
    correspondents: [operator]
```

## Inference turns

The last message of an inference input is the current turn.

| Field | Type | Meaning |
| --- | --- | --- |
| `current` | `Current` | Identity, role, and observation time |
| `events` | `Event[]`, when nonempty | New events for an ordinary inference |
| `summarize` | `instructions: Text` and optional `state: State` | Request for a handover summary with any sampled state |

`current` has the same fields in ordinary and compaction turns.

| Field in `current` | Type | Meaning |
| --- | --- | --- |
| `focus_id` | `Text` | ID of the focus receiving the turn |
| `role` | `Role` | `core` or `activity` |
| `observed_at` | `Time` | Time the runtime sampled this turn |

An ordinary turn with no new events contains only `current`. Retained events and [state samples](#sampled-state) keep their own dates.

In this restart turn, the core sees its outgoing registration and a release report queued before restart. See [how a listener reports observations](subscriptions.md#publish-an-observation).

```yaml
current:
  focus_id: core-1
  role: core
  observed_at: "2026-11-10T18:00:01.000Z"
events:
  - startup:
      observed_at: "2026-11-10T18:00:00.000Z"
      correspondents: [reviewer]
  - subscription:
      subscription_id: release-watch-1
      observed_at: "2026-11-10T17:59:59.200Z"
      text: Stable release v2.4.0 is available
```

## Handover generation and replacement

A compaction request contains the common system prompt, the history to summarize, and a turn with `current` and `summarize`. The [handover instructions](../packages/agent/src/compaction.md) ask for a plain-text summary. Tools are disabled, and observations awaiting admission stay queued. A tool result in this request can contain a short omission notice in place of an attachment. The result keeps its existing text, including any source description. If the runtime requests a revised summary, `summarize.instructions` includes the reason for revision.

After accepting a handover, the next ordinary request presents it first in the retained history. Any carried-forward observations and complete exchanges follow it. New observations appear in the current turn.

See [bounded model context](architecture.md#bounded-model-context) for which history is summarized or carried forward and when a handover replaces it.
