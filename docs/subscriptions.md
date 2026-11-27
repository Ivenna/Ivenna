# Subscription listener protocol

A listener watches a source and reports observations to the focus that subscribed. See [registering a subscription](attention.md#subscriptions).

## Keep a listener session open

Start `ivenna subscription listen SUBSCRIPTION_ID` as a child process with the ID returned by `subscribe`. In an Ivenna host command, use the executable in `IVENNA`. For an independent listener, see [listener deployment](running.md#subscription-listeners).

The command writes the JSON string `"ready"` to stdout when it connects. A startup failure ends the process with status 1 before `"ready"`. An unknown or withdrawn ID produces a `"withdrawn"` receipt in that case.

Keep stdin and stdout open while watching the source. Several sessions may use the same subscription. Each counts as connected while open, including between reports. See [listener sessions in the current turn](input.md#channel-receivers-and-subscription-listeners).

## Publish an observation

After receiving `"ready"`, write reports as JSON lines to stdin and read one JSON receipt per report from stdout.

```json
{"key":"release-v2.4.0","text":"Stable release v2.4.0 is available"}
```

| Field | Meaning |
| --- | --- |
| `key` | Nonempty string that identifies the observation within this subscription. Use the same key for every attempt to send that observation. |
| `text` | Observation text of 1–2,048 UTF-8 bytes. |
| `source_time_unix_ms` | Optional event time at the source, in integer Unix milliseconds from `-62167219200000` through `253402300799000`. |

Each line can contain up to 65,536 bytes before the newline. See the [observation delivered to the focus](input.md#subscription-observations).

## Write receipts and recovery

After `"ready"`, each receipt reports the result of processing one line.

| Receipt | Outcome |
| --- | --- |
| `"accepted"` | The report has been saved, either now or on an earlier attempt. Only the first acceptance of a key queues a report. |
| `"busy"` | The instance database was busy. |
| `"storage_full"` | The instance database was out of space. |
| `"invalid_request"` | The line exceeds the size limit, could not be parsed as a report, or contains an invalid field. |
| `"withdrawn"` | The subscription has been withdrawn. |

The command exits with status 1 after `"withdrawn"` or an oversized line. After other receipts the session stays open for another report. Close stdin to finish with status 0 after the final report. The command processes a final nonempty line even without a newline.

If the output pipe closes while the command writes a receipt, it exits with status 1. A report may already have been saved when a receipt is lost. To retry, reopen the session with the same subscription ID if needed and send the observation with its original key.

## Resume at the source

The listener chooses which items to report and saves its position in its own storage or in the source's consumer state. Wait for `"accepted"` before saving progress past a reported item. If the listener stops before saving its position, it can replay that item with its original key. For a source that cannot replay items, keep the report and key in durable listener storage until acceptance.

For example, a listener can report release 17 and save its position after acceptance. It can skip prerelease 18 and save that position directly. When it restarts, it resumes from the position it saved.

## Withdrawal

Withdrawing a subscription removes its registration and accepted keys. An open session returns `"withdrawn"` on its next valid report. See [withdrawing a subscription](attention.md#withdrawing-a-subscription).

Subscribing again to the same source gives the listener a new ID with its own accepted keys. A key used on the withdrawn subscription can be accepted again on the new one.

## Reporting after a channel read

A program can take work from a channel and report its outcome to a subscribed focus. Give it the `channel_id` for receiving work and the `subscription_id` for sending reports. The channel confirms a message handoff, and the subscription confirms receipt of the program's report. See [sending to a channel](communication.md#sending-to-a-channel) and [write receipts](#write-receipts-and-recovery).
