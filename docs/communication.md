# Communication

`send_message` submits text to recipients identified by contact references. Both core and work sessions can use it, sending zero, one, or several messages while handling their work. An activation's final text remains internal to the core or returns as a report to a work session's parent. For sending messages to Ivenna, see the [usage guide](usage.md).

## Contacts

Incoming material and supporting [evidence](input.md#material-and-provenance) can supply contacts independently of their source provenance. Each contact contains:

| Field | Meaning |
| --- | --- |
| `reference` | Opaque recipient reference accepted by `send_message` |
| `description` | Optional human-readable context about that recipient |

A contact reference identifies a recipient independently of the material's source and the current session. References remain usable after the originating material and working context have been released; retain the ones needed for ongoing work in handovers or autonomous memory.

## Sending a message

The [`send_message` declaration](../packages/agent/src/tools.json) defines two required arguments:

| Argument | Meaning |
| --- | --- |
| `recipients` | Nonempty array of contact references |
| `text` | Nonempty message text |

For example, using a reference supplied with incoming material or context:

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
