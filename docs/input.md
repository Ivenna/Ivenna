# Runtime user messages

Observations, handovers, and the current inference turn appear as YAML messages with the `user` role. See the [input definitions and renderers](../packages/agent/src/input.zig).

When a tool result includes uploaded files, the inference input includes a user-role message with the tool call ID and the file IDs. See [tool result encoding](architecture.md#tool-results).

## Records and turns

| Interface | Shape | Lifetime and meaning |
| --- | --- | --- |
| [`Input.Record`](#retained-records) | `events` or `handover` | Observations and handovers retained in working history |
| [`Input.Turn`](#inference-turns) | `current` with optional `events`, or `current` with `summarize` | Focus identity and input for one inference |

Newly admitted events enter working history as records. The runtime also retains complete model/tool exchanges when their rounds commit.

`Text` denotes a string. `Time` denotes a UTC RFC 3339 string with millisecond precision, such as `2026-11-06T12:00:01.000Z`. Records, events, and callback sources are mappings with one key for the branch name and its payload as the value.

The turn's `current.focus_id` identifies the focus receiving the turn. Inherited records keep their original focus IDs and observation times, so an activity can see the core's ID in its history.

## Names and references

The `name` supplied when opening a focus or channel, running a command, or subscribing contains one to 32 Unicode code points, excludes ASCII controls, and includes at least one character besides an ASCII space. The runtime appends a numeric suffix, as in `practice-2`, so repeated names within a resource type produce distinct IDs.

Use the complete ID to identify the item. Focus IDs remain stable across waiting, context unloading, and restart. Ending an activity retires its ID permanently. A callback ID connects the arrangement, sampled pending state, and eventual observation. Command IDs control host commands in their originating runtime. Channel IDs can address a restored channel after restart. See [channel lifetimes](communication.md#channel-lifetimes).

## Retained records

Retained records and complete model/tool exchanges form the focus's working history. See [persistent working history](architecture.md#persistent-working-history) for storage encoding and checkpoints.

### Event groups

An `events` record has `focus_id: Text` and `items: Event[]`. The ordinary turn that admits the observations presents them in `events`. Later requests carry the admitted group in history. See [admission](architecture.md#activation-admission).

Each `Event` selects one branch.

| Branch | Payload | Meaning |
| --- | --- | --- |
| `startup` | `Startup` | Observation that a new runtime has begun |
| `input` | `IncomingMessage` | Observation of what correspondents said |
| `assignment` | `Assignment` | The core's initial intent for a new activity |
| `activity` | `ActivityReport` | One activity's newly admitted messages and ending information |
| `focus_message` | `FocusMessage` | Explicit message from a focus |
| `focus_interrupted` | `FocusInterrupted` | Runtime observation that an activity could not continue reasoning |
| `callback` | `Callback` | A host command completion observation |
| `subscription` | `SubscriptionReport` | A listener's report to the focus that subscribed |

#### Startup and restart

The core receives `startup` on first launch and every restart. A restored activity with its initial assignment still queued begins with the assignment. An activity whose assignment was already admitted receives `startup` when it next resumes after restart. See [startup and interruption](architecture.md#startup-and-interruption).

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

An activity's first new observation is an `assignment`. Its `task: Text` field contains the text the core passed to `open_focus`. The same text can also appear in the inherited tool call. See [opening a focus](attention.md#opening-a-focus).

In the core's input, an `ActivityReport` groups newly admitted messages and any ending from one activity.

| Field | Type | Meaning |
| --- | --- | --- |
| `from_focus` | `Text` | Source activity focus |
| `messages` | `ActivityMessage[]`, when nonempty | New assistant texts from this activity, in recorded order |
| `ended_at` | `Time`, when present | Time the runtime ended the activity |

Each ordinary activity response that contains assistant text contributes one `ActivityMessage`. Its `text: Text` carries that text, including an explicitly empty string. Its `observed_at: Time` records when the runtime collected the complete response, before executing any accompanying tool calls.

A report contains messages, an ending, or both. An ending with no unread messages has just `from_focus` and `ended_at`.

One ordinary core input, including a tool continuation, can contain events and reports from several activities. Newly admitted messages for the same focus are grouped once. Each group's position follows that focus's first appearance in the selected observations, and messages within it keep their original order. Use the observation times for messages and endings from different focuses. Those times survive waiting, persistence, and restart.

See how the core receives [activity expressions](attention.md#activity-expressions) and when the runtime [ends an activity](attention.md#activity-completion).

#### Activity interruptions

The runtime sends the core a `focus_interrupted` event when an activity has to pause reasoning.

| Field | Type | Meaning |
| --- | --- | --- |
| `focus_id` | `Text` | Activity whose reasoning was interrupted |
| `observed_at` | `Time` | Time the runtime recorded the interruption |
| `reason` | `Text` | What prevented the activity from continuing, such as context size or a model-service refusal |

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

Each new `callback` reports a host command outcome or interruption to the activity that started the command.

| Field | Type | Meaning |
| --- | --- | --- |
| `callback_id` | `Text` | Complete ID returned by a `run_host_shell` handoff |
| `source` | `CallbackSource` | `{host: {command_id: "build-17"}}` |
| `observed_at` | `Time` | Time the runtime observed the callback during intake |
| `text` | `Text` | Serialized host result or diagnostic |

`source.host.command_id` identifies the command even if its control handle has expired. See [command lifetimes](host.md#command-lifetimes).

Retained observations and handover samples can still include the former `source: {wakeup: {}}`, with `scheduled_for` when the time was saved. See [upgrading from scheduled attention](upgrading.md#removing-scheduled-attention).

#### Subscription observations

Each `subscription` event carries one listener report to the focus that subscribed. Reports for that focus appear in acceptance order across its subscriptions.

| Field | Type | Meaning |
| --- | --- | --- |
| `subscription_id` | `Text` | ID returned by `subscribe`, shared by all reports for that subscription |
| `observed_at` | `Time` | Time `ivenna subscription listen` recorded before saving the report |
| `source_time` | `Time`, when supplied | Time of the reported event, as supplied by the listener |
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

The compaction turn carries the runtime sample in `summarize.state`. Its `current.observed_at` dates the turn. The accepted handover keeps the sample and time alongside the summary. Inherited handovers keep their original focus ID, time, and sample.

| Field | Type | Core sample | Activity sample |
| --- | --- | --- | --- |
| `activities` | `Text[]` | IDs of existing activities, including sleeping and interrupted ones | — |
| `callbacks` | `PendingCallback[]` | — | Pending host callbacks for this activity |
| `subscriptions` | `SampledSubscription[]` | Active subscriptions for the core | Active subscriptions for this activity |
| `channels` | `SampledChannel[]` | All open channels, including those opened by activities that have ended | Open channels created by this activity |
| `correspondents` | `Text[]` | Registered outgoing correspondent IDs | — |

Core samples always include `correspondents`, even when empty. Other collections appear when nonempty. When every field is absent, the message omits `state`. See [startup and restart](#startup-and-restart) for how to interpret the correspondent list.

A `SampledSubscription` has `subscription_id: Text` and the registered `listener` description of what to watch and when to report. A new subscription can appear before its first report. A report accepted before withdrawal can still reach the focus after the subscription leaves the sample. See [subscriptions](attention.md#subscriptions).

A `SampledChannel` has `channel_id: Text` and the `description` supplied when the channel opened, when available. A channel enters the sample after the runtime confirms its registration. A retained handover records what was open at the time of the sample. The result of a new send tells the focus whether the message reached a waiting receiver. See [opening a channel](communication.md#opening-a-channel) and [channel send outcomes](communication.md#sending-to-a-channel).

`listener` and `description` are `Text` or `null`. Older samples that stored only IDs use `null`. Some older checkpoints can also restore a channel without a saved description.

Each `PendingCallback` contains `callback_id: Text` and `source: CallbackSource`. A callback remains pending until its observation enters the activity's history, and it can refer to a command that has already finished. See [callback observations](#callback-observations) and [command lifetimes](host.md#command-lifetimes).

In this handover, the sampled state gives the core a subscription for stable releases and a channel for CSV files ready to import.

```yaml
handover:
  focus_id: core-1
  observed_at: "2026-11-06T12:00:01.000Z"
  summary: The verification activity is checking the release CSVs. Review the results when the activity reports back.
  state:
    activities: [verify-release-2]
    subscriptions:
      - subscription_id: release-watch-1
        listener: Report each stable release in the project changelog.
    channels:
      - channel_id: task-input-18
        description: Receives the absolute path of each CSV file ready for import.
    correspondents: [operator]
```

## Inference turns

The last message of an inference input is the current turn.

| Field | Type | Meaning |
| --- | --- | --- |
| `current` | `Current` | Focus identity, role, observation time, and any channel or subscription connection notes |
| `events` | `Event[]`, when nonempty | New events for an ordinary inference |
| `summarize` | `instructions: Text` and optional `state: State` | Request for a handover summary with any sampled state |

`current` describes the focus in both ordinary and compaction turns. Connection lists appear only in ordinary turns.

| Field in `current` | Type | Meaning |
| --- | --- | --- |
| `focus_id` | `Text` | ID of the focus receiving the turn |
| `role` | `Role` | `core` or `activity` |
| `observed_at` | `Time` | Time the runtime sampled this turn |
| `channels_without_receivers` | `Text[]`, when present | IDs of open channels with no connected receiver |
| `subscriptions_without_listeners` | `Text[]`, when present | IDs of active subscriptions with no open listener session |

When there are no new events, an ordinary turn contains only `current`. Retained events and [handover samples](#sampled-state) keep their own dates.

### Channel receivers and subscription listeners

The lists report what the runtime found during the sample dated by `current.observed_at`. An open receiver session counts as connected between reads, and an open listener session between reports. A channel send requires a waiting read at the time of the handoff. [Channel sends](communication.md#sending-to-a-channel) · [Listener sessions](subscriptions.md#open-a-listener-session)

| Field | Scope for the core | Scope for an activity |
| --- | --- | --- |
| `channels_without_receivers` | Channels across the instance | Channels opened by this activity |
| `subscriptions_without_listeners` | Subscriptions registered by the core | Subscriptions registered by this activity |

Each list includes up to eight IDs. The runtime omits empty lists and can omit both to fit the request. Use the sample only for the listed IDs and the current inference. The runtime samples connection status when an ordinary turn is already due.

After restart, the core receives a report accepted earlier. The sample shows that the subscription now lacks a listener and the open channel lacks a receiver.

```yaml
current:
  focus_id: core-1
  role: core
  observed_at: "2026-11-10T18:00:01.000Z"
  channels_without_receivers: [task-input-18]
  subscriptions_without_listeners: [release-watch-1]
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

A compaction request presents the history to summarize and a turn with `current` and `summarize` under the shared system prompt. It offers no tools and asks for a plain-text summary. On a revision request, `summarize.instructions` says what to correct. See the [handover instructions](../packages/agent/src/compaction.md).

When a summary request exceeds an adapter limit, the runtime can substitute short notices for images and file references in that request. The request still includes the tool result text and source descriptions. See [summary request preparation](architecture.md#sampling-state-and-preparing-the-request).

The next ordinary request begins its retained history with the accepted handover, followed by any records and complete exchanges carried forward. Observations already in history and still awaiting inference remain intact. Observations admitted for this turn appear in its `events` field. An activity whose inherited history was summarized before its first ordinary inference still sees its original [assignment](#assignments-and-reports).

See [bounded model context](architecture.md#bounded-model-context) for which history is summarized or carried forward and when a handover replaces it.
