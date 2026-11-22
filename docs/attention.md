# Attention

The core and activities are focuses of one Ivenna. Each focus has its own identity, working history, and event queue. A `focus_id` identifies it in observations, tool results, and retained history; it survives sleep and restart. Correspondent IDs belong to [external communication](communication.md), not to this internal coordination.

The [agent tools](../packages/agent/src/tools.json) let each focus decide what to attend to.

| Action | Tool | Available to |
| --- | --- | --- |
| Open another focus on some work | `open_focus` | Core |
| Reach an existing focus | `send_focus_message` | Core |
| Return to something later | `schedule_attention` | Core |
| Receive [recurring observations](#subscriptions) in this focus | `subscribe` | Core and activities |
| Stop accepting reports for a subscription | `withdraw_subscription` | Core and activities |

Both roles can also [communicate externally](communication.md) and [maintain memory](memory.md). Activities have [host tools](host.md). The [design intent](design.md#core-and-concurrent-attention) explains these roles.

Names may repeat. Use the complete reference when addressing a focus or subscription. The core's reference is `core-1`. Names must contain 1–32 Unicode code points and exclude ASCII control characters. Spaces alone are invalid.

## Opening a focus

Call `open_focus` with a short `name` and nonempty `task` describing what this focus should pursue. The runtime appends a number to the name and returns the complete stable reference:

```json
{"result":{"focus_id":"practice-2"}}
```

The activity inherits the core's retained history through the complete calling model/tool round, including any existing handover, then receives the task as its first new observation. The core continues its activation; their histories then grow independently.

Inherited records keep their original [focus IDs](input.md#records-and-turns). Core and activity use the same system prompt. Subsequent inferences identify the activity as the current focus and supply the tools available to its role. Queued observations, callbacks, and subscription reports keep their original destinations. Historical tool calls are not replayed.

Malformed arguments or an empty task return `invalid_arguments`. Exhausted focus capacity returns `focus_unavailable`; existing focuses remain addressable. See [configuration](running.md#configuration) for capacity limits.

## Reaching an existing focus

Call `send_focus_message` with a complete `focus_id` and nonempty `text`. The core can address any existing focus, including itself at `current.focus_id`. Tool results, activity reports, interruption notices, and handovers carry focus references. A successful call saves the message in the recipient's queue and returns its reference.

```json
{"result":{"focus_id":"practice-2"}}
```

The observation identifies the sending core as its source. When relaying someone else's words, include their attribution in the text. The message makes a sleeping or interrupted recipient ready. An active recipient can read it between complete model/tool rounds, so a long tool call can delay delivery.

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

## Subscriptions

Call `subscribe` in the focus that should receive the reports. For example, the core can follow release announcements across assignments and ask an activity to set up the listener on the host.

```json
{
  "name": "releases",
  "listener": "Report each new stable version from the project's release feed.",
  "reminder": "next_input"
}
```

Pass the returned `subscription_id` to the listener.

```json
{"result":{"subscription_id":"releases-1"}}
```

The `listener` field records what the program watches and when it should report. It can include the program or configuration path. The listener runs separately and submits observations using the [listener protocol](subscriptions.md).

| Reminder | Effect on the receiving focus |
| --- | --- |
| `immediate` | A report can wake the focus. A working focus can read it after the current round. |
| `next_input` | Wait for the next ordinary input, including a continuation after tools. A sleeping focus stays asleep. |

Reports that do not fit in one input wait for a later turn. Each [observation](input.md#subscription-observations) carries its subscription reference. During compaction, the runtime records the ID of each active subscription for this focus in the [handover](input.md#sampled-state), even if its listener has never reported.

Any focus can call `withdraw_subscription` with the complete `subscription_id`. The result echoes the ID. `changed` is `true` if this call closed an active subscription and `false` otherwise. Reports accepted before withdrawal keep their destination and reminder. Stop the listener separately if needed.

Reconfiguring the listener can change what it reports under the same subscription. To choose a different reminder, register again, give the listener the new reference and withdraw the old subscription. Each registration has its own [cursor and retry keys](subscriptions.md#resume-from-a-cursor).

## Results and errors

These actions return a JSON text part containing either `result` or an operation `error` with `code` and `message`.

| Code | Meaning |
| --- | --- |
| `invalid_arguments` | Arguments do not match the tool's parameters |
| `unknown_tool` | The action is unavailable to the calling role or is not a current tool |
| `focus_unavailable` | A new focus cannot fit the configured limit |
| `unknown_focus` | The addressed focus is unknown or has ended |
| `focus_queue_full` | The recipient cannot currently accept another event |

`open_focus` reserves an identity; focus messages use the recipient's ordinary event allowance. See [configuration](running.md#configuration) for limits and [focus messages and callbacks](input.md#focus-messages-and-callbacks) for observation fields. Infrastructure failures follow the [availability contract](design.md#runtime-availability).

## Callback observations

Scheduled attention and [host commands](host.md#command-lifetimes) that outlive their initial call deliver registered [callback observations](input.md#focus-messages-and-callbacks), independently of external correspondence. Each callback reference connects an arrangement with its pending state and arriving observation. The runtime keeps that observation bound to the receiving focus and its source. The destination survives sleep, context unloading, and restart, and the observation is admitted at most once even if several mail copies arrive. Repeated publication preserves the first identifiable stored result.

The callback remains pending until its observation is admitted, even if its source has already finished. Its complete reference appears in the registration result and arriving observation. Compaction supplies pending callbacks for recollection and carries them into the handover. Source completion, result delivery, and activity completion are separate events.

The current email adapter stores these observations as [callback mail](architecture.md#callback-delivery). See [delivery and admission](architecture.md#event-sources-and-callback-admission) for registration and resumption, and [communication-copy retention](running.md#communication-copies) for the mail's lifetime.

## Activity expressions

New assistant text from ordinary activity inferences is collected in order for the core, including text accompanying tool calls. It is retained before those tools execute, so the text may describe intentions whose effects are not yet known. Reasoning, tool replies, compaction output, and inherited history are not collected as new expressions.

These texts do not activate the core. They accompany ordinary core inputs, including continuations after tools, within the request budget. Information that has not been admitted remains available in recorded order. Admitted reports become retained observations in the core's history; they remain attributed to their source activity.

One input can carry reports from several activities alongside other observations. An ending can accompany new text or arrive later without repeating admitted messages. The [input contract](input.md#assignments-and-reports) defines grouping and the observation times preserved through waiting and restart.

## Interrupted reasoning

A rejected request, an unusable model response, or an input that cannot fit the context budget can interrupt an activity. The runtime alerts the core with a [`focus_interrupted` observation](input.md#activity-interruptions) giving the reason. The activity keeps its working history, queued observations and registrations. A message from the core, a command completion or a fresh `immediate` subscription report can resume it.

## Activity completion

A sleeping activity keeps its identity and history while it has a pending callback, an active subscription, or a subscription report awaiting delivery. If its last subscription is withdrawn, an accepted `next_input` report still waits for ordinary input, such as a message from the core.

Withdraw subscriptions when the activity finishes following their sources. When no work or registrations remain, the activity ends and frees its capacity slot. Its ending calls for the core's attention even if it produced no text.

Completed focus references are not reused, and messages to them return `unknown_focus`. Reports keep their source IDs and remain available for core admission after the source focus has ended.
