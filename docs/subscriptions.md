# Subscription listener protocol

A listener sends reports to the focus that subscribed. See [registering a subscription](attention.md#subscriptions).

## Open a listener session

Start `ivenna subscription listen SUBSCRIPTION_ID` as a child process with the ID returned by `subscribe`. In an Ivenna host command, use the executable in `IVENNA`. For an independent listener, see [listener deployment](running.md#subscription-listeners).

Wait for the JSON string `"ready"` on stdout before sending reports. If the session cannot open, the command exits with status 1. The receipt for an unknown or withdrawn ID is `"withdrawn"`. [Receipt meanings](#write-receipts-and-recovery)

Keep stdin and stdout open for as long as you use the session. Several sessions may use the same subscription. Each counts as connected while open, including between reports. See [listener sessions in the current turn](input.md#channel-receivers-and-subscription-listeners).

## Publish an observation

After receiving `"ready"`, write reports as JSON lines to stdin and read their JSON receipts from stdout.

```json
{"key":"release-v2.4.0","text":"Stable release v2.4.0 is available"}
```

| Field | Meaning |
| --- | --- |
| `key` | Nonempty string that identifies the observation within this subscription. Use a distinct key for each observation and reuse it on retries. |
| `text` | Observation text of 1–2,048 UTF-8 bytes. |
| `source_time_unix_ms` | Optional time of the reported event, in whole Unix milliseconds from `-62167219200000` through `253402300799000`. |

Each line can contain up to 65,536 bytes before the newline. See the [observation delivered to the focus](input.md#subscription-observations).

## Write receipts and recovery

After `"ready"`, receipts report line outcomes in input order.

| Receipt | Outcome | Session |
| --- | --- | --- |
| `"accepted"` | The first successful write for a key queues the report. A retry confirms that same report. | Stays open |
| `"busy"` | The instance database was busy. Retry the report. | Stays open |
| `"storage_full"` | The instance database was out of space. Free space and retry the report. | Stays open |
| `"invalid_request"` | The report could not be parsed, contains an invalid field, or exceeds the line limit. | Exits with status 1 for an oversized line. Otherwise stays open. |
| `"withdrawn"` | The subscription ID is unknown or withdrawn. | Exits with status 1 |

Close stdin to finish with status 0 after the final report. The command processes a final nonempty line even without a newline.

If writing a receipt fails, the command exits with status 1.

If a receipt is missing, the report may already be saved. Reconnect if the session ended, then resend the same report with its original subscription ID and key. A retry can confirm acceptance while that subscription remains active.

## Resume at the source

A listener that tracks progress can save its position locally or in the source's consumer state. Wait for `"accepted"` before saving progress past a reported item. If the listener stops before saving its position, it can replay the item with its original key. When delivery must survive a restart and the source cannot replay the item, save the report and its key until acceptance.

For example, a listener can report release 17 and save its position after acceptance. It can skip prerelease 18 and save that position directly. When it restarts, it resumes from the position it saved.

## Reporting from a schedule

A calendar timer can start a listener when a report is due. For a subscription following one timer, the scheduled timestamp can be the report's `key`. Supply it as `source_time_unix_ms` in Unix milliseconds if the focus needs the original time. If missed occurrences matter, arrange for the scheduler or listener to replay them until `"accepted"`. [Calendar timers](https://www.freedesktop.org/software/systemd/man/latest/systemd.timer.html#Persistent=) · [Report fields](#publish-an-observation) · [Write receipts](#write-receipts-and-recovery)

## Withdrawal

Withdrawing a subscription removes its registration and accepted keys. Reports already queued remain available to the subscribing focus. An open session returns `"withdrawn"` on its next valid report. See [withdrawing a subscription](attention.md#withdrawing-a-subscription).

Subscribing again to the same source gives the listener a new ID with its own accepted keys. A key used on the withdrawn subscription can be accepted again on the new one.

## Reporting after a channel read

A program can take work from a channel and report its outcome to a subscribed focus. Give it the `channel_id` for receiving work and the `subscription_id` for sending reports. The channel's `accepted` status confirms the handoff. The listener's `"accepted"` receipt confirms that the report was saved for the subscribing focus. See [sending to a channel](communication.md#sending-to-a-channel) and [write receipts](#write-receipts-and-recovery).
