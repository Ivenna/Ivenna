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

A channel hands each message to one waiting receive request from a local program. The channel holds no queue between reads. Ivenna can open a channel before the program starts and give the same ID to a replacement receiver.

### Opening a channel

Any focus can call `open_channel`. Give it a name and a description of the channel's purpose and the text the receiver expects. See [names and references](input.md#names-and-references).

```json
{"name":"task-input","description":"Receives the absolute path of each CSV file ready for import."}
```

```json
{"result":{"channel_id":"task-input-18"}}
```

Pass the complete `channel_id` to the receiving program and use it to send or close the channel. The description gives the ID context in a later handover. See [sampled state](input.md#sampled-state) for which channels each focus sees.

### Receiving from a channel

Run `ivenna receive CHANNEL_ID` to wait for one message. This example runs in an Ivenna host command. See the [command environment](host.md#command-environment) and [receiver setup](running.md#channel-receivers).

```sh
channel_id='task-input-18'
"$IVENNA" receive "$channel_id"
```

Add `--timeout MS` to limit the wait to a positive number of milliseconds. Each single-read outcome writes one JSON line to stdout and exits with status 0.

| JSON on stdout | Meaning |
| --- | --- |
| `{"status":"message","text":"/work/ready.csv"}` | One message was read. |
| `{"status":"timeout"}` | The wait ended before a message arrived. |
| `{"status":"closed"}` | The channel closed while the read was waiting. |

Use `--follow` to write successive `message` records, one JSON line per message. The command exits with status 0 when it observes the channel close. See [closing a channel](#closing-a-channel).

```sh
"$IVENNA" receive "$channel_id" --follow | ./handle-messages
```

Here `handle-messages` reads JSON lines from stdin. The `receive` command flushes each line before requesting the next read. A full pipe delays that request. In that gap, a send can return `channel_would_block` if no other receiver is waiting.

If the output pipe closes during a wait or write, either mode exits with status 0. An unknown ID on the initial request or an unavailable channel service produces a diagnostic on stderr and exit status 1. Run `ivenna receive --help` for syntax and limits.

### Sending to a channel

While a program is waiting to receive, call `send` with the complete ID in `to.channel_id` and up to 4,096 UTF-8 bytes of text.

```json
{"to":{"channel_id":"task-input-18"},"text":"/work/ready.csv"}
```

`send` returns without waiting for a receiver. The `accepted` status confirms that the runtime handed the message to a waiting receive request. A subscription report can tell a focus how the program handled it. See [reporting after a channel read](subscriptions.md#reporting-after-a-channel-read).

```json
{"result":{"channel_id":"task-input-18","status":"accepted"}}
```

| Send error | Meaning |
| --- | --- |
| `channel_would_block` | The message is unsent and unqueued. The result can arrive before the runtime checks the ID. You can retry when a receiver is waiting. |
| `unknown_channel` | The lookup found no open channel for the supplied ID. |
| `channel_message_too_long` | The text exceeds the channel's message limit. |

### Closing a channel

Either role can call `close_channel` with a complete channel ID.

```json
{"channel_id":"task-input-18"}
```

```json
{"result":{"channel_id":"task-input-18","changed":true}}
```

Closing the channel retires its ID. A waiting single read reports `closed`, and a matched read can finish. A follower between reads observes the close on its next request. Closing a channel that is already absent returns `changed: false`.

### Channel lifetimes

A channel stays open when its readers exit or its opening focus ends. A channel whose opening activity has ended expires when the kernel stops.

When the kernel restarts, it reopens saved channels whose opening focuses are restored. Each keeps its ID and any saved description. A receiving program starts a new read with the same ID. The restored channel starts with no pending reads or messages, so a send can return `channel_would_block` until a receiver is waiting. See [receiver deployment](running.md#channel-receivers).
