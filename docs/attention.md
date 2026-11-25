# Attention

The core and activities are focuses of one Ivenna. Each has a working history, an event queue, and a `focus_id`. The core's ID is `core-1`. See the [role overview](design.md#core-and-concurrent-attention) for the actions available to each focus.

| Action | Tool |
| --- | --- |
| [Open a focus for an assignment](#opening-a-focus) | `open_focus` |
| [Reach an existing focus](#reaching-an-existing-focus) | `send` |
| [Return to something later](#returning-later) | `schedule_attention` |
| [Receive recurring observations in this focus](#subscriptions) | `subscribe` |
| [Withdraw a subscription](#withdrawing-a-subscription) | `withdraw_subscription` |

See [names and references](input.md#names-and-references) for the `name` argument and the [tool schema](../packages/agent/src/tools.json) for the declarations.

## Opening a focus

The core calls `open_focus` with a short `name` and nonempty `task` describing what the activity should pursue.

```json
{"name":"practice","task":"Prepare a short French practice plan."}
```

The result gives the activity's `focus_id`. The activity can receive messages once the opening round completes.

```json
{"result":{"focus_id":"practice-2"}}
```

The activity inherits the core's retained history through the opening round, including its tool results and any existing handover. The task is its first new observation. Inherited records keep their original focus IDs. Queued observations, callbacks, and subscription reports keep their original destinations. See [records and turns](input.md#records-and-turns) and [how an activity starts](architecture.md#activity-forks).

Subsequent inferences identify the activity as the current focus and supply its tools. The two histories grow independently, and the core receives [what the activity says](#activity-expressions).

Opening an activity once the focus limit is reached returns `focus_unavailable`. See [session capacity](running.md#session-and-command-capacity).

## Reaching an existing focus

Call `send` with the recipient's complete ID in `to.focus_id` and the message in `text`. A focus can send to itself using `current.focus_id`. See [sending a message](communication.md#sending-a-message) for sources of IDs and other destination types.

```json
{"to":{"focus_id":"practice-2"},"text":"Include a short warm-up in your plan."}
```

A successful call saves the message in the recipient's queue and returns its focus ID.

```json
{"result":{"focus_id":"practice-2"}}
```

The observation identifies the sending focus. When relaying someone else's words, attribute them in the text. The message makes a sleeping or interrupted recipient ready. An active recipient can read it between complete model/tool rounds. Focus messages count toward the recipient's event queue limit. See [focus message fields](input.md#focus-messages) and [session capacity](running.md#session-and-command-capacity).

## Returning later

The core calls `schedule_attention` with a short `name`, an absolute wakeup time in `at`, and nonempty `text` describing what to return to. Pass `at` as an RFC 3339 date and time with `Z` for UTC or an explicit offset such as `+08:00`.

```json
{"name":"revisit-practice","at":"2026-11-10T18:00:00Z","text":"Revisit the French practice plan."}
```

The wakeup survives restart. The result gives its `callback_id`.

```json
{"result":{"callback_id":"revisit-practice-5"}}
```

A past `at` makes the wakeup eligible at the next intake poll. The core can keep working until the callback arrives. The observation carries the supplied text and the scheduled instant in `scheduled_for`, rendered in UTC. Cancellation is unavailable. See [wakeup and callback fields](input.md#callback-observations).

### Callback observations

A scheduled wakeup or a host command that outlasts its initial call arranges one callback. The observation returns to the focus that arranged it, with the same callback ID, even after sleep or restart. The focus admits at most one observation per callback ID. See [command lifetimes](host.md#command-lifetimes), [observation fields](input.md#callback-observations), and [callback delivery](architecture.md#callback-delivery).

## Subscriptions

Call `subscribe` in the focus that should receive the reports. Describe in `listener` what to watch and when to report, such as once per release or in a daily digest. The description can include where to find the listener program or its configuration. In this example, the core follows release announcements across assignments.

```json
{
  "name": "release-watch",
  "listener": "Report each stable release in the project changelog."
}
```

Each successful call creates a subscription with a new `subscription_id`, even if this focus already follows the same source.

```json
{"result":{"subscription_id":"release-watch-1"}}
```

Give the returned `subscription_id` to the program that watches the source and reports observations. If the core calls `subscribe`, reports go to the core even when an activity runs the listener on the host. See the [listener protocol](subscriptions.md) for reporting and resuming from a saved position.

An accepted report makes a sleeping focus ready. A working focus can receive several reports alongside other observations after its current round. Reports left out of that input stay queued. See [subscription observations](input.md#subscription-observations).

Subscriptions survive sleep and restart. A handover can carry the active subscriptions and their descriptions. See [sampled state](input.md#sampled-state).

### Withdrawing a subscription

Any focus can call `withdraw_subscription` with the complete `subscription_id`. The result echoes the ID with `changed: true` if the call withdrew the subscription, or `changed: false` if the subscription was already withdrawn or unknown. Reports already accepted remain addressed to the subscribing focus. Stop the listener separately if needed. See [listener behavior after withdrawal](subscriptions.md#withdrawal).

## Results and errors

These actions return a JSON text part containing either `result` or an operation `error` with `code` and `message`.

| Code | Meaning |
| --- | --- |
| `invalid_arguments` | Arguments do not match the tool's declaration |
| `unknown_tool` | The action is unavailable to the calling role or is not a current tool |
| `focus_unavailable` | A new focus cannot fit the configured limit |
| `unknown_focus` | The selected focus is unknown or has ended |
| `focus_queue_full` | The recipient cannot currently accept another event |

See [runtime availability](design.md#runtime-availability) for failures that interrupt reasoning or stop the kernel.

## Activity expressions

Each ordinary activity inference that produces assistant text contributes one message for the core. The runtime records that text before executing any accompanying tool calls, so a report can describe an intention whose outcome is still unknown. Tool replies belong to the activity's own exchange. To share a finding, the activity can quote the relevant passage or give the core a [location it can open](resources.md).

The core can receive activity messages in its next ordinary input, including a continuation after tool use. Messages that wait for a later input keep their order. The core's history attributes each admitted report to its source activity.

One input can carry reports from several activities alongside other observations. See [how activity reports group messages and endings](input.md#assignments-and-reports).

## Interrupted reasoning

An activity can pause when its next request cannot fit, when the service rejects it, or when the response is unusable. The core receives a [`focus_interrupted` observation](input.md#activity-interruptions) with the reason. The activity keeps its working history, queued observations, and registrations. An explicit message, a command completion, or a new subscription report can resume it.

If waiting observations make a request too large, the runtime can continue a tool exchange with a fitting request while those observations stay queued. See [how the runtime continues after compaction](architecture.md#continuing-with-a-handover).

## Activity completion

An activity with a pending callback or an active subscription can sleep with its identity and history intact. If its last subscription is withdrawn with reports still queued, the activity remains available to receive them.

Withdraw subscriptions when the activity finishes following their sources. The activity ends and frees its capacity slot when it has no work, pending callbacks, or active subscriptions left. Its ending calls for the core's attention even if it produced no text.

The core can still receive the ended activity's expressions and ending with its original focus ID. An activity can share an open channel's ID in a report so the core can keep using it after the activity ends. See [channel lifetimes](communication.md#channel-lifetimes) and [report fields](input.md#assignments-and-reports).
