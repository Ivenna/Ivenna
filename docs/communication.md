# Communication

Incoming correspondence from people and programs enters Ivenna's core. The core and its activities use `send` to write to a correspondent, reach a focus, or publish to a feed. To write to Ivenna, see the [correspondence guide](usage.md).

## Correspondents and IDs

An incoming observation identifies the correspondent who sent it. If `operator` relays Alice's words, `from` contains `ivenna:/correspondent/operator`, and the text can attribute those words to Alice. The channel catalog lists the correspondents registered to receive messages. See the [incoming message fields](input.md#incoming-messages).

## Sending a message

Call `send` with nonempty `text` and one complete `channel_id`. Use the address from the [channel catalog](input.md#inference-turns) or from the tool that created the destination. It identifies a destination within the current Ivenna instance.

| Address | Destination | Successful result |
| --- | --- | --- |
| `ivenna:/correspondent/<id>` | One registered correspondent | `channel_id` and submission `reference` |
| `ivenna:/focus/<id>` | An [existing focus](attention.md#reaching-an-existing-focus) | `channel_id` |
| `ivenna:/feed/<name>-<serial>` | An open feed | `channel_id` and message `sequence` |

Address prefixes and keys are case-sensitive. Keys use UTF-8 with ASCII control characters excluded. Keep ASCII letters, digits, `-`, `.`, `_`, and `~` as written. Encode other bytes as `%` followed by two uppercase hexadecimal digits. For example, `notes/release-1` becomes `notes%2Frelease-1`.

Tool errors carry `error.code` and `error.message`. Malformed arguments, including invalid addresses and values outside the documented bounds, return `invalid_arguments`.

### Writing to a correspondent

```json
{"channel_id":"ivenna:/correspondent/operator","text":"The updated files are ready for review."}
```

The result includes a reference once Ivenna confirms the service accepted the submission. Delivery can still fail afterward.

```json
{"result":{"channel_id":"ivenna:/correspondent/operator","reference":"<submission-reference>"}}
```

| Correspondence error | Meaning |
| --- | --- |
| `invalid_recipient` | The ID is outside the deployment's permitted correspondence destinations. The tool stops before preparing the message. |
| `not_submitted` | Preparation stopped before the tool attempted submission. |
| `submission_unknown` | The tool attempted submission and could not confirm the outcome. The service may already have accepted the message, so sending it again could produce a duplicate. |

## Feeds

A feed keeps an ordered sequence of messages. Any focus can call `create_channel` with a short `name` and a `description` of what belongs in the feed. The description is nonblank UTF-8 up to 256 code points and can span lines. See [names and references](input.md#records-and-turns) for the name format.

```json
{"name":"releases","description":"Release announcements and links to upgrade notes."}
```

The result contains a complete `channel_id`, such as `ivenna:/feed/releases-1`. Creating another feed with the same name issues a new address. Feeds belong to the instance, outlive their creating focus, and survive restart. Open feeds appear with their descriptions in the [channel catalog](input.md#inference-turns).

Use `send` to publish to the feed.

```json
{"channel_id":"ivenna:/feed/releases-1","text":"The release is ready for review."}
```

```json
{"result":{"channel_id":"ivenna:/feed/releases-1","sequence":1}}
```

The sequence confirms that Ivenna stored the message for readers. A process interruption can leave a committed message without a saved tool result. Restart preserves the publication. Each new successful `send` creates a new message, even when the text is the same. See [restart behavior](architecture.md#startup-and-interruption).

### Closing feeds

Use `close_channel` with the complete feed `channel_id` to stop writes. The feed's description and published messages remain readable. A close returns the ID and `changed: true` on the first closure, or `changed: false` if already closed.

### Feed tool errors

| Feed error | Meaning |
| --- | --- |
| `unknown_channel` | The supplied feed address has no matching feed. |
| `channel_closed` | The feed was closed when Ivenna tried to publish. |
| `channel_capacity` | The instance has reached its configured limit for open feeds. |
| `channel_managed` | The close request addressed a focus or correspondent channel. |
| `channel_storage_busy` | The feed store is busy. |
| `channel_storage_full` | The feed store ran out of space. |
| `channel_storage_failed` | The store could not confirm the operation. Check the feed's state before trying the write again. |

### Reading feeds

Configure the reader with the complete `channel_id` Ivenna gives it. Set `DATA_DIR` to the directory of that instance. The reader can use the same address while the kernel is stopped. See [deploying a feed reader](running.md#feed-readers).

```sh
feed_id='ivenna:/feed/releases-1'
ivenna feed read "$feed_id"
```

`feed read` returns one JSON line with a page from one snapshot. `--after` defaults to `0` and accepts a decimal sequence from `0` through `9223372036854775807`. The page includes messages with a greater sequence in ascending order. `--limit` defaults to `100` and accepts `1` through `1000`.

```json
{"channel_id":"ivenna:/feed/releases-1","description":"Release announcements and links to upgrade notes.","closed":false,"messages":[{"sequence":1,"focus_id":"core-1","text":"The release is ready for review.","published_at_unix_ms":1795478400000}],"next_after":1,"has_more":false}
```

Every page includes the feed's address, description, and closure state, including when `messages` is empty. The array keeps each message whole, including any newlines in its `text`. `focus_id` identifies the publishing focus, and `published_at_unix_ms` gives the time Ivenna handled the send in Unix milliseconds. Sequence numbers can have gaps.

Each reader keeps its own position. After processing a page, save `next_after` and pass it as `--after` on the next read. It is the last returned sequence or, for an empty page, the position supplied on the read. If `has_more` is true, read another page. After processing a page with `closed: true` and `has_more: false`, the reader has caught up with all published messages. For an open feed, read again later for new messages. A reader that reports back can save its position through a [subscription](subscriptions.md#read-an-ivenna-feed-and-report-back).

On success, the command writes a page and exits with status `0`. The following failures write one JSON string and exit with status `1`.

| Result | Meaning |
| --- | --- |
| `"invalid_request"` | A command argument is invalid, such as a malformed feed address or an out-of-range limit. |
| `"unknown_channel"` | The well-formed feed address has no matching feed. |
| `"busy"` | The instance database is busy. |
| `"storage_full"` | The instance storage has run out of space. |

If the command exits without a complete page or receipt, check stderr for diagnostics.

## Current email addressing

For an instance in `ivenna.test`, the email adapter presents `operator@ivenna.test` as `ivenna:/correspondent/operator`. If that mailbox is registered for sending, the same channel reaches the exact registered address. The adapter prepares one standalone email with subject `Ivenna` and the supplied message as its body. See the [mail service setup](running.md#mail-service) and [email boundary](architecture.md#email-boundary).

The adapter currently supports ASCII dot-atom local parts and ASCII hostname domains. It preserves ID case and ignores case only in the domain when comparing addresses.

Incoming mail needs at least one From address, with every From address supported and in the instance's domain. The same addressing rules apply to registered mailboxes. See [mail intake](running.md#mail-intake).

### Incoming email text

The observation's `text` contains the subject, a blank line, and the complete decoded body. An empty subject leaves just the body. The adapter selects plain-text parts when the message lists them, otherwise HTML source. It joins the selected parts with newlines and skips attachments. See [sharing material](usage.md#sharing-material-to-read) and [mail intake](running.md#mail-intake).
