# Communication

The core receives incoming correspondence. Both the core and activities can send messages. To write to Ivenna, see the [correspondence guide](usage.md).

## Sending a message

Call `send` with nonempty `text` and a `to` object containing exactly one destination field. Use a complete ID from an observation, a handover, a tool result, or a message.

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

A channel hands each message to one waiting receive request from a local program. The channel holds no queue between reads. Ivenna can open a channel before the program starts and give the same ID to a replacement receiver.

### Opening a channel

Any focus can call `open_channel` with a name and a nonempty description of the channel's purpose and what each message should contain. See [names and references](input.md#names-and-references).

```json
{"name":"task-input","description":"Receives the absolute path of each CSV file ready for import."}
```

```json
{"result":{"channel_id":"task-input-18"}}
```

The channel becomes available when the runtime confirms the checkpoint that saves its registration and tool result. Give the receiving program the complete `channel_id`. Use the same ID to send or close the channel. The description identifies its purpose in a later handover. See [sampled state](input.md#sampled-state) for which channels each focus sees.

If saving the checkpoint fails, the runtime stops with the channel inactive. On restart it restores the channel and its tool result together if the selected checkpoint includes them. See [recovering from a size rejection](running.md#working-history-limits) and [checkpoint selection on restart](architecture.md#saving-and-restoration).

### Receiving from a channel

Run `ivenna channel receive CHANNEL_ID` before sending to the channel. An Ivenna host command can use the executable in `IVENNA`. For an independent receiver, see [receiver setup](running.md#channel-receivers).

```sh
channel_id='task-input-18'
"$IVENNA" channel receive "$channel_id" | ./handle-messages
```

Here `handle-messages` reads one JSON object per line from the receiver's stdout.

```json
{"text":"/work/ready.csv"}
```

The receiver flushes each line before requesting the next message. If the output pipe is full, the receiver stays connected while it waits to write. A send can return `channel_would_block` until a receiver can take the message. See [send outcomes](#sending-to-a-channel).

After Ivenna closes the channel, the receiver writes any message already handed off and exits with status 0 when it reads the closing reply. Closing the receiver's output pipe also ends the process with status 0. If the pipe closes during a write, the reader may receive a partial line.

An unknown channel ID, a failed connection, or a lost connection before the closing reply produces an error on stderr and exit status 1. The kernel can disconnect before sending the closing reply if the socket stays full. See [local channel handling](architecture.md#local-channels).

### Sending to a channel

Call `send` with the complete ID in `to.channel_id` and up to 4,096 UTF-8 bytes of text.

```json
{"to":{"channel_id":"task-input-18"},"text":"/work/ready.csv"}
```

`send` attempts an immediate handoff to one waiting receiver. The `accepted` status confirms the handoff. The receiving program can report how it handled the message through a subscription. See [reporting after a channel read](subscriptions.md#reporting-after-a-channel-read).

```json
{"result":{"channel_id":"task-input-18","status":"accepted"}}
```

If the call returns one of these errors, the message stays unsent and unqueued.

| Send error | Meaning |
| --- | --- |
| `channel_no_receiver` | No receiver was connected when the runtime checked. Start or reconnect a receiver before retrying. |
| `channel_would_block` | The channel service was busy or connected receivers could not take the message yet. Retry when a receiver is waiting. |
| `unknown_channel` | No open channel matches the supplied ID. |
| `channel_message_too_long` | The text exceeds the channel's message limit. |

### Closing a channel

Either role can call `close_channel` with a complete channel ID.

```json
{"channel_id":"task-input-18"}
```

```json
{"result":{"channel_id":"task-input-18","changed":true}}
```

The runtime confirms retirement before ending [receiver connections](#receiving-from-a-channel). Closing an ID that is already absent returns `changed: false`.

### Channel lifetimes

A channel stays open when its readers exit or its opening focus ends. Use `close_channel` to retire its ID.

An open channel keeps its ID and any saved description across restart. A receiver can reconnect with that ID once the kernel is running again. The focus's [current input](input.md#channel-receivers-and-subscription-listeners) can list channels with no connected receiver.
