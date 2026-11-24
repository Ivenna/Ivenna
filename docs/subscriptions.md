# Subscription listener protocol

A listener uses `ivenna subscription` to report observations to the focus that registered the subscription. Give the listener the complete `subscription_id` returned by `subscribe` and pass it as one argument to each command. An independently running listener can report while the kernel is stopped. See [subscription registration](attention.md#subscriptions) and [listener deployment](running.md#subscription-listeners).

Set `DATA_DIR` to the instance's data directory. The examples use `IVENNA` for the path to the executable. Ivenna supplies both variables to its [host commands](host.md#running-a-command). Run `"$IVENNA" subscription --help` for command details.

## Publish an observation

Give each distinct observation its own `key` and reuse that key when retrying. The optional `cursor` saves the listener's position in its source. In this example, item 17 of the release feed announces v2.4.0.

```sh
subscription_id='releases-1'  # Use the ID returned by subscribe.
printf '%s\n' '{
  "key": "release-v2.4.0",
  "text": "Stable release v2.4.0 is available",
  "cursor": {"to": "17"}
}' | "$IVENNA" subscription publish "$subscription_id"
```

The JSON receipt `"accepted"` confirms that Ivenna queued the observation and saved position `"17"` together. The focus sees the report text and the time the local command received it. Supply `source_time_unix_ms` if the source event time is known. See the [publish fields and limits](../apps/ivenna/src/help/publish.txt) and the [observation delivered to the focus](input.md#subscription-observations).

## Resume from a cursor

Use `inspect` to recover the listener's last saved position when it starts or resumes.

```sh
"$IVENNA" subscription inspect "$subscription_id"
```

After the report for item 17 is accepted, `inspect` returns the subscription with its saved cursor.

```json
{"subscription_id":"releases-1","focus_id":"core-1","listener":"Report each new stable version from the project's release feed.","cursor":"17"}
```

With cursor `"17"`, resume after item 17. An object with `"cursor": null` describes an active subscription with no saved position. If the entire result is `null`, the ID is unknown or withdrawn. Stop using that ID. See the [inspect output and exit status](../apps/ivenna/src/help/inspect.txt).

## Skip an item

Use `checkpoint` to save a position after processing an item that needs no observation. If item 18 is a prerelease the listener filters out, pass `"17"` as the last saved position and `"18"` as the new position.

```sh
printf '%s\n' '{"from":"17","to":"18"}' | "$IVENNA" subscription checkpoint "$subscription_id"
```

To save a new cursor position, `from` must match the saved position. On `"cursor_conflict"`, use `inspect` again to decide which items still need processing. A replacement listener can use the same subscription if it understands the saved positions and the keys used for earlier publications. See the [cursor change fields](../apps/ivenna/src/help/writes.txt).

## Read an Ivenna feed and report back

Give a program that follows an Ivenna feed both its source `channel_id` and its destination `subscription_id`. Use `inspect` to recover its position and pass it as `--after` to [`feed read`](communication.md#reading-feeds). With a null cursor, start the read at `0` and omit `from` from the first cursor change.

Process messages in sequence order. Use each processed message's sequence as a decimal string for the new cursor position. For a report, use a stable key derived from the feed address and message sequence, and commit the cursor with `publish`. For a skipped message, save the cursor with `checkpoint`. A replacement listener can resume on the same feed from the last committed position.

## Command results

For each write, read the JSON receipt from stdout and check the exit status. See [write receipts and exit statuses](../apps/ivenna/src/help/writes.txt).

If a process or I/O failure interrupts the receipt, the write may already have committed. Check stderr for diagnostics.

- For `publish`, retry with the original key on the same subscription. An active subscription returns `"duplicate"` for an accepted key even after the focus receives the observation. In this example, retrying `release-v2.4.0` after checkpointing item 18 leaves the cursor at `"18"`.
- For `checkpoint`, inspect the saved cursor before deciding whether to retry.

## Withdrawal

Withdrawing `releases-1` closes it to new reports and releases its cursor and retry keys. A listener retrying item 17 on that ID now gets `"withdrawn"`. Reports already queued for the subscribing focus still reach it.

Subscribing again to the same source gives the listener a new ID with its own cursor and retry keys. A key used on `releases-1` can be accepted again on the new subscription.
