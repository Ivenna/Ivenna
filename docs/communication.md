# Communication

Correspondent IDs identify people and programs; session IDs identify Ivenna's separate working contexts. This guide covers [external correspondence](#external-correspondence) through `send_message` and [session coordination](#session-coordination) through forks, messages, wakeups, host completion observations, and activity reports. For sending messages to Ivenna, see the [usage guide](usage.md).

## External correspondence

Incoming correspondence enters the core. Both core and activity sessions can send messages.

### Correspondents and IDs

Each [incoming message](input.md#incoming-messages) records the correspondent IDs it came `from` and its free-form text. If `operator` relays Alice's words, `from` is `[operator]`; the text carries that attribution and context. The model relates the message to its ongoing understanding and decides whether to respond.

Retained observations, sending exchanges, and handovers preserve correspondent IDs and their context. Outgoing arguments record chosen recipients and text; results record submission outcomes.

### Sending a message

The `send_message` [declaration](../packages/agent/src/tools.json) defines two required arguments:

| Argument | Meaning |
| --- | --- |
| `recipients` | Nonempty array of correspondent IDs |
| `text` | Nonempty message text |

For example:

```json
{
  "recipients": ["operator"],
  "text": "The analysis is complete. The updated files are ready for review."
}
```

With the current email adapter, each successful invocation submits one standalone message to the specified recipients, with subject `Ivenna` and the supplied `text` as its body.

Success returns a submission reference:

```json
{"result":{"reference":"<submission-reference>"}}
```

The email adapter returns this reference after confirming submission and moving its sending copy to Trash. The result does not establish final recipient delivery. See [communication-copy retention](running.md#communication-copies) for the copy's lifetime.

An unsupported recipient ID returns an `invalid_recipient` tool error; invalid argument structure returns `invalid_arguments`. Communication infrastructure, submission, or retirement failures end the runtime under the [availability contract](design.md#runtime-availability).

### Current email addressing

The [current email adapter](architecture.md#email-boundary) uses the domain of `MAIL_ADDRESS` to resolve correspondent IDs. For `MAIL_ADDRESS=ivenna@ivenna.test`, `operator@ivenna.test` becomes `operator`, and sending to `operator` resolves to that address. IDs remain usable across context unloading and restart with the same configured domain.

The adapter currently supports ASCII dot-atom local parts and ASCII hostname domains. It preserves ID case and ignores case only in the domain when comparing addresses.

The adapter maps message From addresses to correspondent IDs, relying on the [mail service](running.md#mail-service) to establish sender identity. Incoming mail must have at least one From address, and every address must map to a supported ID in this domain. Missing, unsupported, or cross-domain From addresses exclude the message from intake.

### Incoming email text

An eligible correspondence email becomes one [`input` observation](input.md#incoming-messages). Its `text` contains the subject, a blank line, and the selected body; an empty subject leaves the body alone. The adapter uses decoded plain text when the message lists a plain-text body, otherwise HTML source. Multiple selected body parts are joined with a newline. Attachments do not enter the observation.

The selected body must be complete and decoded without encoding errors. Unsupported or incomplete bodies are skipped, leaving the original mail copy unchanged. Eligible text enters the observation in full and is subject to [request-budget admission](architecture.md#activation-admission).

## Session coordination

### Forking an activity session

Only the core can call `fork_session` with a nonempty `task`. The task specifies what the activity should pursue. Success returns its stable identity:

```json
{"result":{"session_id":2}}
```

The activity inherits the core's retained history through the complete calling model/tool round, including any existing handover, then receives the task as its first new observation. The core continues its activation; their histories then grow independently.

Inherited records keep their original [session IDs](input.md#records-and-turns). The activity receives its own current-state snapshot and tools. Queued observations and pending callback registrations keep their original destinations; historical tool calls are not replayed.

An empty task or malformed arguments return `invalid_arguments`. Exhausted session capacity returns `fork_unavailable`; existing sessions remain addressable. See [configuration](running.md#configuration) for capacity limits.

### Session communication and wakeups

The [agent tools](../packages/agent/src/tools.json) expose session messaging and self-scheduled wakeups to the core:

| Tool | Available to | Arguments | Example success |
| --- | --- | --- | --- |
| `send_session_message` | Core | `session_id`, nonempty `text` | `{"result":{"session_id":2}}` identifies the recipient whose queue accepted the observation |
| `wakeup` | Core | `at_unix_ms`, nonempty `text` | `{"result":{"callback_id":5}}` identifies a scheduled observation for the core |

`send_session_message` queues an observation for an existing session and confirms durable queue acceptance. The observation identifies the core as its sender; attribution to an earlier source belongs in the message text. A sleeping recipient wakes, while an active recipient admits the message between complete model/tool rounds, including after a long tool call finishes. Session IDs survive sleep, context unloading, and restart.

`wakeup` retains its text and deadline across restart and returns the text to the core. Past timestamps are due immediately; polling, queue capacity, and scheduling can delay inference. The core can sleep while waiting. Cancellation is unavailable.

The tools report defined failures without ending the runtime:

| Code | Operation and meaning |
| --- | --- |
| `invalid_arguments` | Either tool received arguments that do not match its parameters |
| `unknown_tool` | The tool is unavailable to the calling session |
| `unknown_session` | The message's recipient session does not exist |
| `session_queue_full` | The message's recipient cannot currently accept another event |

See [configuration](running.md#configuration) for capacity limits and [session messages and callbacks](input.md#session-messages-and-callbacks) for observation fields. Infrastructure failures follow the [availability contract](design.md#runtime-availability).

### Callback mail

Wakeups and [host commands](host.md#command-lifetimes) that outlive their initial call use durable JMAP callback mail, independently of SMTP reception. Each registration binds one observation and its source to the receiving session. The destination survives sleep, context unloading, and restart, and the observation is admitted at most once even if several mail copies arrive. Repeated publication preserves the first identifiable stored result. See [delivery and admission](architecture.md#event-sources-and-callback-admission) for the mechanism and [communication-copy retention](running.md#communication-copies) for the mail's lifetime.

### Activity reports

New assistant text from ordinary activity inferences is collected in order for the core, including text accompanying tool calls. It is retained before those tools execute, so the text may describe intentions whose effects are not yet known. Reasoning, tool replies, compaction output, and inherited history are not collected as new expressions.

These texts do not activate the core. They accompany ordinary core inputs, including continuations after tools, within the request budget. Information that has not been admitted remains available in recorded order. Admitted reports become retained observations in the core's history; they remain attributed to their source activity.

One input can carry reports from several activities alongside other observations. An ending can accompany new text or arrive later without repeating admitted messages. The [input contract](input.md#assignments-and-reports) defines grouping and the observation times preserved through waiting and restart.

### Activity completion

An activity response without tool calls returns control to the runtime. Queued observations continue the activation before it can complete. If its queue is empty but callback registrations remain pending, the activity sleeps with its identity and history retained. A host completion or session message from the core can resume it. Waiting for a tool instead keeps the current activation and context in place while other sessions advance.

If the queue is empty and no callback registrations remain, a response without tool calls ends the session and releases its registered-session slot. The runtime records its ending, making the core ready even if no new text was produced. This establishes session completion; a host callback reports a command outcome or diagnostic. Ivenna assesses task success from the available evidence.

Completed session IDs are not reused, and messages to them return `unknown_session`. The current session roster shows which activities remain addressable. Reports keep their source IDs and remain available for core admission after the source session has ended.
