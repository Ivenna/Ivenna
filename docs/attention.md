# Attention

The core and activities are focuses of one Ivenna. Each focus has its own identity, working history, and event queue. A `focus_id` identifies it in the current roster and retained observations; it survives sleep and restart. Correspondent IDs belong to [external communication](communication.md), not to this internal coordination.

The core directs attention through these [agent tools](../packages/agent/src/tools.json):

| Action | Tool |
| --- | --- |
| Open another focus on some work | `open_focus` |
| Reach an existing focus | `send_focus_message` |
| Return to something later | `schedule_attention` |

Both roles can [communicate externally](communication.md) and [maintain memory](memory.md). Activities also have [host tools](host.md). The [design intent](design.md#core-and-concurrent-attention) explains these roles.

Names are recognition cues and may repeat. The core's reference is `core-1`. Current state supplies addressable focus references and the current focus's pending callback references. Use each complete reference in later calls and when relating observations to earlier work.

Names must contain 1–32 Unicode code points and no ASCII control characters; spaces alone are not accepted.

## Opening a focus

Call `open_focus` with a short `name` and nonempty `task` describing what this focus should pursue. The runtime appends a number to the name and returns the complete stable reference:

```json
{"result":{"focus_id":"practice-2"}}
```

The activity inherits the core's retained history through the complete calling model/tool round, including any existing handover, then receives the task as its first new observation. The core continues its activation; their histories then grow independently.

Inherited records keep their original [focus IDs](input.md#records-and-turns). Core and activity use the same system prompt. The activity receives its own current-state snapshot and available tools. Queued observations and pending callback registrations keep their original destinations; historical tool calls are not replayed.

Malformed arguments or an empty task return `invalid_arguments`. Exhausted focus capacity returns `focus_unavailable`; existing focuses remain addressable. See [configuration](running.md#configuration) for capacity limits.

## Reaching an existing focus

Call `send_focus_message` with a complete `focus_id` from the current roster and nonempty `text`. The core can address any existing focus, including itself. Success confirms durable queue acceptance:

```json
{"result":{"focus_id":"practice-2"}}
```

The observation identifies the sending core as its source; attribution to an earlier source belongs in the text. A sleeping recipient becomes ready, while an active recipient admits the message between complete model/tool rounds, including after a long tool call finishes. Acceptance does not confirm that the recipient has read or acted on the message.

## Returning later

Call `schedule_attention` with a short `name`, an `at_unix_ms` deadline in Unix milliseconds, and nonempty `text` describing what to return to. The arrangement survives restart. Success returns its complete callback reference:

```json
{"result":{"callback_id":"revisit-practice-5"}}
```

The text later reaches the core as a callback observation with source `wakeup`. Past timestamps are due immediately; polling, queue capacity, and scheduling can delay inference. The core can sleep while waiting. Cancellation is unavailable.

## Results and errors

These actions return a JSON text part containing either `result` or an operation `error` with `code` and `message`. Defined failures do not end the runtime:

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

The callback remains pending until its observation is admitted, even if its source has already finished. Source completion, result delivery, and activity completion are separate events.

The current email adapter stores these observations as [callback mail](architecture.md#callback-delivery). See [delivery and admission](architecture.md#event-sources-and-callback-admission) for registration and resumption, and [communication-copy retention](running.md#communication-copies) for the mail's lifetime.

## Activity expressions

New assistant text from ordinary activity inferences is collected in order for the core, including text accompanying tool calls. It is retained before those tools execute, so the text may describe intentions whose effects are not yet known. Reasoning, tool replies, compaction output, and inherited history are not collected as new expressions.

These texts do not activate the core. They accompany ordinary core inputs, including continuations after tools, within the request budget. Information that has not been admitted remains available in recorded order. Admitted reports become retained observations in the core's history; they remain attributed to their source activity.

One input can carry reports from several activities alongside other observations. An ending can accompany new text or arrive later without repeating admitted messages. The [input contract](input.md#assignments-and-reports) defines grouping and the observation times preserved through waiting and restart.

## Activity completion

An activity response without tool calls returns control to the runtime. Queued observations continue the activation before it can complete. If its queue is empty but callback registrations remain pending, the activity sleeps with its identity and history retained. A host completion or focus message can resume it. Waiting for a tool instead keeps the current activation and context in place while other focuses advance.

If the queue is empty and no callback registrations remain, a response without tool calls ends the focus and releases its capacity slot. The runtime records its ending, making the core ready even if no new text was produced. An ending establishes focus completion; task success depends on the available evidence.

Completed focus references are not reused, and messages to them return `unknown_focus`. The current roster shows which focuses remain addressable. Reports keep their source IDs and remain available for core admission after the source focus has ended.
