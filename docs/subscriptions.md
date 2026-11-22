# Subscription listener protocol

A listener calls `ivenna-report` with the `subscription_id` returned by `subscribe`. The report goes to the focus that registered the subscription. Host commands inherit `IVENNA_REPORT`, the executable path, and `DATA_DIR`, the instance directory. Set both paths when [deploying an independent listener](running.md#subscription-listeners).

## Publish an observation

Suppose `subscribe` returned `releases-1` and the listener's first observation is release 17.

```sh
subscription_id='releases-1'
"$IVENNA_REPORT" inspect "$subscription_id"
printf '%s\n' '{"key":"release-17","text":"Release 17 is available","progress":"17"}' |
  "$IVENNA_REPORT" publish "$subscription_id"
```

The first submission prints `"accepted"` once the report and cursor are saved locally, even while the kernel is stopped. Repeating it on the active subscription prints `"duplicate"`. When the kernel is running, the [reminder](attention.md#subscriptions) determines when the focus receives the [observation](input.md#subscription-observations).

Programs can invoke the executable with the command and subscription ID as two arguments. `publish` and `checkpoint` each read one JSON object of up to 64 KiB from standard input. Text fields take nonempty UTF-8 strings.

| `publish` fields | Meaning |
| --- | --- |
| `key`, `text` | Required. Use a stable key (up to 256 bytes) and a description for the focus (up to 2,048 bytes). Give each distinct update its own key, including later revisions of the same item. |
| `source_time_unix_ms`, `truncated` | Optional upstream event time in Unix milliseconds and whether the description is an excerpt. The reporter supplies the local receipt time. |
| `retrieval`, `handle`, `version` | The default `unavailable` carries no handle. Supply a handle with `current` to reopen the latest state or with `version` to reopen the observed revision. The optional version label and the handle each allow up to 512 bytes. |
| `progress`, `expected_progress` | To advance the cursor with the report, set `progress` to the new position. If a cursor is already saved, pass that value as `expected_progress`. |

## Resume from a cursor

`inspect` returns JSON `null` if the reference has no registration in this instance. Otherwise it returns the registration (`subscription_id`, `focus_id`, `listener`, `reminder`), its current state (`active`, `external`, `status`), the saved cursor (`progress`) and the number of reports awaiting acknowledgement (`pending`).

A replacement listener can continue the same subscription using its saved cursor and key convention. Supply that cursor as `expected_progress` when advancing it. A new subscription has its own keys and a null cursor, so omit `expected_progress` on its first advance. A new report and its cursor commit together. A duplicate leaves the cursor unchanged.

Use `checkpoint` to save one or more of `progress`, `status` and `external` without queuing an observation. For example, if the listener filters out item 18, it can still save that position.

```sh
printf '%s\n' '{"expected_progress":"17","progress":"18"}' |
  "$IVENNA_REPORT" checkpoint "$subscription_id"
```

Advance through the items the listener has processed. If the source can no longer replay an interval, use `publish` to describe the gap and the range the listener could recover.

## Withdrawal and external follows

Between source reads, `inspect` can tell a listener whether its registration is still active. After withdrawal, `publish` returns `"withdrawn"` for that reference. Already accepted reports keep their reminder. A later subscription to the same source gets a new reference.

If collecting a source requires a follow request to the publisher, set `external` to `true` with `checkpoint` before sending the request. Use `status` (up to 512 bytes) to record what the publisher has confirmed or what is still pending. Reconcile an uncertain response with the publisher.

After local withdrawal an outstanding follow remains visible as `active: false`, `external: true`. The listener can still update its status. Once the publisher confirms closure, checkpoint `{"external":false}` on the old reference. The registration is then retired. If the publisher allows one follow per account and source, confirm closure before opening another follow there.

## Command results

Read the JSON result from standard output. Successful commands exit zero. Rejections exit nonzero.

| Result | Listener action |
| --- | --- |
| `"accepted"` | The report or checkpoint was saved. Continue. |
| `"duplicate"` | The active subscription already accepted this report key. The original receipt still applies after delivery to the focus. |
| `"withdrawn"` | This reference has no active registration in this instance. Stop reporting on it. Inspect it if an external follow needs cleanup. |
| `"progress_conflict"` | Read the saved cursor with `inspect` and reconcile it with the source before advancing. |
| `"busy"` | Retry when store contention subsides. |
| `"storage_full"` | Free space in the instance's store before retrying. |
| `"invalid_request"` | Correct the arguments or JSON input. |

If a write ends without a readable receipt, its outcome can be uncertain. Retry a report with its original key. For a checkpoint, inspect the registration to see which changes were saved.
