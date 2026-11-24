# Subscription listener protocol

A listener uses `ivenna subscription` to report observations to the focus that subscribed and can save its position in the source as a cursor. Pass the complete `subscription_id` returned by `subscribe` as one argument to each command. See [registering a subscription](attention.md#subscriptions).

The examples call the executable through `IVENNA`. Ivenna's host commands inherit this variable and `DATA_DIR`. For independent listeners, see [listener deployment](running.md#subscription-listeners). Run `"$IVENNA" subscription COMMAND --help` for the command's fields and exit statuses.

## Publish an observation

Choose a distinct, stable `key` for each observation in this subscription. A listener with no saved cursor can report item 17 and save position `"17"` in the same write.

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

A replacement listener can use the same subscription if it understands the cursor format and generates the same keys for previously reported items. See [cursor changes and write receipts](../apps/ivenna/src/help/writes.txt).

## Read an Ivenna feed and report back

Use the source's `feed_id` to read its messages and the destination's `subscription_id` to report observations. Save the last processed feed sequence as the subscription cursor.

1. Use `subscription inspect` to recover the registration and cursor. If the registration is active, pass the cursor as `--after` to `feed read`. When the cursor is null, use `--after 0` and omit `from` in the first write.
2. Process each message in sequence order. For the cursor change, use the last saved cursor as `from` and the message sequence as a decimal string for `to`.
3. Use `subscription publish` to report an observation and save the sequence together. Derive the report key from the feed ID and sequence. Choose what to convey within the [report text limit](../apps/ivenna/src/help/publish.txt). Use `subscription checkpoint` for a message you skip.
4. With `has_more: true`, read the next page from the last saved sequence. Once caught up, read again with `--wait MS` while the feed is open, so the next message returns as soon as it is published, or stop if the feed has closed.

See [reading feeds](communication.md#reading-feeds) for the feed page format.

## Command results

Read the JSON receipt on stdout and check the exit status before using the new cursor. On `"cursor_conflict"`, inspect the saved cursor again before processing more items. See [write receipts and recovery](../apps/ivenna/src/help/writes.txt) for missing receipts and other errors.

In the example, retrying `release-v2.4.0` after checkpointing item 18 returns `"duplicate"` and leaves the cursor at `"18"`.

## Withdrawal

Withdrawing a subscription releases its cursor and retry keys. A listener that tries to write to that ID receives `"withdrawn"`. Reports already accepted keep their destination.

Subscribing again to the same source gives the listener a new ID with its own cursor and retry keys. A key used on the withdrawn subscription can be accepted again on the new one.
