# Communication

Incoming correspondence from people and programs enters Ivenna's core. Both the core and its activities can write to correspondents through `send_message`. Assistant text and activity reports stay internal unless Ivenna chooses to send them. See the [usage guide](usage.md) for writing to Ivenna and [Attention](attention.md) for communication between focuses.

## Correspondents and IDs

Each [incoming message](input.md#incoming-messages) records the correspondent IDs it came `from` and its free-form text. If `operator` relays Alice's words, `from` contains only `operator`. The text can identify Alice as the original speaker. Receiving a message does not require a response.

Ivenna chooses what to retain about correspondence in its understanding and shared memory. The communication interface has no operation for searching past correspondence. Stored copies follow the [communication-copy retention policy](running.md#communication-copies).

## Sending a message

Call `send_message` with one or more correspondent IDs in `recipients` and nonempty `text`. The email adapter prepares one standalone message addressed to everyone listed, with subject `Ivenna` and the supplied text as its body. See the [tool declaration](../packages/agent/src/tools.json).

```json
{
  "recipients": ["operator"],
  "text": "The analysis is complete. The updated files are ready for review."
}
```

The tool returns a reference when it can confirm that the mail service accepted the message for delivery. Delivery to a recipient can still fail afterward.

```json
{"result":{"reference":"<submission-reference>"}}
```

Tool errors carry an `error.code` and a human-readable `error.message`.

| `error.code` | Meaning |
| --- | --- |
| `invalid_arguments` | The call could not be parsed, the recipient list was empty, or the message text was empty. |
| `invalid_recipient` | At least one recipient ID was unsupported. The tool submitted no message. |
| `not_submitted` | Preparation stopped before the tool attempted submission. |
| `submission_unknown` | The tool attempted submission and could not confirm the outcome. The service may already have accepted the message, so sending it again could produce a duplicate. |

If the runtime loses required mail access, it closes reception and stops. See [runtime availability](design.md#runtime-availability).

## Current email addressing

The [current email adapter](architecture.md#email-boundary) uses the domain of `MAIL_ADDRESS` to resolve correspondent IDs. For `MAIL_ADDRESS=ivenna@ivenna.test`, `operator@ivenna.test` becomes `operator`, and sending to `operator` resolves to that address. IDs remain usable across context unloading and restart with the same configured domain.

The adapter currently supports ASCII dot-atom local parts and ASCII hostname domains. It preserves ID case and ignores case only in the domain when comparing addresses.

The adapter maps message From addresses to correspondent IDs, relying on the [mail service](running.md#mail-service) to establish sender identity. Incoming mail must have at least one From address, and every address must map to a supported ID in this domain. Missing, unsupported, or cross-domain From addresses exclude the message from intake.

## Incoming email text

An eligible correspondence email becomes one [`input` observation](input.md#incoming-messages). Its `text` contains the subject, a blank line, and the selected body; an empty subject leaves the body alone. The adapter uses decoded plain text when the message lists a plain-text body, otherwise HTML source. Multiple selected body parts are joined with a newline. Attachments do not enter the observation.

The selected body must be complete and decoded without encoding errors. Unsupported or incomplete bodies are skipped, leaving the original mail copy unchanged. Eligible text enters the observation in full and is subject to [request-budget admission](architecture.md#activation-admission).
