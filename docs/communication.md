# Communication

The core and its activities use `send` to write to a correspondent, reach a focus, or publish to a feed. Incoming correspondence reaches the core. To write to Ivenna, see the [correspondence guide](usage.md).

## Sending a message

Call `send` with nonempty `text` and one `channel_id`. Copy the complete address from the tool that created the destination or from the [channel catalog](input.md#inference-turns).

| Address | Destination | Successful result |
| --- | --- | --- |
| `ivenna:/correspondent/<id>` | A [registered correspondent](#writing-to-a-correspondent) | `channel_id` and submission `reference` |
| `ivenna:/focus/<id>` | An [existing focus](attention.md#reaching-an-existing-focus) | `channel_id` |
| `ivenna:/feed/<id>` | An [open feed](#feeds) | `channel_id` and message `sequence` |

Addresses are case-sensitive and local to the instance. The final path segment encodes the correspondent, focus, or feed ID. ASCII letters, digits, `-`, `.`, `_`, and `~` appear as written. Other UTF-8 bytes use `%` followed by two uppercase hexadecimal digits. IDs exclude ASCII controls. For example, the feed ID `notes/release-1` gives the address `ivenna:/feed/notes%2Frelease-1`.

Tool errors carry `error.code` and `error.message`. Malformed arguments, including invalid addresses and values outside the documented bounds, return `invalid_arguments`.

## Correspondents and IDs

An incoming observation's `from` field contains the senders' channel addresses. If the operator relays Alice's words, the operator's address identifies the sender and the text can attribute the words to Alice. For replies, choose a registered address from `current.channels.correspondents`. See [incoming message fields](input.md#incoming-messages).

### Writing to a correspondent

```json
{"channel_id":"ivenna:/correspondent/operator","text":"The updated files are ready for review."}
```

The result confirms that the service accepted the submission for delivery and includes its reference. Delivery can still fail afterward.

```json
{"result":{"channel_id":"ivenna:/correspondent/operator","reference":"<submission-reference>"}}
```

| Correspondence error | Meaning |
| --- | --- |
| `invalid_recipient` | The ID is outside the deployment's permitted correspondence destinations. The tool stops before preparing the message. |
| `not_submitted` | Preparation stopped before the tool attempted submission. |
| `submission_unknown` | The tool attempted submission and could not confirm the outcome. The service may already have accepted the message, so sending it again could produce a duplicate. |

### Current email addressing

The email adapter uses the mailbox's local part as its correspondent ID. For an instance in `ivenna.test`, it presents `operator@ivenna.test` as `ivenna:/correspondent/operator`. To send to that channel, the adapter uses the exact mailbox registered for it and prepares a standalone email with subject `Ivenna` and the supplied text as its body. See the [mail service setup](running.md#mail-service) and [email boundary](architecture.md#email-boundary).

The adapter supports ASCII dot-atom local parts and ASCII hostname domains. The local part is case-sensitive. The domain is compared case-insensitively.

Incoming mail needs at least one From address, with every From address supported and in the instance's domain. Registered mailboxes follow the same address syntax and domain rules. See [mail intake](running.md#mail-intake).

#### Incoming email text

The observation's `text` contains the subject, a blank line, and the complete decoded body. An empty subject leaves just the body. The adapter selects plain-text parts when the message lists them, otherwise HTML source. It joins the selected parts with newlines and skips attachments. See [sharing material](usage.md#sharing-material-to-read) and [mail intake](running.md#mail-intake).

## Feeds

A feed keeps an ordered sequence of messages. It belongs to the instance, outlives its creating focus, and survives restart. Use its `channel_id` to publish and its `feed_id` to read or close it.

### Creating feeds

Any focus can call `create_feed` with a short `name` and a `description` of what readers can expect. The description is nonblank UTF-8, can span lines, and accepts up to 256 code points. See [names and references](input.md#names-and-references).

```json
{"name":"releases","description":"Release announcements and links to upgrade notes."}
```

```json
{"result":{"feed_id":"releases-1","channel_id":"ivenna:/feed/releases-1"}}
```

The `feed_id` preserves the name and appends a numeric suffix. Creating another feed with the same name produces a different ID. The runtime encodes the feed ID to form its `channel_id`. The channel catalog lists both values and the description for each open feed. See [address encoding](#sending-a-message) and the [channel catalog](input.md#inference-turns).

### Publishing to a feed

Call `send` with the feed's `channel_id`.

```json
{"channel_id":"ivenna:/feed/releases-1","text":"The release is ready for review."}
```

```json
{"result":{"channel_id":"ivenna:/feed/releases-1","sequence":1}}
```

The sequence confirms that Ivenna stored the message for readers. A process interruption can leave the message stored after restart without a saved tool result. Each successful `send` appends a message, so repeating the call can publish the same text again. See [restart behavior](architecture.md#startup-and-interruption).

### Closing feeds

Use `close_feed` with the exact `feed_id` to stop writes. The feed's description and published messages remain readable.

```json
{"feed_id":"releases-1"}
```

The result includes the ID and whether the call closed the feed. Closing an already closed feed returns `changed: false`.

```json
{"result":{"feed_id":"releases-1","changed":true}}
```

### Feed tool errors

| Feed error | Meaning |
| --- | --- |
| `unknown_feed` | No feed matches the supplied ID or the ID encoded in the send address. |
| `feed_closed` | The feed was closed when Ivenna tried to publish. |
| `feed_capacity` | The instance has reached its configured limit for open feeds. |
| `feed_storage_busy` | The feed store is busy. |
| `feed_storage_full` | The feed store ran out of space. |
| `feed_storage_failed` | The store could not confirm the operation. Check the feed's state before trying the write again. |

### Reading feeds

Set `DATA_DIR` to the instance's data directory and pass the `feed_id` from Ivenna as one argument. The command works while the kernel is stopped. See [deploying a feed reader](running.md#feed-readers).

```sh
feed_id='releases-1'
ivenna feed read "$feed_id"
```

On success, `feed read` returns one JSON line. Each page comes from a single snapshot and lists messages in ascending sequence order. `--after` selects messages with a greater sequence. It defaults to `0` and accepts decimal integers from `0` through `9223372036854775807`. `--limit` sets the maximum number of messages to return. It defaults to `100` and accepts `1` through `1000`.

```json
{"feed_id":"releases-1","description":"Release announcements and links to upgrade notes.","closed":false,"messages":[{"sequence":1,"focus_id":"core-1","text":"The release is ready for review.","published_at_unix_ms":1795478400000}],"next_after":1,"has_more":false}
```

The page includes the feed ID, description, and closure state even when `messages` is empty. Each message contains the complete `text`, its `sequence`, the publishing `focus_id`, and the publication time in `published_at_unix_ms`. Sequence numbers can have gaps.

Each reader keeps its own position. After processing the whole page, save `next_after` and use it as `--after` on the next read. It equals the last returned sequence, or the supplied position when the page is empty. If `has_more` is true, read the next page. After processing a page with `closed: true` and `has_more: false`, the reader has caught up with the complete feed. For an open feed, read again later for new messages. A reader that reports back can save its position through a [subscription](subscriptions.md#read-an-ivenna-feed-and-report-back).

The command exits with status `0` on success. The following failures write one JSON string and exit with status `1`.

| Result | Meaning |
| --- | --- |
| `"invalid_request"` | The command is missing an argument or has an invalid option. |
| `"unknown_feed"` | The supplied ID does not exactly match a feed. |
| `"busy"` | The instance database is busy. |
| `"storage_full"` | The instance storage has run out of space. |

If the command exits without a complete page or error string, check stderr for diagnostics.
