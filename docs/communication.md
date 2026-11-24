# Communication

The core receives incoming correspondence. Both the core and activities can send messages. To write to Ivenna, see the [correspondence guide](usage.md).

## Sending a message

Call `send` with nonempty `text` and a `to` object containing exactly one destination field. Use a complete ID from an observation, a tool result, or a reference shared in a message.

| Field in `to` | Destination | Successful result |
| --- | --- | --- |
| `correspondent_id` | A [registered correspondent](#writing-to-a-correspondent) | `correspondent_id` and submission `reference` |
| `focus_id` | An [existing focus](attention.md#reaching-an-existing-focus) | `focus_id` |
| `feed_id` | An [open feed](#publishing-to-a-feed) | `feed_id` and message `sequence` |

Pass IDs as case-sensitive JSON strings, preserving spaces, punctuation, and non-ASCII characters. An ID is local to its instance and destination kind. For example, a focus and a feed can have the same ID.

Tool replies contain a JSON `result` or an `error` with `code` and `message`. Malformed arguments return `invalid_arguments`. The runtime resolves the selected destination when `send` runs.

## Correspondents and IDs

An incoming observation's `from` field contains the sender IDs. If the operator relays Alice's words, `from` identifies the operator. The message text can attribute the words to Alice. See [correspondence observations](input.md#incoming-messages).

Sending to a known correspondent ID requires outgoing registration, including when the ID comes from a letter Ivenna received. The core also receives the registered outgoing IDs at compaction. See [outgoing registration](running.md#outgoing-correspondents) and [sampled state](input.md#sampled-state).

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

The observation's `text` contains the subject, a blank line, and the decoded text of the selected body parts. With an empty subject, it contains only the body. The adapter selects plain-text parts when the message lists them and uses HTML source when it lists only HTML body parts. It joins selected parts with newlines. See [sharing material](usage.md#sharing-material-to-read) and [mail intake](running.md#mail-intake).

## Feeds

A feed is an instance-owned sequence of messages. An open feed stays available for publication after its creating focus ends. Use its `feed_id` to publish, read, or close it, including after a restart. See [which feed IDs each focus receives at compaction](input.md#sampled-state).

### Creating feeds

Any focus can call `create_feed` with a short `name` and a nonempty `description` of what readers can expect. The description can span lines. See [names and references](input.md#names-and-references).

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

The `changed` field indicates whether the call closed the feed. Closing an already closed feed returns `changed: false`.

```json
{"result":{"feed_id":"releases-1","changed":true}}
```

### Feed tool errors

| Feed error | Meaning |
| --- | --- |
| `unknown_feed` | No feed matches the supplied ID. |
| `feed_closed` | The feed was closed when Ivenna tried to publish. |
| `feed_storage_busy` | The feed store is busy. |
| `feed_storage_full` | The feed store ran out of space. |

Loss of required access to instance state follows the [runtime availability policy](design.md#runtime-availability).

### Reading feeds

With `DATA_DIR` set to the instance's data directory, run `ivenna feed read` on the kernel host. Pass the complete `feed_id` from Ivenna as one quoted argument. The command also works while the kernel is stopped. For filesystem access requirements, see [feed reader deployment](running.md#feed-readers).

```sh
feed_id='releases-1'
ivenna feed read "$feed_id"
```

The result is one JSON line on stdout. The feed metadata and messages in the page come from the same snapshot, including whether the feed has closed. Messages appear in ascending sequence order and sequence numbers can have gaps. Here is an example page with line breaks added for readability.

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

Save `next_after` after processing the whole page and pass it as `--after` on the next read. A reader that reports an observation for each message can save its position with that observation. See [reading a feed and reporting back](subscriptions.md#read-an-ivenna-feed-and-report-back).

Run `ivenna feed read --help` for the options, page fields, and exit statuses.
