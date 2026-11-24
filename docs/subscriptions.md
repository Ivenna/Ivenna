# Subscription listener protocol

A listener uses `ivenna subscription` to report observations to the focus that subscribed. Pass the `subscription_id` returned by `subscribe` as one argument to each command. An independent listener can report while the kernel is stopped. See [subscription registration](attention.md#subscriptions) and [listener deployment](running.md#subscription-listeners).

Set `DATA_DIR` to the instance's data directory. The examples use `IVENNA` for the executable path. Ivenna gives host commands both variables. Run `"$IVENNA" subscription --help` to find the commands and `"$IVENNA" subscription COMMAND --help` for command details. See the [command environment](host.md#command-environment).

## Publish an observation

Give each observation a distinct `key` within its subscription. Reuse that key when retrying the same observation. A report can also save the listener's position in its source through `cursor`. Here, a listener with no saved position reports that item 17 announced v2.4.0.

```sh
subscription_id='release-watch-1'  # Use the ID returned by subscribe.
printf '%s\n' '{
  "key": "release-v2.4.0",
  "text": "Stable release v2.4.0 is available",
  "cursor": {"to": "17"}
}' | "$IVENNA" subscription publish "$subscription_id"
```

The `"accepted"` receipt confirms that Ivenna queued the observation and saved position `"17"` in the same write. The focus sees the report text and its local receipt time. Supply `source_time_unix_ms` to also convey the source event time. See the [publish fields and limits](../apps/ivenna/src/help/publish.txt) and the [observation delivered to the focus](input.md#subscription-observations).

## Resume from a cursor

Use `inspect` to recover the listener's last saved position when it starts or resumes.

```sh
"$IVENNA" subscription inspect "$subscription_id"
```

After the report for item 17 is accepted, `inspect` returns the subscription with its saved cursor.

```json
{"subscription_id":"release-watch-1","focus_id":"core-1","listener":"Report each stable release announced on the feed.","cursor":"17"}
```

With cursor `"17"`, resume after item 17. An object with `"cursor": null` describes an active subscription with no saved position. If the entire result is `null`, the ID is unknown or withdrawn. Stop using that ID. See the [inspect output and exit status](../apps/ivenna/src/help/inspect.txt).

## Skip an item

Use `checkpoint` to save a position without queuing an observation. If item 18 is a prerelease the listener filters out, pass `"17"` as the last saved position and `"18"` as the new position.

```sh
printf '%s\n' '{"from":"17","to":"18"}' | "$IVENNA" subscription checkpoint "$subscription_id"
```

Both `publish` and `checkpoint` save a new cursor only when `from` matches the saved position. On `"cursor_conflict"`, use `inspect` again to decide which items still need processing. A replacement listener can use the same subscription if it understands the saved positions and earlier report keys. See the [cursor change fields](../apps/ivenna/src/help/writes.txt).

## Read an Ivenna feed and report back

The listener passes the source `feed_id` to `feed read` and the destination `subscription_id` to `ivenna subscription`. In these examples, the source is `releases-1` and the destination is `release-watch-1`.

Use `inspect` to load the subscription's cursor and pass that position as `--after` to `feed read`. If the cursor is null, read from `0` and omit `from` in the first cursor change. See [reading feeds](communication.md#reading-feeds).

Process messages in sequence order. For each message, set `to` to its sequence as a decimal string and `from` to the last saved cursor, when present. Use `publish` to save the position with a report. Derive a stable report key from the feed ID and message sequence. Use `checkpoint` to save the position for a skipped message. On restart, `inspect` returns the last committed position.

## Command results

For each write, read the JSON receipt from stdout and check the exit status. See [write receipts and exit statuses](../apps/ivenna/src/help/writes.txt).

If a process or I/O failure interrupts the receipt, the write may already have committed. Check stderr for diagnostics.

- For `publish`, retry with the original key on the same subscription. An active subscription returns `"duplicate"` for an accepted key even after the focus receives the observation. In this example, retrying `release-v2.4.0` after checkpointing item 18 leaves the cursor at `"18"`.
- For `checkpoint`, inspect the saved cursor before deciding whether to retry.

## Withdrawal

Withdrawing `release-watch-1` closes it to new reports and releases its cursor and retry keys. A listener retrying item 17 on that ID now gets `"withdrawn"`. Reports already queued for the subscribing focus still reach it.

Subscribing again to the same source gives the listener a new ID with its own cursor and retry keys. A key used on the withdrawn subscription can be accepted again on the new one.
