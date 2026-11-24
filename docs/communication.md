# Communication

Incoming correspondence from people and programs enters Ivenna's core. Both the core and its activities use `send` to write to a correspondent, reach a focus, or publish to a feed. See the [usage guide](usage.md) for writing to Ivenna and [Attention](attention.md) for communication between focuses.

## Correspondents and IDs

If `operator` relays Alice's words, the observation identifies `ivenna:/correspondent/operator` as the sender. The text can identify Alice as the original speaker. See [incoming message fields](input.md#incoming-messages).

Ivenna chooses what to retain about correspondence in its understanding and shared memory. The communication interface has no operation for searching past correspondence. Stored copies follow the [communication-copy retention policy](running.md#communication-copies).

## Sending a message

Call `send` with nonempty `text` and one complete `channel_id`. The URI addresses a destination within the current Ivenna instance. Choose an address from the channel catalog or a creation result. See [the channel catalog](input.md#inference-turns) and [reaching a focus](attention.md#reaching-an-existing-focus).

| Address | Destination | Successful result |
| --- | --- | --- |
| `ivenna:/correspondent/<id>` | One registered correspondent | `channel_id` and submission `reference` |
| `ivenna:/focus/<id>` | An existing focus | `channel_id` |
| `ivenna:/feed/<name>-<serial>` | An open feed | `channel_id` and storage `sequence` |

Address prefixes and keys are case-sensitive. Keys use UTF-8 with ASCII control characters excluded. Keep ASCII letters, digits, `-`, `.`, `_`, and `~` as written. Encode other bytes as `%` followed by two uppercase hexadecimal digits. For example, `notes/release-1` becomes `notes%2Frelease-1`.

Tool errors carry `error.code` and `error.message`. Malformed arguments, including invalid addresses and values outside the documented bounds, return `invalid_arguments`.

```json
{"channel_id":"ivenna:/correspondent/operator","text":"The updated files are ready for review."}
```

The result includes a reference when the correspondence service accepts a message for delivery. Delivery can still fail afterward.

```json
{"result":{"channel_id":"ivenna:/correspondent/operator","reference":"<submission-reference>"}}
```

| Correspondence error | Meaning |
| --- | --- |
| `invalid_recipient` | The ID is outside the deployment's permitted correspondence destinations. The tool stops before preparing the message. |
| `not_submitted` | Preparation stopped before the tool attempted submission. |
| `submission_unknown` | The tool attempted submission and could not confirm the outcome. The service may already have accepted the message, so sending it again could produce a duplicate. |

## Feeds

A feed keeps an ordered sequence of messages. Any focus can call `create_channel` with a brief `name` and a `description` of what belongs in the feed. A name is one to 32 Unicode code points, excludes ASCII controls, and includes at least one character besides an ASCII space. A description is nonblank UTF-8 up to 256 code points and can span lines. Embedded NUL bytes are invalid.

```json
{"name":"releases","description":"Release announcements and links to upgrade notes."}
```

The result contains a complete `channel_id`, such as `ivenna:/feed/releases-1`. Creating another feed with the same name issues a new ID. Feeds belong to the instance and persist across focus completion, context handover, and restart. Find open feeds by address and description in the [channel catalog](input.md#inference-turns).

Send to a feed by its complete ID. Feed text must be nonempty UTF-8 without NUL bytes.

```json
{"channel_id":"ivenna:/feed/releases-1","text":"The release is ready for review."}
```

```json
{"result":{"channel_id":"ivenna:/feed/releases-1","sequence":1}}
```

The sequence confirms that Ivenna stored the message for readers. A program can report back through [a subscription](subscriptions.md).

### Closing feeds

Use `close_channel` with the complete feed `channel_id` to stop writes. The feed's description and published messages remain readable. A close returns the ID and `changed: true` on the first closure, or `changed: false` if already closed.

| Feed error | Meaning |
| --- | --- |
| `unknown_channel` | The supplied feed address has no matching feed. |
| `channel_closed` | The feed closed before the write could be accepted. |
| `channel_capacity` | The instance has reached its configured limit for open feeds. |
| `channel_managed` | The close request addressed a focus or correspondent channel. |
| `channel_storage_busy` | The feed store is busy. |
| `channel_storage_full` | The feed store ran out of space. |
| `channel_storage_failed` | The store could not confirm the operation. |

A process interruption can leave a committed message without a saved tool result. Restart restores the store and does not replay tool calls. Sending the same text in a new call creates a new message.

### Reading feeds

A local program with access to the instance data directory can open `<DATA_DIR>/channels.sqlite3` using a read-only SQLite connection, including while the kernel is stopped. These views include closed feeds and their messages. See [feed storage and access](running.md#feed-storage) for deployment details.

| View | Columns |
| --- | --- |
| `feeds` | Complete `channel_id`, `description`, `closed` (0 or 1) |
| `feed_messages` | Complete `channel_id`, `sequence`, `focus_id`, `text`, `published_at_unix_ms` |

For example, start at sequence 0 and read a bounded page. Supply the channel ID and previous sequence as bound parameters in a program.

```sh
sqlite3 -readonly -json "$DATA_DIR/channels.sqlite3" \
  "SELECT sequence, focus_id, text, published_at_unix_ms
   FROM feed_messages
   WHERE channel_id = 'ivenna:/feed/releases-1' AND sequence > 0
   ORDER BY sequence LIMIT 100;"
```

Each row is one message, including any newlines in its text. The store assigns increasing sequence numbers across all feeds, so one feed can have gaps in its sequence. A reader records the last sequence it processed and queries for larger values on its next read. A closed feed can still have unread messages.

## Current email addressing

For an instance in `ivenna.test`, the email adapter presents `operator@ivenna.test` as `ivenna:/correspondent/operator`. If that mailbox is registered for sending, the same channel reaches the exact registered address. The adapter prepares one standalone email with subject `Ivenna` and the supplied message as its body. See the [mail service setup](running.md#mail-service) and [email boundary](architecture.md#email-boundary).

The adapter currently supports ASCII dot-atom local parts and ASCII hostname domains. It preserves ID case and ignores case only in the domain when comparing addresses.

Incoming mail needs at least one From address, with every From address supported and in the instance's domain. The same addressing rules apply to registered mailboxes. See [mail intake](running.md#mail-intake).

## Incoming email text

The observation's `text` contains the subject, a blank line, and the complete decoded body. An empty subject leaves just the body. The adapter selects plain-text parts when the message lists them, otherwise HTML source. It joins the selected parts with newlines and skips attachments. See [sharing material](usage.md#sharing-material-to-read) and [mail intake](running.md#mail-intake).
