# Communication

The core receives incoming correspondence. Both the core and activities can send messages. To write to Ivenna, see the [correspondence guide](usage.md).

## Sending a message

Call `send` with nonempty `text` and a `to` object containing exactly one destination field. Use a complete ID from an observation, a tool result, or a reference shared in a message.

| Field in `to` | Destination | Successful result |
| --- | --- | --- |
| `correspondent_id` | A [registered correspondent](#writing-to-a-correspondent) | `correspondent_id` and submission `reference` |
| `focus_id` | An [existing focus](attention.md#reaching-an-existing-focus) | `focus_id` |
| `feed_id` | An [open feed](#publishing-to-a-feed) | `feed_id` and message `sequence` |

Pass IDs as case-sensitive JSON strings, preserving spaces, punctuation, and non-ASCII characters. Each ID has meaning within its instance and destination kind. For example, `to.focus_id` and `to.feed_id` can refer to different destinations with the same ID.

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

## Feeds

A feed is an instance-owned sequence of messages. An open feed stays available for publication after its creating focus ends. Use its `feed_id` to publish, read, or close it, including after a restart. See [which feed IDs each focus receives at compaction](input.md#sampled-state).

### Creating feeds

Any focus can call `create_feed` with a short `name` and a nonempty `description` of what readers can expect. Readers see the description on every page. See [names and references](input.md#names-and-references).

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

Use `close_feed` with the `feed_id` to stop new publications. The feed's description and messages remain readable.

```json
{"feed_id":"releases-1"}
```

```json
{"result":{"feed_id":"releases-1","changed":true}}
```

Closing an already closed feed returns `changed: false`.

### Feed tool errors

| Feed error | Meaning |
| --- | --- |
| `unknown_feed` | No feed matches the supplied ID. |
| `feed_closed` | The feed was closed when Ivenna tried to publish. |
| `feed_storage_busy` | The feed store is busy. |
| `feed_storage_full` | The feed store ran out of space. |

Loss of required access to instance state follows the [runtime availability policy](design.md#runtime-availability).

### Reading feeds

On the kernel host, set `DATA_DIR` to the instance's data directory and pass the complete `feed_id` as one quoted argument. The command also works while the kernel is stopped. For filesystem access requirements, see [feed reader deployment](running.md#feed-readers).

```sh
ivenna feed read 'releases-1'
```

The command prints one JSON page on a single line. The description, closure status, and messages come from the same read. Messages appear in ascending sequence order, with possible gaps.

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

After processing the whole page, save `next_after` and pass it as `--after` on the next read. `has_more: false` means the reader has caught up with the feed at the time of the read. If the feed is open, either poll later for new messages or pass `--wait MS` to hold the read open until one arrives, the feed closes, or the wait expires; the page then comes back empty with the same `next_after`. A listener can save its position with each observation it reports. See [reading a feed and reporting back](subscriptions.md#read-an-ivenna-feed-and-report-back).

Run `ivenna feed read --help` for the options, page fields, and exit statuses.
