# Attention

Ivenna can keep its main focus on correspondence and other ongoing concerns while it follows a question or line of work in an activity focus. Each focus has its own working history, pending observations, and a `focus_id`. The main focus has the stable ID `core-1`. [Actions available to each role](design.md#main-focus-and-concurrent-attention)

| Action | Tool |
| --- | --- |
| [Open another focus](#opening-a-focus) | `open_focus` |
| [Reach an existing focus](#reaching-an-existing-focus) | `send` |
| [Register a subscription](#subscriptions) | `subscribe` |
| [Withdraw a subscription](#withdrawing-a-subscription) | `withdraw_subscription` |

See [names and references](input.md#names-and-references) for the `name` argument and the [tool schema](../packages/agent/src/tools.json) for the declarations.

## Opening a focus

The main focus calls `open_focus` with a short `name` and a nonempty `task`. The task can be a question, a line of thought, or work Ivenna wants to give its own attention.

```json
{"name":"practice","task":"Think through how to get back into practicing French."}
```

The result gives the new `focus_id`. The activity focus can receive messages once the opening round completes.

```json
{"result":{"focus_id":"practice-2"}}
```

The new focus inherits the main focus's retained history through the end of the opening round, including results from tools called after `open_focus` in that round. It receives the supplied `task` as its first new observation, `assignment`. If quiet reflection replaces inherited history before that first ordinary request, the request includes the continuity note and the original assignment. [Assignment fields](input.md#assignments-and-reports) · [How an activity starts](architecture.md#activity-forks)

The focuses continue with their own observations and working histories. The main focus can also receive what the activity says. [Activity expressions](#activity-expressions)

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

## Subscriptions

Call `subscribe` in the focus that should receive the reports. Describe in `listener` what to watch and when to report it. Ivenna saves that description with the subscription. In this example, the main focus follows release announcements across activities.

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

Arrange the listener and give it the `subscription_id`. The focus that registered the subscription receives the reports regardless of which focus runs the listener. A listener can also report on a schedule. [Listener protocol](subscriptions.md) · [Scheduled reports](subscriptions.md#reporting-from-a-schedule)

A newly queued report can wake a sleeping focus. A working focus can receive several reports alongside other observations after its current round. Reports left out of that input stay queued. [Subscription observations](input.md#subscription-observations)

Subscriptions survive sleep and restart. The dated sample accompanying a continuity note can include active subscription IDs and their descriptions. An ordinary turn can report subscriptions without an open listener session. [Sampled state](input.md#sampled-state) · [Listener sessions in the current turn](input.md#channel-receivers-and-subscription-listeners)

### Withdrawing a subscription

Any focus can call `withdraw_subscription` with the complete `subscription_id`. The result echoes the ID with `changed: true` if the call withdrew the subscription, or `changed: false` if the subscription was already withdrawn or unknown. Reports already accepted remain addressed to the subscribing focus. Stop the listener separately if needed. See [listener behavior after withdrawal](subscriptions.md#withdrawal).

## Results and errors

These actions return a JSON text part containing either `result` or an operation `error` with `code` and `message`.

| Code | Meaning |
| --- | --- |
| `invalid_arguments` | Arguments do not match the tool's declaration |
| `unknown_tool` | The action is unavailable to the calling role or is not a current tool |
| `focus_unavailable` | The runtime is at its configured [session limit](running.md#session-and-command-capacity) |
| `unknown_focus` | The selected focus is unknown or has ended |
| `focus_queue_full` | The recipient cannot currently accept another event |

See [runtime availability](design.md#runtime-availability) for failures that interrupt reasoning or stop the kernel.

## Activity expressions

Each ordinary activity inference that produces assistant text contributes one message for the main focus. The runtime records that text before executing any accompanying tool calls, so a report can describe an intention whose outcome is still unknown. Tool replies belong to the activity focus's own exchange. To share a finding, it can quote the relevant passage or give the main focus a [location it can open](resources.md).

The main focus can receive activity messages in its next ordinary input, including a continuation after tool use. Messages that wait for a later input keep their order. The main focus's history attributes each admitted report to its source focus.

One input can carry reports from several activities alongside other observations. See [how activity reports group messages and endings](input.md#assignments-and-reports).

## Interrupted reasoning

An activity focus can pause when its next request cannot fit, when the service rejects it, or when the response is unusable. The main focus receives a [`focus_interrupted` observation](input.md#activity-interruptions) with the reason. The activity focus keeps its working history, queued observations, and registrations. An explicit message, a command completion, or a new subscription report can resume it.

If a waiting observation makes a request too large, the runtime can continue pending work that fits while the observation stays queued. See [how the runtime continues after compaction](architecture.md#resuming-after-quiet-reflection).

## Activity completion

An activity focus with a pending host callback or an active subscription can sleep with its ID and working history intact. If its last subscription is withdrawn with reports still queued, the focus remains available to receive them. [Command lifetimes](host.md#command-lifetimes)

The runtime ends the activity focus and frees its capacity slot once it has no work, pending callbacks, or active subscriptions left. The main focus can still receive unread messages under the original focus ID. It also receives the ending, even if the activity produced no text. See [report fields](input.md#assignments-and-reports).

An activity focus can share an open channel's ID in a report so the main focus can keep using the channel after the activity ends. See [channel lifetimes](communication.md#channel-lifetimes).
