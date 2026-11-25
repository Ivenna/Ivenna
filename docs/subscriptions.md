# Subscription listener protocol

A listener uses `ivenna subscription` to report observations to the focus that subscribed and save where to resume in its source. The saved position is called a cursor. Pass the complete `subscription_id` returned by `subscribe` as one argument to each command. See [registering a subscription](attention.md#subscriptions).

The examples call the executable through `IVENNA`. See the [command environment](host.md#command-environment) for listeners started by Ivenna and [listener deployment](running.md#subscription-listeners) for independent listeners. Run `"$IVENNA" subscription COMMAND --help` for the command's fields and exit statuses.

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
{"subscription_id":"release-watch-1","focus_id":"core-1","listener":"Report each stable release in the project changelog.","cursor":"17"}
```

With cursor `"17"`, resume after item 17. With `"cursor": null`, choose a starting position in your source. If the entire result is `null`, stop using that ID. See [inspect output and exit status](../apps/ivenna/src/help/inspect.txt).

## Skip an item

Use `checkpoint` to save a position without queuing an observation. If item 18 is a prerelease the listener filters out, pass `"17"` as the last saved position and `"18"` as the new position.

```sh
printf '%s\n' '{"from":"17","to":"18"}' | "$IVENNA" subscription checkpoint "$subscription_id"
```

A replacement listener can use the same subscription if it understands the cursor format and generates the same keys for previously reported items. See [cursor changes and write receipts](../apps/ivenna/src/help/writes.txt).

## Command results

Check the exit status and JSON receipt before advancing your local cursor. On `"cursor_conflict"`, read the saved cursor again before processing more items. See [write receipts and recovery](../apps/ivenna/src/help/writes.txt) for missing receipts and other errors.

In the example, retrying `release-v2.4.0` after checkpointing item 18 returns `"duplicate"` and leaves the cursor at `"18"`.

## Withdrawal

Withdrawing a subscription removes its saved cursor and retry keys. A listener that tries to write to that ID receives `"withdrawn"`. Reports already accepted keep their destination. See [withdrawing a subscription](attention.md#withdrawing-a-subscription).

Subscribing again to the same source gives the listener a new ID with its own cursor and retry keys. A key used on the withdrawn subscription can be accepted again on the new one.

## Reporting after a channel read

A program can use a channel to receive work and a subscription to report its outcome. Give it the `channel_id` for reads and the `subscription_id` from the focus that should receive the reports. See [receiving a channel message](communication.md#receiving-from-a-channel) and [publishing an observation](#publish-an-observation).

Keep the report and its `key` until publication is confirmed so the program can retry the report independently of the read.
