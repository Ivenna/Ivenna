# Attention

The core and activities are focuses of one Ivenna. Each has a working history, an event queue, and a `focus_id`. The core's ID is `core-1`. See the [role overview](design.md#core-and-concurrent-attention) for the actions available to each focus.

| Action | Tool |
| --- | --- |
| [Open another focus](#opening-a-focus) | `open_focus` |
| [Reach an existing focus](#reaching-an-existing-focus) | `send` |
| [Return to something later](#returning-later) | `schedule_attention` |
| [Receive recurring observations in this focus](#subscriptions) | `subscribe` |
| [Withdraw a subscription](#withdrawing-a-subscription) | `withdraw_subscription` |

See [names and references](input.md#names-and-references) for the `name` argument and the [tool schema](../packages/agent/src/tools.json) for the declarations.

## Opening a focus

The core calls `open_focus` with a short `name` and a nonempty `task` describing what it wants to explore or work on in the new focus.

```json
{"name":"practice","task":"Think through how to get back into practicing French."}
```

The result gives the activity's `focus_id`. The activity can receive messages once the opening round completes.

```json
{"result":{"focus_id":"practice-2"}}
```

The activity inherits the core's retained history through the end of the opening round, including results from tools called after `open_focus` in that round. The history can include earlier correspondence, work, and a handover. The supplied `task` arrives as the activity's first new observation. If the runtime summarizes the inherited history before the activity starts reasoning, the activity receives the handover and its original assignment together. See [assignment fields](input.md#assignments-and-reports) and [how an activity starts](architecture.md#activity-forks).

The activity reasons with its own focus ID, tools, and working history. The core keeps its queued observations and continues to receive its callbacks and subscription reports. It can also read [what the activity says](#activity-expressions).

Opening an activity once the focus limit is reached returns `focus_unavailable`. See [session capacity](running.md#session-and-command-capacity).

## Reaching an existing focus

Call `send` with the recipient's complete ID in `to.focus_id` and the message in `text`. A focus can send to itself using `current.focus_id`. See [sending a message](communication.md#sending-a-message) for sources of IDs and other destination types.

```json
{"to":{"focus_id":"practice-2"},"text":"I used to enjoy starting with a short conversation."}
```

A successful call saves the message in the recipient's queue and returns its focus ID.

```json
{"result":{"focus_id":"practice-2"}}
```

The observation identifies the sending focus. When relaying someone else's words, attribute them in the text. The message makes a sleeping or interrupted recipient ready. An active recipient can read it between complete model/tool rounds. Focus messages count toward the recipient's event queue limit. See [focus message fields](input.md#focus-messages) and [session capacity](running.md#session-and-command-capacity).

## Returning later

The core calls `schedule_attention` with a short `name`, an absolute wakeup time in `at`, and nonempty `text` describing what to return to. Pass `at` as an RFC 3339 date and time with `Z` for UTC or an explicit offset such as `+08:00`.

```json
{"name":"revisit-practice","at":"2026-11-10T18:00:00Z","text":"See how French practice has been going."}
```

The wakeup survives restart. The result gives its `callback_id`.

```json
{"result":{"callback_id":"revisit-practice-5"}}
```

A past `at` makes the wakeup eligible at the next intake poll. The core can keep working until the callback arrives. The observation carries the supplied text and the scheduled instant in `scheduled_for`, rendered in UTC. Cancellation is unavailable. See [wakeup and callback fields](input.md#callback-observations).

### Callback observations

A scheduled wakeup or a host command that outlasts its initial call arranges one callback. The observation returns to the focus that arranged it, with the same callback ID, even after sleep or restart. The focus admits at most one observation per callback ID. See [command lifetimes](host.md#command-lifetimes), [observation fields](input.md#callback-observations), and [callback delivery](architecture.md#callback-delivery).

## Subscriptions

Call `subscribe` in the focus that should receive the reports. In `listener`, record what the program watches and when it should report. You can include where to find the program or its configuration. In this example, the core follows release announcements across assignments.

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

Start or configure the program that watches the source and give it the `subscription_id`. Reports go to the focus that called `subscribe`, even when another focus runs the listener. [Listener protocol](subscriptions.md)

A newly queued report can wake a sleeping focus. A working focus can receive several reports alongside other observations after its current round. Reports left out of that input stay queued. [Subscription observations](input.md#subscription-observations)

Subscriptions survive sleep and restart. A handover can carry active subscription IDs and their descriptions. An ordinary turn can list subscriptions that have no open listener session when sampled. See [sampled state](input.md#sampled-state) and [listener sessions in the current turn](input.md#channel-receivers-and-subscription-listeners).

### Withdrawing a subscription

Any focus can call `withdraw_subscription` with the complete `subscription_id`. The result echoes the ID with `changed: true` if the call withdrew the subscription, or `changed: false` if the subscription was already withdrawn or unknown. Reports already accepted remain addressed to the subscribing focus. Stop the listener separately if needed. See [listener behavior after withdrawal](subscriptions.md#withdrawal).

## Results and errors

These actions return a JSON text part containing either `result` or an operation `error` with `code` and `message`.

| Code | Meaning |
| --- | --- |
| `invalid_arguments` | Arguments do not match the tool's declaration |
| `unknown_tool` | The action is unavailable to the calling role or is not a current tool |
| `focus_unavailable` | The runtime is at its configured session limit |
| `unknown_focus` | The selected focus is unknown or has ended |
| `focus_queue_full` | The recipient cannot currently accept another event |

See [runtime availability](design.md#runtime-availability) for failures that interrupt reasoning or stop the kernel.

## Activity expressions

Each ordinary activity inference that produces assistant text contributes one message for the core. The runtime records that text before executing any accompanying tool calls, so a report can describe an intention whose outcome is still unknown. Tool replies belong to the activity's own exchange. To share a finding, the activity can quote the relevant passage or give the core a [location it can open](resources.md).

The core can receive activity messages in its next ordinary input, including a continuation after tool use. Messages that wait for a later input keep their order. The core's history attributes each admitted report to its source activity.

One input can carry reports from several activities alongside other observations. See [how activity reports group messages and endings](input.md#assignments-and-reports).

## Interrupted reasoning

An activity can pause when its next request cannot fit, when the service rejects it, or when the response is unusable. The core receives a [`focus_interrupted` observation](input.md#activity-interruptions) with the reason. The activity keeps its working history, queued observations, and registrations. An explicit message, a command completion, or a new subscription report can resume it.

If a waiting observation makes a request too large, the runtime can continue pending work that fits while the observation stays queued. See [how the runtime continues after compaction](architecture.md#continuing-with-a-handover).

## Activity completion

An activity with a pending callback or an active subscription can sleep with its identity and history intact. If its last subscription is withdrawn with reports still queued, the activity remains available to receive them.

The runtime ends the activity and frees its capacity slot once it has no work, pending callbacks, or active subscriptions left. The core can still receive unread messages under the activity's original focus ID. It also receives the ending, even if the activity produced no text. See [report fields](input.md#assignments-and-reports).

An activity can share an open channel's ID in a report so the core can keep using the channel after the activity ends. See [channel lifetimes](communication.md#channel-lifetimes).
