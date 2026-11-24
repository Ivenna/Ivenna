# Subscription listener protocol

A listener uses `ivenna subscription` to report observations to the focus that subscribed. Pass the complete `subscription_id` as one argument to each command. See [registering a subscription](attention.md#subscriptions).

The examples use `IVENNA` for the executable path and `DATA_DIR` for the instance's data directory. Ivenna's host commands inherit both variables. For independent listeners, see [listener deployment](running.md#subscription-listeners). Run `"$IVENNA" subscription COMMAND --help` for the command's fields and exit statuses.

## Publish an observation

Use a stable `key` for each observation, so a retry can refer to the same observation. Here, a listener with no saved cursor reports that item 17 announced v2.4.0 and sets its cursor to `"17"`.

```sh
subscription_id='release-watch-1'  # Use the ID returned by subscribe.
printf '%s\n' '{
  "key": "release-v2.4.0",
  "text": "Stable release v2.4.0 is available",
  "cursor": {"to": "17"}
}' | "$IVENNA" subscription publish "$subscription_id"
```

The `"accepted"` receipt confirms that the report and position were saved together. Supply `source_time_unix_ms` if the listener knows when the event happened at the source. See the [publish fields and limits](../apps/ivenna/src/help/publish.txt) and the [observation delivered to the focus](input.md#subscription-observations).

## Resume from a cursor

Use `inspect` to recover the listener's last saved position when it starts or resumes.

```sh
"$IVENNA" subscription inspect "$subscription_id"
```

After the report for item 17 is accepted, `inspect` returns the active subscription.

```json
{"subscription_id":"release-watch-1","focus_id":"core-1","listener":"Report each stable release announced on the feed.","cursor":"17"}
```

With cursor `"17"`, resume after item 17. With `"cursor": null`, choose a starting position in your source. If the entire result is `null`, stop using that ID. See [inspect output and exit status](../apps/ivenna/src/help/inspect.txt).

## Skip an item

Use `checkpoint` to save a position without queuing an observation. If item 18 is a prerelease the listener filters out, pass `"17"` as the last saved position and `"18"` as the new position.

```sh
printf '%s\n' '{"from":"17","to":"18"}' | "$IVENNA" subscription checkpoint "$subscription_id"
```

Both write commands require `from` to match the saved cursor when advancing it. On `"cursor_conflict"`, inspect the saved position again before processing more items. A replacement listener can use the same subscription if it understands the cursor format and generates the same keys for previously reported items. See [cursor changes](../apps/ivenna/src/help/writes.txt).

## Read an Ivenna feed and report back

Pass the source `feed_id` to `ivenna feed read` and the destination `subscription_id` to `ivenna subscription`. The subscription cursor records the sequence of the last processed message.

1. Use `inspect` to load the subscription cursor and pass it as `--after` to `feed read`. When the cursor is null, use `--after 0` and omit `from` in the first write.
2. Process messages in sequence order. For each message, use the last saved cursor as `from` and the message's sequence as a decimal string for `to`.
3. Use `publish` to report a message and save its position in the same write. Derive the report key from the feed ID and sequence. For a skipped message, use `checkpoint` to save the position.

See [reading feeds](communication.md#reading-feeds) for the feed page format.

## Command results

Read the JSON receipt on stdout and check the exit status. If a write loses its receipt, it may already have committed. See [write receipts and recovery](../apps/ivenna/src/help/writes.txt).

In the example, retrying `release-v2.4.0` after checkpointing item 18 returns `"duplicate"` and leaves the cursor at `"18"`. For a lost checkpoint receipt, `inspect` shows which cursor was saved.

## Withdrawal

Withdrawing a subscription releases its cursor and retry keys. A listener that tries to write to that ID receives `"withdrawn"`. Reports already accepted keep their destination.

Subscribing again to the same source gives the listener a new ID with its own cursor and retry keys. A key used on the withdrawn subscription can be accepted again on the new one.
