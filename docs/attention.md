# Attention

The core and activities are focuses of one Ivenna. Each focus has its own identity, working history, and event queue. Its `focus_id` identifies it in observations and retained history across sleep and restart. Its channel address lets another focus send it a message. See [communication](communication.md).

These [attention tools](../packages/agent/src/tools.json) let each focus decide what to attend to. The [role overview](design.md#core-and-concurrent-attention) covers the other actions available to each focus.

| Action | Tool | Available to |
| --- | --- | --- |
| Open another focus on some work | `open_focus` | Core |
| Reach an existing focus | `send` with a focus channel address | Core and activities |
| Return to something later | `schedule_attention` | Core |
| Receive [recurring observations](#subscriptions) in this focus | `subscribe` | Core and activities |
| Stop accepting reports for a subscription | `withdraw_subscription` | Core and activities |

Use the complete channel address to reach a focus and the complete subscription ID to withdraw a subscription. The core's focus ID is `core-1`. See [names and references](input.md#records-and-turns) for the name format.

## Opening a focus

The core calls `open_focus` with a short `name` and nonempty `task` describing what the activity should pursue. The runtime appends a number to the name and returns the focus ID and its channel address.

```json
{"result":{"focus_id":"practice-2","channel_id":"ivenna:/focus/practice-2"}}
```

The activity inherits the core's retained history through the complete round that opened it, including that round's tool results and any existing handover. The task is its first new observation. The core continues its own work. Their histories then grow independently, and the core receives [what the activity says](#activity-expressions).

Inherited records keep their original [focus IDs](input.md#records-and-turns). Core and activity use the same system prompt. Subsequent inferences identify the activity as the current focus and supply the tools available to its role. Queued observations, callbacks, and subscription reports keep their original destinations. Historical tool calls are not replayed.

Malformed arguments or an empty task return `invalid_arguments`. Exhausted focus capacity returns `focus_unavailable`; existing focuses remain addressable. See [configuration](running.md#configuration) for capacity limits.

## Reaching an existing focus

Any focus can call `send` with an existing focus's `channel_id` and nonempty `text`. `current.channels.focuses` includes the calling focus, so it can also send to itself. See [the channel catalog](input.md#inference-turns).

```json
{"channel_id":"ivenna:/focus/practice-2","text":"Include a short warm-up in your plan."}
```

A successful call saves the message in the recipient's queue and returns its channel address.

```json
{"result":{"channel_id":"ivenna:/focus/practice-2"}}
```

The observation identifies the sending focus as its source. When relaying someone else's words, include their attribution in the text. The message makes a sleeping or interrupted recipient ready. An active recipient can read it between complete model/tool rounds, so a long tool call can delay delivery. Focus messages count toward the recipient's [event queue limit](running.md#session-and-command-capacity). See [focus message fields](input.md#focus-messages-and-callbacks).

## Returning later

Call `schedule_attention` with a short `name`, an `at` deadline in RFC 3339 form with an explicit UTC offset, and nonempty `text` describing what to return to. Use `Z` for UTC or an offset such as `+08:00`.

```json
{"name":"revisit-practice","at":"2026-11-10T18:00:00Z","text":"Revisit the French practice plan."}
```

The arrangement survives restart. Success returns its complete callback reference:

```json
{"result":{"callback_id":"revisit-practice-5"}}
```

The text later reaches the core as a callback observation with source `wakeup`. Past timestamps are due immediately; polling, queue capacity, and scheduling can delay inference. The core can sleep while waiting. Cancellation is unavailable.

### Callback observations

Scheduled wakeups and [host commands](host.md#command-lifetimes) that outlive their initial call each arrange one callback. Its observation returns to the calling focus with the original reference and source, even after sleep or restart. A callback remains pending until the focus admits its observation. A host command can therefore be finished while its callback still appears in a handover. See the [observation fields](input.md#focus-messages-and-callbacks) and [sampled state](input.md#sampled-state).

The focus admits each callback at most once. Repeated publication preserves the first identifiable stored result. See the [callback protocol](architecture.md#callback-delivery).

## Subscriptions

Call `subscribe` in the focus that should receive the reports. Describe in `listener` what to watch and when to report, such as once per release or in a daily digest. The description can include where to find the listener program or its configuration. In this example, the core follows release announcements across assignments.

```json
{
  "name": "releases",
  "listener": "Report each new stable version from the project's release feed."
}
```

Each call creates a subscription and returns its complete reference, even if this focus already follows the same source.

```json
{"result":{"subscription_id":"releases-1"}}
```

Give the returned `subscription_id` to the listener you set up. If an activity runs the listener for `releases-1` on the host, the subscription still directs its reports to the core. See the [listener protocol](subscriptions.md) for reporting and resuming from a saved position.

An accepted report makes a sleeping focus ready. A working focus can receive several reports alongside other observations after its current round. Reports left out of that input stay queued. See [subscription observations](input.md#subscription-observations).

Subscriptions survive sleep and restart. The focus can find its active subscription IDs in the [state sampled for a handover](input.md#sampled-state).

Any focus can call `withdraw_subscription` with the complete `subscription_id`. The result echoes the ID. The `changed` field is `true` when the call closes an active subscription and `false` for an unknown or previously withdrawn ID. Reports accepted before withdrawal still reach the subscribing focus. Stop the listener separately if needed.

## Results and errors

These actions return a JSON text part containing either `result` or an operation `error` with `code` and `message`.

| Code | Meaning |
| --- | --- |
| `invalid_arguments` | Arguments do not match the tool's declaration |
| `unknown_tool` | The action is unavailable to the calling role or is not a current tool |
| `focus_unavailable` | A new focus cannot fit the configured limit |
| `unknown_channel` | The addressed focus is unknown or has ended |
| `focus_queue_full` | The recipient cannot currently accept another event |

See [runtime availability](design.md#runtime-availability) for failures that interrupt reasoning or stop the kernel.

## Activity expressions

Each ordinary activity inference that produces assistant text contributes one message for the core. The runtime records that text before executing any accompanying tool calls, so a report can describe an intention whose outcome is still unknown. Tool replies belong to the activity's own exchange. To share a finding, the activity can quote the relevant passage or give the core a [location it can open](resources.md).

The core can receive activity messages in its next ordinary input, including a continuation after tool use. Messages that wait for a later input keep their order. The core's history attributes each admitted report to its source activity.

One input can carry reports from several activities alongside other observations. An ending can accompany new text or arrive later without repeating admitted messages. The [input contract](input.md#assignments-and-reports) defines grouping and the observation times preserved through waiting and restart.

## Interrupted reasoning

An activity can pause when its next request cannot fit, when the service rejects it, or when the response is unusable. The core receives a [`focus_interrupted` observation](input.md#activity-interruptions) with the reason. The activity keeps its working history, queued observations, and registrations. An explicit message to its channel, a command completion, or a new subscription report can resume it.

If waiting observations make a request too large, the runtime can continue a tool exchange with a fitting request while those observations stay queued. See [how the runtime continues after compaction](architecture.md#continuing-with-a-handover).

## Activity completion

An activity with a pending callback or an active subscription can sleep with its identity and history intact. If its last subscription is withdrawn with reports still queued, the activity remains available to receive them.

Withdraw subscriptions when the activity finishes following their sources. When no work or registrations remain, the activity ends and frees its capacity slot. Its ending calls for the core's attention even if it produced no text.

Completed focus references stay reserved, and messages to them return `unknown_channel`. The core can still receive the ended activity's [expressions and ending](input.md#assignments-and-reports) with the original focus ID.
