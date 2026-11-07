# Communication

Ivenna communicates externally through `send_message` and internally through session messages, reports, and callbacks. Correspondent IDs identify people and programs; session IDs identify Ivenna's separate working contexts. External correspondence enters the core. For sending messages to Ivenna, see the [usage guide](usage.md).

## Correspondents and IDs

Each [incoming message](input.md#incoming-messages) records the correspondent IDs it came `from` and its free-form text. If `operator` relays Alice's words, `from` is `[operator]`; the text carries that attribution and context. The model relates the message to its ongoing understanding and decides whether to respond.

Retained observations, sending exchanges, and handovers preserve correspondent IDs and their context. Outgoing arguments record chosen recipients and text; results record submission outcomes.

## Sending a message

Both core and activity sessions can call `send_message`. Its [declaration](../packages/agent/src/tools.json) defines two required arguments:

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

## Current email addressing

The [current email adapter](architecture.md#email-boundary) uses the domain of `MAIL_ADDRESS` to resolve correspondent IDs. For `MAIL_ADDRESS=ivenna@ivenna.test`, `operator@ivenna.test` becomes `operator`, and sending to `operator` resolves to that address. IDs remain usable across context unloading and restart with the same configured domain.

The adapter currently supports ASCII dot-atom local parts and ASCII hostname domains. It preserves ID case and ignores case only in the domain when comparing addresses.

Incoming mail must have at least one From address, and every address must map to a supported ID in this domain. Missing, unsupported, or cross-domain From addresses exclude the message from intake.

## Incoming email text

An eligible correspondence email becomes one [`input` observation](input.md#incoming-messages). Its `text` contains the subject, a blank line, and the selected body; an empty subject leaves the body alone. The adapter uses decoded plain text when the message lists a plain-text body, otherwise HTML source. Multiple selected body parts are joined with a newline. Attachments do not enter the observation.

The selected body must be complete and decoded without encoding errors. Unsupported or incomplete bodies are skipped, leaving the original mail copy unchanged. Eligible text enters the observation in full and is subject to [request-budget admission](architecture.md#activation-admission).

## Forking an activity session

Only the core can call `fork_session` with a nonempty `task`. The task specifies what the activity should pursue. Success returns its stable identity:

```json
{"result":{"session_id":2}}
```

The activity inherits the core's retained history through the complete calling model/tool round, including any existing handover, then receives the task as its first new observation. The core continues its activation; their histories then grow independently.

Inherited records keep their original [session IDs](input.md#records-and-turns). The activity receives its own current-state snapshot and tools. Queued observations, callback registrations, and wakeup schedules keep their original destinations; historical tool calls are not replayed.

Each activity activation's final text reaches the core automatically as a [report](input.md#assignments-and-reports). A sleeping activity retains its history and can continue through a session message from the core, a callback, or a wakeup.

An empty task or malformed arguments return `invalid_arguments`. Exhausted session capacity or core report capacity returns `fork_unavailable`; existing sessions remain addressable. See [configuration](running.md#configuration) for capacity limits.

## Session communication and wakeups

The [agent tools](../packages/agent/src/tools.json) distinguish core coordination from self-scheduled wakeups:

| Tool | Available to | Arguments | Example success |
| --- | --- | --- | --- |
| `send_session_message` | Core | `session_id`, nonempty `text` | `{"result":{"session_id":2}}` identifies the recipient whose queue accepted the observation |
| `wakeup` | Core and activity | `at_unix_ms`, nonempty `text` | `{"result":{"callback_id":5}}` identifies a scheduled observation for the calling session |

`send_session_message` queues an observation for an existing session and confirms durable queue acceptance. The observation identifies the core as its sender; attribution to an earlier source belongs in the message text. A sleeping recipient wakes, while a running recipient admits the message between complete model/tool rounds. Session IDs survive sleep, context unloading, and restart.

`wakeup` retains its text and deadline across restart and returns the text to the calling session. Past timestamps are due immediately; polling, queue capacity, and scheduling can delay inference. The session can sleep while waiting. Cancellation is unavailable.

The tools report defined failures without ending the runtime:

| Code | Operation and meaning |
| --- | --- |
| `invalid_arguments` | Either tool received arguments that do not match its parameters |
| `unknown_tool` | The tool is unavailable to the calling session |
| `unknown_session` | The message's recipient session does not exist |
| `session_queue_full` | The message's recipient cannot currently accept another event |
| `callback_unavailable` | The calling session has reached its pending-callback limit |

See [configuration](running.md#configuration) for capacity limits and [session messages and callbacks](input.md#session-messages-and-callbacks) for observation fields. Infrastructure failures follow the [availability contract](design.md#runtime-availability).

## Callback mail

Background host commands and wakeups register an ID and receiving session before producing results. Callbacks keep that destination for their lifetime and arrive through durable JMAP mailbox delivery, independently of SMTP reception. The model relates each result to its initiating tool exchange by ID.

Publication reuses the first identifiable result while its copy and metadata remain [retained in the account](running.md#communication-copies). Admission persists the observation once; later copies are retired without another observation. Unknown IDs fail explicitly. See [callback delivery and admission](architecture.md#event-sources-and-callback-admission) for these guarantees and [background commands](host.md#background-commands) for process interruption.
