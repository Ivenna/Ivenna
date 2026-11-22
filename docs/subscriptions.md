# Subscription listener protocol

Give the listener the complete `subscription_id` returned by `subscribe`. Reports submitted under that ID go to the focus that created the subscription. The examples use the executable path in `IVENNA_REPORT` and the instance's data directory in `DATA_DIR`. Host commands inherit both. See [subscription registration](attention.md#subscriptions) and [deploying an independent listener](running.md#subscription-listeners).

## Publish an observation

Suppose the subscription is `releases-1` and item 17 in a release feed announces a stable release, v2.4.0. The listener can report the release and save its place in the feed in one write.

```sh
subscription_id='releases-1'
printf '%s\n' '{"key":"release-v2.4.0","text":"Stable release v2.4.0 is available","cursor":{"to":"17"}}' |
  "$IVENNA_REPORT" publish "$subscription_id"
```

`publish` returns `"accepted"` once the report and any cursor change commit together. The subscription's [reminder](attention.md#subscriptions) determines when the focus receives the [observation](input.md#subscription-observations).

| Field | Use |
| --- | --- |
| `key` | Required nonempty string identifying this update within the subscription. Reuse it for retries and choose a new key for a later revision. Separate subscriptions to the same feed may use the same keys. |
| `text` | Required nonempty description for the focus, up to 2,048 UTF-8 bytes. Include the revision, where to read more, or any gap in coverage when that matters to the observation. |
| `source_time_unix_ms` | Optional source event time as a JSON number of milliseconds since the Unix epoch. The reporter records the local receipt time. |
| `cursor` | Optional move from the last saved source position to the next one. Omit this field for a report that leaves the cursor in place. |

## Resume from a cursor

```sh
"$IVENNA_REPORT" inspect "$subscription_id"
```

`inspect` returns the registration (`subscription_id`, `focus_id`, `listener`, `reminder`) and its saved source position (`cursor`). A new registration has `"cursor": null`. If the registration was withdrawn or the ID is unknown, the entire result is JSON `null`.

After a restart, the release listener reads the saved cursor `"17"` and asks the feed for later items. The source defines the cursor's meaning. A push-only listener can omit it.

Suppose item 18 is a prerelease that the listener filters out. Use `checkpoint` to record that position without sending an observation. It takes the same cursor change that `publish` accepts in its `cursor` field.

```sh
printf '%s\n' '{"from":"17","to":"18"}' |
  "$IVENNA_REPORT" checkpoint "$subscription_id"
```

Set `from` to the saved cursor and `to` to the new position. For the first move, omit `from` or set it to `null`. If the source uses the empty string as a position, pass `""` to match it.

When `from` no longer matches, a checkpoint or a new report returns `"cursor_conflict"`. A report rejected for this reason leaves its key available for retry. Read the current cursor with `inspect` and check which items still need processing. If the source can no longer replay some items, a report can identify the gap.

## Withdrawal

Withdrawal closes intake on that reference and releases its cursor and retry keys. Reports already accepted keep their original focus and reminder.

A replacement listener can continue on an active subscription if it understands the saved cursor and the previous listener's key convention. Registering the same source again gives the listener a fresh reference with its own cursor and keys.

## Command results

Each write reads one JSON object from standard input. The reader accepts up to 4 MiB per string, so `from` and `to` can each use that space in one call. Read the JSON result from standard output and check the exit status.

| Result | Exit | Listener action |
| --- | --- | --- |
| `"accepted"` | Zero | The write committed. Continue. |
| `"duplicate"` | Zero | This subscription already accepted the key, even if the focus has since read the report. The saved cursor stays in place. |
| `"withdrawn"` | Nonzero | The registration cannot accept this operation. Stop reporting on the old reference. |
| `"cursor_conflict"` | Nonzero | Read the saved cursor before continuing. |
| `"busy"` | Nonzero | Retry after store contention subsides. |
| `"storage_full"` | Nonzero | Free storage before retrying. |
| `"invalid_request"` | Nonzero | Correct the arguments or JSON input. |

A process or I/O failure can leave the listener without a JSON receipt. Check standard error for diagnostics. If the outcome of `publish` is uncertain, retry the original report with its original key. After an uncertain `checkpoint`, use `inspect` to see whether the position changed before deciding how to continue.
