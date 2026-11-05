# Communication

`send_message` submits text to recipients identified by contact references. Both core and work sessions can use it. Each activation can send zero, one, or several messages; final text completes core work or returns a branch result to its parent. For sending messages to Ivenna, see the [usage guide](usage.md).

## Contacts

An [input or evidence record](input.md#content-source-and-context) can supply contacts independently of its source provenance. Each contact contains:

| Field | Meaning |
| --- | --- |
| `reference` | Opaque recipient reference accepted by `send_message` |
| `description` | Optional human-readable context about that recipient |

A contact reference identifies a recipient independently of the input's source and the current session. References remain usable after the originating input and working context have been released; retain the ones needed for ongoing work in handovers or autonomous memory.

Native addresses and delivery protocols belong to the communication adapter. The current [email adapter](architecture.md#email-boundary-and-source-materials) persists contact mappings in the deployment's data directory.

## Sending a message

The [`send_message` declaration](../packages/agent/src/tools.json) defines two required arguments:

| Argument | Meaning |
| --- | --- |
| `recipients` | Nonempty array of contact references |
| `text` | Nonempty message text |

For example, using a reference supplied by an observation:

```json
{
  "recipients": ["<contact-reference>"],
  "text": "The analysis is complete. The updated files are ready for review."
}
```

Each invocation submits one message to the specified recipients.

Success returns a submission reference:

```json
{"result":{"reference":"<submission-reference>"}}
```

The result confirms submission through the adapter. It does not establish final recipient delivery. An unavailable recipient reference returns an `unknown_recipient` tool error; invalid argument structure returns `invalid_arguments`. Communication infrastructure or submission failures end the runtime under the [availability contract](design.md#runtime-availability).
