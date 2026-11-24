# Communication

The core and its activities use `send` to write to a correspondent, reach a focus, or publish to a feed. Incoming correspondence reaches the core. To write to Ivenna, see the [correspondence guide](usage.md).

## Sending a message

Call `send` with nonempty `text` and a `to` object containing exactly one destination field. Look up the complete ID in the [current turn](input.md#inference-turns) or use the ID returned when opening a focus or creating a feed.

| Field in `to` | Destination | Where to find the ID | Successful result |
| --- | --- | --- | --- |
| `correspondent_id` | A [registered correspondent](#writing-to-a-correspondent) | `current.correspondents` | `correspondent_id` and submission `reference` |
| `focus_id` | An [existing focus](attention.md#reaching-an-existing-focus) | `current.focuses` or `open_focus` | `focus_id` |
| `feed_id` | An [open feed](#publishing-to-a-feed) | `current.feeds` or `create_feed` | `feed_id` and message `sequence` |

IDs are case-sensitive and local to the instance. Each field selects its own kind of destination, so a focus and a feed can have the same ID. Pass IDs as JSON strings with their original spelling, including spaces, punctuation, and non-ASCII characters.

Tool replies contain a JSON `result` or an `error` with `code` and `message`. Malformed arguments return `invalid_arguments`. The tool checks the destination when it runs. An unmatched ID returns the error for the selected type, and a feed that has closed since the turn was sampled returns `feed_closed`.

## Correspondents and IDs

Use the correspondent IDs in an incoming observation's `from` field to attribute the message. If the operator relays Alice's words, `from` identifies the operator, and the message text can attribute the words to Alice. Sender eligibility follows the mail intake rules. To reply, choose a registered recipient ID from `current.correspondents`. See [mail intake](running.md#mail-intake) and [outgoing registration](running.md#outgoing-correspondents).

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
| `invalid_recipient` | The ID is outside the deployment's permitted correspondence destinations. The tool stops before preparing the message. |
| `not_submitted` | Preparation stopped before the tool attempted submission. |
| `submission_unknown` | The tool attempted submission and could not confirm the outcome. The service may already have accepted the message, so sending it again could produce a duplicate. |

### Current email addressing

The email adapter uses the mailbox's local part as its correspondent ID. For an instance in `ivenna.test`, the ID for `operator@ivenna.test` is `operator`. Sending to that ID uses the exact registered mailbox and produces a standalone email with subject `Ivenna` and the supplied text as its body.

Registered mailboxes and incoming From addresses use ASCII dot-atom local parts and ASCII hostname domains. The adapter compares the local part case-sensitively and the domain case-insensitively. Incoming mail needs at least one From address, and all From addresses must be supported addresses in the instance's domain. See [mail service setup](running.md#mail-service) and [mail intake](running.md#mail-intake).

#### Incoming email text

The observation's `text` contains the subject, a blank line, and the complete decoded body. An empty subject leaves just the body. The adapter selects plain-text parts when the message lists them, otherwise HTML source. It joins the selected parts with newlines and skips attachments. See [sharing material](usage.md#sharing-material-to-read) and [mail intake](running.md#mail-intake).

## Feeds

A feed keeps an ordered sequence of messages. It belongs to the instance, outlives its creating focus, and survives restart. Use its `feed_id` to publish, read, or close it.

### Creating feeds

Any focus can call `create_feed` with a short `name` and a `description` of what readers can expect. The description contains 1 to 256 Unicode code points and can span lines. See [names and references](input.md#names-and-references).

```json
{"name":"releases","description":"Release announcements and links to upgrade notes."}
```

```json
{"result":{"feed_id":"releases-1"}}
```

### Publishing to a feed

Call `send` with the feed's `feed_id` in `to`.

```json
{"to":{"feed_id":"releases-1"},"text":"The release is ready for review."}
```

```json
{"result":{"feed_id":"releases-1","sequence":1}}
```

The sequence identifies the message stored for readers. An interruption can occur after publication but before the tool result reaches working history. Repeating `send` in that case can publish the same text again. See [restart behavior](architecture.md#startup-and-interruption).

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
| `unknown_feed` | No feed matches the supplied ID. |
| `feed_closed` | The feed was closed when Ivenna tried to publish. |
| `feed_capacity` | The instance has reached its configured limit for open feeds. |
| `feed_storage_busy` | The feed store is busy. |
| `feed_storage_full` | The feed store ran out of space. |
| `feed_storage_failed` | The store could not confirm the operation. |

### Reading feeds

Run `ivenna feed read` on the kernel host with `DATA_DIR` set to the instance's data directory. Pass the complete `feed_id` from Ivenna as one quoted argument. You can read a feed before or after it closes, even while the kernel is stopped. See [deploying a feed reader](running.md#feed-readers).

```sh
feed_id='releases-1'
ivenna feed read "$feed_id"
```

| Option | Meaning | Default | Accepted range |
| --- | --- | --- | --- |
| `--after SEQUENCE` | Return messages with a greater sequence | `0` | Decimal integers from `0` through `9223372036854775807` |
| `--limit N` | Maximum messages per page | `100` | Decimal integers from `1` through `1000` |

The command writes one page as a JSON line on stdout. Each page comes from one snapshot and lists messages in ascending sequence order. Sequence numbers can have gaps. The example page is formatted for readability.

```json
{
  "feed_id": "releases-1",
  "description": "Release announcements and links to upgrade notes.",
  "closed": false,
  "messages": [
    {
      "sequence": 1,
      "focus_id": "core-1",
      "text": "The release is ready for review.",
      "published_at_unix_ms": 1795478400000
    }
  ],
  "next_after": 1,
  "has_more": false
}
```

The page includes the feed ID, description, and closure state even when `messages` is empty. Each message contains the complete `text`, its `sequence`, the publishing `focus_id`, and `published_at_unix_ms` in Unix milliseconds.

Each reader keeps its own position. Save `next_after` after processing the whole page and pass it as `--after` on the next read. The value is the last returned sequence, or the supplied position when the page is empty. Read the next page when `has_more` is true. If it is false, poll later for an open feed or stop reading a closed feed. A reader that reports back can save its position through a [subscription](subscriptions.md#read-an-ivenna-feed-and-report-back).

The command exits with status `0` on success. The following failures write one JSON string and exit with status `1`.

| Result | Meaning |
| --- | --- |
| `"invalid_request"` | The command is missing an argument or has an invalid option. |
| `"unknown_feed"` | The supplied ID does not exactly match a feed. |
| `"busy"` | The instance database is busy. |
| `"storage_full"` | The instance storage has run out of space. |

If the command exits without a complete page or error string, check stderr for diagnostics.
