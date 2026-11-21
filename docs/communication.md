# Communication

Correspondence connects Ivenna with people and programs through correspondent IDs. This guide covers incoming observations and explicit sending through `send_message`. Internal focus coordination belongs to [Attention](attention.md); for sending messages to Ivenna, see the [usage guide](usage.md).

Incoming correspondence enters the core. Both core and activity sessions can send messages through `send_message`. Assistant text and activity reports remain internal unless Ivenna chooses to send them.

## Correspondents and IDs

Each [incoming message](input.md#incoming-messages) records the correspondent IDs it came `from` and its free-form text. If `operator` relays Alice's words, `from` is `[operator]`; any attribution to Alice belongs in the text. Receiving a message does not require a response.

Outgoing calls identify their chosen recipients; results record submission outcomes. Ivenna chooses what to retain about correspondence in its understanding and shared memory.

The communication interface has no operation for searching past correspondence. Stored message copies follow the [communication-copy retention policy](running.md#communication-copies).

## Sending a message

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

## Current email addressing

The [current email adapter](architecture.md#email-boundary) uses the domain of `MAIL_ADDRESS` to resolve correspondent IDs. For `MAIL_ADDRESS=ivenna@ivenna.test`, `operator@ivenna.test` becomes `operator`, and sending to `operator` resolves to that address. IDs remain usable across context unloading and restart with the same configured domain.

The adapter currently supports ASCII dot-atom local parts and ASCII hostname domains. It preserves ID case and ignores case only in the domain when comparing addresses.

The adapter maps message From addresses to correspondent IDs, relying on the [mail service](running.md#mail-service) to establish sender identity. Incoming mail must have at least one From address, and every address must map to a supported ID in this domain. Missing, unsupported, or cross-domain From addresses exclude the message from intake.

## Incoming email text

An eligible correspondence email becomes one [`input` observation](input.md#incoming-messages). Its `text` contains the subject, a blank line, and the selected body; an empty subject leaves the body alone. The adapter uses decoded plain text when the message lists a plain-text body, otherwise HTML source. Multiple selected body parts are joined with a newline. Attachments do not enter the observation.

The selected body must be complete and decoded without encoding errors. Unsupported or incomplete bodies are skipped, leaving the original mail copy unchanged. Eligible text enters the observation in full and is subject to [request-budget admission](architecture.md#activation-admission).
