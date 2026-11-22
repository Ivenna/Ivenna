# Subscription listener protocol

A listener uses `ivenna-report` to send observations to the focus that registered a subscription. Give the listener the complete `subscription_id` returned by `subscribe` and pass it as one argument to each command. See [subscription registration](attention.md#subscriptions).

Ivenna's host commands inherit `IVENNA_REPORT`, the path to the executable, and `DATA_DIR`, the kernel's data directory. Run `"$IVENNA_REPORT" --help` for the full protocol or `"$IVENNA_REPORT" publish --help` for a single command. Help works before `DATA_DIR` is set. For an independent listener, see [deployment and configuration](running.md#subscription-listeners).

## Publish an observation

Give each distinct observation its own `key` and reuse that key when retrying it. The optional `cursor` records how far the listener has read in the source. In this example, subscription `releases-1` follows a feed whose item 17 announces v2.4.0.

```sh
subscription_id='releases-1'  # Use the ID returned by subscribe.
printf '%s\n' '{
  "key": "release-v2.4.0",
  "text": "Stable release v2.4.0 is available",
  "cursor": {"to": "17"}
}' | "$IVENNA_REPORT" publish "$subscription_id"
```

The JSON receipt `"accepted"` means the reporter queued the observation and saved position `"17"` together. A listener running independently can publish while the kernel is stopped. When the focus receives the observation, it sees the report text and the time the reporter received it. A listener that knows when the source event occurred can also supply `source_time_unix_ms`. See the [publish fields and limits](../apps/ivenna-report/src/help/publish.txt) and the [observation delivered to the focus](input.md#subscription-observations).

## Resume from a cursor

When the listener restarts, use `inspect` to find its last saved position.

```sh
"$IVENNA_REPORT" inspect "$subscription_id"
```

After item 17, the core subscription in this example has the following registration and cursor.

```json
{"subscription_id":"releases-1","focus_id":"core-1","listener":"Report each new stable version from the project's release feed.","cursor":"17"}
```

With cursor `"17"`, resume after item 17. An object with `"cursor": null` means the subscription is active and has no saved position. If the entire result is `null`, the ID is unknown or withdrawn and the listener should stop using it. See the [inspect output and exit status](../apps/ivenna-report/src/help/inspect.txt).

Suppose item 18 is a prerelease that the listener filters out. Use `checkpoint` to save position `"18"` without queuing an observation. Pass the cursor change directly, with the position just read in `from`.

```sh
printf '%s\n' '{"from":"17","to":"18"}' | "$IVENNA_REPORT" checkpoint "$subscription_id"
```

If the saved cursor no longer matches `from`, the command returns `"cursor_conflict"`. Inspect the saved position again to decide which items still need processing. A replacement listener can use the same subscription if it understands the saved positions and the keys used for earlier publications. See the [checkpoint command](../apps/ivenna-report/src/help/checkpoint.txt).

## Command results

For each write, read the JSON receipt from stdout and check the exit status. See [write receipts and exit statuses](../apps/ivenna-report/src/help/writes.txt).

If a process or I/O failure interrupts the receipt, the write may already have committed. Check stderr for diagnostics.

- For `publish`, retry with the original key on the same subscription. An active subscription returns `"duplicate"` for an accepted key even after the focus receives the observation. In this example, retrying `release-v2.4.0` after checkpointing item 18 leaves the cursor at `"18"`.
- For `checkpoint`, inspect the saved cursor before deciding whether to retry.

## Withdrawal

Withdrawing `releases-1` closes it to new reports and releases its cursor and retry keys. A listener retrying item 17 on that ID now gets `"withdrawn"`. Reports already queued for the subscribing focus still reach it.

Registering the same feed again gives the listener a fresh ID with no saved cursor. A key used on `releases-1` can be accepted again on the new subscription.
