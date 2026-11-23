# Attention

The core and activities are focuses of one Ivenna. Each focus has its own identity, working history, and event queue. A `focus_id` identifies it in observations, tool results, and retained history; it survives sleep and restart. Correspondent IDs belong to [external communication](communication.md), not to this internal coordination.

These [attention tools](../packages/agent/src/tools.json) let each focus decide what to attend to. The [role overview](design.md#core-and-concurrent-attention) covers the other actions available to each focus.

| Action | Tool | Available to |
| --- | --- | --- |
| Open another focus on some work | `open_focus` | Core |
| Reach an existing focus | `send_focus_message` | Core |
| Return to something later | `schedule_attention` | Core |
| Receive [recurring observations](#subscriptions) in this focus | `subscribe` | Core and activities |
| Stop accepting reports for a subscription | `withdraw_subscription` | Core and activities |

Names may repeat. Use the complete reference when addressing a focus or subscription. The core's reference is `core-1`. Names must contain 1–32 Unicode code points and exclude ASCII control characters. Spaces alone are invalid.

## Opening a focus

Call `open_focus` with a short `name` and nonempty `task` describing what this focus should pursue. The runtime appends a number to the name and returns the complete stable reference:

```json
{"result":{"focus_id":"practice-2"}}
```

The activity inherits the core's retained history through the complete round that opened it, including that round's tool results and any existing handover. The task is its first new observation. The core continues its own work. Their histories then grow independently, and the core receives [what the activity says](#activity-expressions).

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

### Callback observations

Scheduled wakeups and [host commands](host.md#command-lifetimes) that outlive their initial call each arrange one callback. Its observation returns to the calling focus with the original reference and source, even after sleep or restart. A callback remains pending until the focus admits its observation. A host command can therefore be finished while its callback still appears in a handover. See the [observation fields](input.md#focus-messages-and-callbacks) and [sampled state](input.md#sampled-state).

The focus admits each callback at most once. The email adapter preserves the first identifiable stored result if the source publishes it again. See [callback delivery](architecture.md#callback-delivery) and [mail retention](running.md#communication-copies).

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

Set up the listener separately and give it the returned `subscription_id`. If an activity runs the listener for `releases-1` on the host, its reports still go to the core. A replacement listener can use the same ID to resume from the saved feed position. See the [listener protocol](subscriptions.md).

An accepted report makes a sleeping focus ready. A working focus can read several reports alongside other observations after its current model/tool round. Reports beyond the input budget stay queued for later turns. See [subscription observations](input.md#subscription-observations).

Subscriptions survive sleep and restart. The focus can find its active subscription IDs in the [state sampled for a handover](input.md#sampled-state).

Any focus can call `withdraw_subscription` with the complete `subscription_id`. The result echoes the ID. The `changed` field is `true` when the call closes an active subscription and `false` for an unknown or previously withdrawn ID. Reports accepted before withdrawal still reach the subscribing focus. Stop the listener separately if needed.

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

## Activity expressions

Each ordinary activity inference that produces assistant text contributes one message for the core. The runtime records that text before executing any accompanying tool calls, so a report can describe an intention whose outcome is still unknown. Tool replies belong to the activity's own exchange. To share a finding, the activity can quote the relevant passage or give the core a [location it can open](resources.md).

Activity messages wait for the core's next ordinary input, including a continuation after tool use. The runtime admits as many as fit the request budget and keeps the rest in order for later inputs. Each admitted report stays attributed to its source activity in the core's history.

One input can carry reports from several activities alongside other observations. An ending can accompany new text or arrive later without repeating admitted messages. The [input contract](input.md#assignments-and-reports) defines grouping and the observation times preserved through waiting and restart.

## Interrupted reasoning

A rejected request, an unusable model response, or an input that cannot fit the context budget can interrupt an activity. The runtime alerts the core with a [`focus_interrupted` observation](input.md#activity-interruptions) giving the reason. The activity keeps its working history, queued observations and registrations. A message from the core, a command completion or a new subscription report can resume it.

## Activity completion

An activity with a pending callback or an active subscription can sleep with its identity and history intact. If its last subscription is withdrawn with reports still queued, the activity remains available to receive them.

Withdraw subscriptions when the activity finishes following their sources. When no work or registrations remain, the activity ends and frees its capacity slot. Its ending calls for the core's attention even if it produced no text.

Completed focus references are not reused, and messages to them return `unknown_focus`. The core can still receive the ended activity's [expressions and ending](input.md#assignments-and-reports) with the original focus ID.
