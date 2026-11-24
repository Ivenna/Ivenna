# Communication

The core receives incoming correspondence. Both the core and activities can send messages. To write to Ivenna, see the [correspondence guide](usage.md).

## Sending a message

Call `send` with nonempty `text` and a `to` object containing exactly one destination field. Use a complete ID from an observation, a tool result, or a reference shared in a message.

| Field in `to` | Destination | Successful result |
| --- | --- | --- |
| `correspondent_id` | A [registered correspondent](#writing-to-a-correspondent) | `correspondent_id` and submission `reference` |
| `focus_id` | An [existing focus](attention.md#reaching-an-existing-focus) | `focus_id` |
| `channel_id` | An [open channel](#sending-to-a-channel) | `channel_id` and status `accepted` |

Pass IDs as case-sensitive JSON strings, preserving spaces, punctuation, and non-ASCII characters. Each ID has meaning within its instance and destination kind. For example, `to.focus_id` and `to.channel_id` can refer to different destinations with the same ID.

Tool replies contain a JSON `result` or an `error` with `code` and `message`. Malformed arguments return `invalid_arguments`. The runtime resolves the selected destination when `send` runs.

## Correspondents and IDs

An incoming observation's `from` field identifies who sent the email. If the operator relays Alice's words, `from` identifies the operator and the message text can attribute the words to Alice. See [correspondence observations](input.md#incoming-messages).

Ivenna can write to an ID while its mailbox is registered for outgoing correspondence. This applies to replies to incoming mail and to letters Ivenna initiates. The core sees the registered IDs at startup and compaction. See [outgoing registration](running.md#outgoing-correspondents), [startup observations](input.md#startup-and-restart), and [compaction samples](input.md#sampled-state).

### Writing to a correspondent

Pass the registered ID as `to.correspondent_id`.

```json
{"to":{"correspondent_id":"operator"},"text":"The updated files are ready for review."}
```

The result confirms that the service accepted the submission for delivery and includes its reference. Delivery can still fail afterward.

```json
{"result":{"correspondent_id":"operator","reference":"<submission-reference>"}}
```

| Correspondence error | Meaning |
| --- | --- |
| `invalid_recipient` | The ID is unregistered. The tool stops before preparing the message. |
| `not_submitted` | Preparation stopped before the tool attempted submission. |
| `submission_unknown` | The tool attempted submission and could not confirm the outcome. The service may already have accepted the message, so sending it again could produce a duplicate. |

### Current email addressing

The email adapter uses the mailbox's local part as its correspondent ID. For an instance in `ivenna.test`, the ID for `operator@ivenna.test` is `operator`. Sending to that ID uses the exact registered mailbox and produces a standalone email with subject `Ivenna` and the supplied text as its body.

Registered mailboxes and incoming From addresses use ASCII dot-atom local parts and ASCII hostname domains. The adapter compares the local part case-sensitively and the domain case-insensitively. Incoming mail needs at least one From address, and all From addresses must be supported addresses in the instance's domain. See [mail service setup](running.md#mail-service) and [mail intake](running.md#mail-intake).

#### Incoming email text

The observation's `text` contains the subject and body separated by a blank line. With an empty subject, it contains only the body. The adapter selects plain-text parts when available and uses HTML source when the message lists only HTML body parts. It joins selected parts with newlines. To share a file, send an accessible link or include the relevant text in the body. See [sharing material](usage.md#sharing-material-to-read) and [mail intake](running.md#mail-intake).

## Channels

A channel is a named destination for sending text messages to one running host command.

### Opening a channel

An activity starts the receiving program in [messages mode](host.md#receiving-messages-in-a-command). The core or any activity can then call `open_channel` with the returned `command_id` and a [name](input.md#names-and-references). A command can have one channel.

```json
{"name":"task-input","command_id":"worker-17"}
```

```json
{"result":{"channel_id":"task-input-18"}}
```

Use the complete `channel_id` to send messages or close the channel. A focus can share an ID with another focus or reuse one from its [sampled state](input.md#sampled-state). An activity can also find an open channel by [inspecting its command](host.md#continuing-and-controlling-a-command).

| Open error | Meaning |
| --- | --- |
| `unknown_command` | The runtime has no command with this ID. |
| `command_messages_disabled` | The command uses another input mode. |
| `command_input_closed` | The command's message input has closed. |
| `channel_already_open` | This command already has an open channel. |

### Sending to a channel

Call `send` with the complete ID in `to.channel_id` and up to 4,096 UTF-8 bytes of text.

```json
{"to":{"channel_id":"task-input-18"},"text":"Process the next item."}
```

`send` returns without waiting for the command to read. A channel can hold one unread message. The `accepted` status confirms that the runtime made the message available to read.

```json
{"result":{"channel_id":"task-input-18","status":"accepted"}}
```

| Send error | Meaning |
| --- | --- |
| `channel_full` | The previous message is still unread. Retry after the command reads it. |
| `channel_closed` | The message input has closed. |
| `unknown_channel` | The runtime has no channel with this ID. |
| `channel_message_too_long` | The text exceeds the channel's message limit. |
| `channel_busy` | The send could not proceed immediately. Try again. |

### Closing a channel

Either role can call `close_channel` with a complete channel ID.

```json
{"channel_id":"task-input-18"}
```

```json
{"result":{"channel_id":"task-input-18","changed":true}}
```

Closing the channel ends sending. The program can read any pending message before it reaches end of input and keep working afterward. Its message input stays closed for the rest of the command's run. Closing a closed or unknown channel returns `changed: false`.

A channel also closes when its command exits. `send` returns `channel_closed` while the runtime retains the closed channel's command handle and `unknown_channel` after it retires the handle. Channels belong to the runtime in which they open. See [command lifetimes](host.md#command-lifetimes).
