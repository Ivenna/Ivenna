# Subscription listener protocol

A listener uses `ivenna-report` to send observations to the focus that registered a subscription. Give the listener the complete `subscription_id` returned by `subscribe` and pass it as one argument to each command. See [subscription registration](attention.md#subscriptions).

Ivenna's host commands inherit `IVENNA_REPORT`, the path to the executable, and `DATA_DIR`, the kernel's data directory. Run `"$IVENNA_REPORT" --help` for the full protocol or `"$IVENNA_REPORT" publish --help` for a single command. Help works before `DATA_DIR` is set. For an independent listener, see [deployment and configuration](running.md#subscription-listeners).

## Publish an observation

Suppose a new subscription, `releases-1`, follows a release feed. Item 17 announces v2.4.0. Give the announcement a key the listener can reproduce if it retries. Include the feed position in the same request.

```sh
subscription_id='releases-1'
printf '%s\n' '{
  "key": "release-v2.4.0",
  "text": "Stable release v2.4.0 is available",
  "cursor": {"to": "17"}
}' | "$IVENNA_REPORT" publish "$subscription_id"
```

The JSON receipt `"accepted"` means the reporter queued the observation and saved position `"17"` together. The listener can do this while the kernel is stopped. When the focus receives the observation, it sees the report text and the reporter's local receipt time. A listener that knows when the source event occurred can also supply `source_time_unix_ms`. See the [publish fields and limits](../apps/ivenna-report/src/help/publish.txt) and the [observation delivered to the focus](input.md#subscription-observations).

## Resume from a cursor

After a restart, inspect the subscription before choosing the next feed item.

```sh
"$IVENNA_REPORT" inspect "$subscription_id"
```

After item 17, the core subscription in this example has the following registration and cursor.

```json
{"subscription_id":"releases-1","focus_id":"core-1","listener":"Report each new stable version from the project's release feed.","cursor":"17"}
```

Resume after item 17. An object with `"cursor": null` means the subscription is active and has no saved position. If the entire result is `null`, the ID is unknown or withdrawn. Both forms are successful reads. See the [inspect output](../apps/ivenna-report/src/help/inspect.txt).

Suppose item 18 is a prerelease that the listener filters out. Use `checkpoint` to save the new position. The `from` field carries the position just read. For a checkpoint, the cursor change is the whole request.

```sh
printf '%s\n' '{"from":"17","to":"18"}' | "$IVENNA_REPORT" checkpoint "$subscription_id"
```

The position advances only if the saved cursor is still `"17"`. If another listener advanced it first, inspect the current position and work out which items still need processing. A replacement listener can use the same subscription if it understands the saved positions and the keys used for earlier publications. See the [checkpoint command](../apps/ivenna-report/src/help/checkpoint.txt).

## Command results

For each write, read the JSON receipt from stdout and check the exit status. If the listener retries item 17 on the same active subscription after checkpointing item 18, the original key returns `"duplicate"` and the cursor stays at `"18"`. See [cursor fields, write receipts and exit statuses](../apps/ivenna-report/src/help/writes.txt).

A process or I/O failure can interrupt the receipt after a write commits. Check stderr for diagnostics. If the outcome is uncertain, retry a publication with its original key. For a checkpoint, inspect the saved cursor before deciding whether to retry.

## Withdrawal

Withdrawal closes intake on that ID and releases its cursor and retry keys. The focus can still receive observations accepted before withdrawal. Registering the same source again gives the listener a fresh ID with its own cursor and keys.
