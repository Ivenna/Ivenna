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

A channel lets Ivenna hand text to a waiting local program. Ivenna can open it before the program starts and use the same ID with a replacement.

### Opening a channel

The core or an activity calls `open_channel` with a [name](input.md#names-and-references) and a nonempty `description` of the channel's purpose. The call records the description in the opening focus's working history.

```json
{"name":"task-input","description":"Send the path of each file to process."}
```

```json
{"result":{"channel_id":"task-input-18"}}
```

Pass the complete `channel_id` to the receiving program. Use the same ID to send or close the channel. A focus can share the ID with another focus or find it in a [handover state sample](input.md#sampled-state).

### Receiving from a channel

Run `ivenna receive CHANNEL_ID` on the kernel host under the same OS account. A [host command](host.md#command-environment) can use the inherited `IVENNA` and `DATA_DIR` values. For an independently launched program, set `DATA_DIR` to the running instance's data directory.

```sh
channel_id='task-input-18'
"$IVENNA" receive "$channel_id"
```

`receive CHANNEL_ID` waits for one message. Use `--wait MS` with a positive number of milliseconds to limit the wait. A single read that reaches one of these outcomes writes one JSON line and exits with status 0.

| JSON on stdout | Meaning |
| --- | --- |
| `{"status":"message","text":"/work/ready.csv"}` | One message was read. |
| `{"status":"timeout"}` | The wait ended before a message arrived. |
| `{"status":"closed"}` | The channel closed while the read was waiting. |

`--follow` waits for one message at a time and flushes each `message` record as a JSON line before requesting the next. Closing the channel ends the stream. If the output pipe closes during a wait, either mode exits with status 0 without another record.

When several readers are waiting, one receives each message. An unknown ID or an unavailable channel service produces a diagnostic on stderr and exit status 1. See `ivenna receive --help` for CLI limits.

A shell pipe can hold records while the consumer works. A write that blocks on a full pipe delays the next receive request.

```sh
"$IVENNA" receive "$channel_id" --follow | ./handle-messages
```

Here `handle-messages` reads JSON lines from stdin.

### Sending to a channel

While a program is waiting to receive, call `send` with the complete ID in `to.channel_id` and up to 4,096 UTF-8 bytes of text.

```json
{"to":{"channel_id":"task-input-18"},"text":"/work/ready.csv"}
```

`send` returns immediately. `accepted` confirms that the message reached a waiting read. The program can [report what it did with the message](subscriptions.md#reporting-after-a-channel-read).

```json
{"result":{"channel_id":"task-input-18","status":"accepted"}}
```

| Send error | Meaning |
| --- | --- |
| `channel_no_receiver` | No waiting read matched the send. The send leaves no message behind. Retry when a reader is waiting. |
| `unknown_channel` | The runtime has no open channel with this ID. |
| `channel_message_too_long` | The text exceeds the channel's message limit. |
| `channel_busy` | A temporary runtime condition prevented the handoff. Retry the send. |

### Closing a channel

Either role can call `close_channel` with a complete channel ID.

```json
{"channel_id":"task-input-18"}
```

```json
{"result":{"channel_id":"task-input-18","changed":true}}
```

Closing the channel retires its ID and ends waiting reads with `closed`. A read that already matched a send can finish. Later sends and new reads find the ID unknown. Closing an unknown ID returns `changed: false`.

A channel stays open when its readers exit or the opening focus ends. It lasts until a focus closes it or the runtime stops. After restart, open a new channel and give the new ID to the receiving program.
