# Communication

`send_message` submits text to people and programs identified by readable IDs. Both core and work sessions can use it, sending zero, one, or several messages while handling their work. An activation's final text remains internal to the core or returns as a report to a work session's parent. For sending messages to Ivenna, see the [usage guide](usage.md).

## Correspondents and IDs

Each [incoming message](input.md#incoming-messages) records the correspondent IDs it came `from` and its free-form text. If `operator` relays Alice's words, `from` is `[operator]`; the text carries that attribution and context. The model relates the message to its ongoing understanding and decides whether to respond.

IDs identify people and programs Ivenna can choose to contact through `send_message`. For example, `alice` can ask Ivenna in the message text to send an update to `support`. The model decides whether to send it and explicitly supplies the recipient IDs.

Retained working history preserves incoming observations and the model/tool exchanges that send messages. Outgoing tool arguments include the chosen `recipients` and text; tool results record submission outcomes. Handovers can preserve correspondent IDs along with the understanding needed for continued interaction.

## Sending a message

The [`send_message` declaration](../packages/agent/src/tools.json) defines two required arguments:

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

The [current email adapter](architecture.md#email-boundary) uses the domain of `MAIL_ADDRESS` to resolve correspondent IDs. For `MAIL_ADDRESS=ivenna@ivenna.test`, `operator@ivenna.test` becomes `operator`, and sending to `operator` resolves to that address. ID case is preserved; domain matching ignores case. IDs remain usable across context release and restart with the same configured domain. The model-facing fields carry ID strings, while the adapter handles full addresses.

IDs use ASCII dot-atom local parts: letters, digits, and the punctuation below, with dots separating nonempty atoms. Leading, trailing, or consecutive dots, quoted or escaped local parts, and non-ASCII local parts are unsupported.

```text
! # $ % & ' * + - / = ? ^ _ ` { | } ~
```

Incoming mail must have at least one From address, and every address must map to a supported ID in this domain. Missing, unsupported, or cross-domain From addresses exclude the message from intake.
