# Subscription listener protocol

Give the listener the complete `subscription_id` returned by Ivenna's `subscribe` tool. The listener invokes `ivenna-report` with that ID to send observations to the subscribing focus. The examples use the executable path in `IVENNA_REPORT` and the kernel's data directory in `DATA_DIR`. Host commands inherit both variables. See [subscription registration](attention.md#subscriptions) and [deploying an independent listener](running.md#subscription-listeners).

## Publish an observation

Suppose a new subscription, `releases-1`, follows a release feed. Item 17 announces a stable release, v2.4.0. The listener can report the release and save its place in the feed in one write.

```sh
subscription_id='releases-1'
printf '%s\n' '{"key":"release-v2.4.0","text":"Stable release v2.4.0 is available","cursor":{"to":"17"}}' |
  "$IVENNA_REPORT" publish "$subscription_id"
```

`publish` returns `"accepted"` once the report and any cursor change commit together, even while the kernel is stopped. The report is queued for the subscribing focus, which can wake to receive it or read it between rounds. See [subscription delivery](attention.md#subscriptions) and the [observation fields](input.md#subscription-observations).

| Field | Use |
| --- | --- |
| `key` | Required nonempty string identifying this update within the subscription. Reuse it for retries and choose a new key for a later revision. Separate subscriptions to the same feed may use the same keys. |
| `text` | Required nonempty string of up to 2,048 UTF-8 bytes describing what the listener observed. Include the revision, where to read more, or any gap in coverage when that matters to the focus. |
| `source_time_unix_ms` | Optional source event time in integer milliseconds since the Unix epoch, from `0000-01-01T00:00:00.000Z` through `9999-12-31T23:59:59.000Z`. The reporter records the local receipt time. |
| `cursor` | Optional object with the [cursor change](#resume-from-a-cursor) to commit with the report. A listener that tracks no source position can publish with just `key` and `text`. |

## Resume from a cursor

```sh
"$IVENNA_REPORT" inspect "$subscription_id"
```

`inspect` returns the registration and its saved source position. After the example publication, the output for a core subscription would look like this.

```json
{"subscription_id":"releases-1","focus_id":"core-1","listener":"Report each new stable version from the project's release feed.","cursor":"17"}
```

A new registration has `"cursor": null`. For a withdrawn or unknown ID, `inspect` prints JSON `null` and exits successfully.

After a restart, the release listener reads the saved cursor `"17"` and asks the feed for later items. A replacement listener can continue on the same subscription if it understands the source position and the keys its predecessor used.

Suppose item 18 is a prerelease that the listener filters out. Use `checkpoint` to record that position without sending an observation. It takes the same cursor change that `publish` accepts in its `cursor` field.

```sh
printf '%s\n' '{"from":"17","to":"18"}' |
  "$IVENNA_REPORT" checkpoint "$subscription_id"
```

Set `to` to a string containing the new position. The reporter saves it only if `from` matches the stored cursor. Omitting `from` or passing `null` matches a cursor that has never been set. If the saved position is the empty string, pass `"from": ""`.

When `from` no longer matches, a checkpoint or a new report returns `"cursor_conflict"`. A report rejected for this reason leaves its key available for retry. Read the current cursor with `inspect` and check which items still need processing. If the source can no longer replay some items, a report can identify the gap.

## Withdrawal

Withdrawal closes intake on that reference and releases its cursor and retry keys. Reports already accepted remain queued for their original focus until admitted. Registering the same source again gives the listener a fresh reference with its own cursor and keys.

## Command results

Each write reads one JSON object from standard input. The current reporter's JSON reader limits each string to 4 MiB. Read the JSON result from standard output and check the exit status.

| Result | Exit | Listener action |
| --- | --- | --- |
| `"accepted"` | Zero | The write committed. Continue. |
| `"duplicate"` | Zero | This subscription already accepted the key, even if the focus has since read the report. The saved cursor stays in place. |
| `"withdrawn"` | Nonzero | The ID is unknown or the subscription has been withdrawn. Stop reporting on this reference. |
| `"cursor_conflict"` | Nonzero | Read the saved cursor before continuing. |
| `"busy"` | Nonzero | Retry after store contention subsides. |
| `"storage_full"` | Nonzero | Free storage before retrying. |
| `"invalid_request"` | Nonzero | Correct the arguments or JSON input. |

A process or I/O failure can leave the listener without a complete JSON receipt, even when the write committed. Check standard error for diagnostics. Retry an uncertain `publish` with its original key. After an uncertain `checkpoint`, use `inspect` to see whether the position changed before deciding how to continue.
