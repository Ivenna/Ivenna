# Upgrading Ivenna

## Moving receivers and listeners to sessions

This update changes the receiver and listener commands. The kernel upgrades the instance database on startup, even for an instance with no receivers or listeners.

1. Stop the kernel and every receiver and listener for the instance, including independently run clients. Keep the old executable and take a matched backup of the mailbox, instance database, and any listener progress. [Backups and transfers](running.md#backups-and-transfers)
2. Install the same updated build for the kernel and its clients. Update the client programs and import any positions Ivenna stored into the listeners' own state. Use the backup to recover any old reminders you want to carry forward. [Subscription listeners](#update-subscription-listeners) · [Channel receivers](#update-older-channel-receivers) · [Removing scheduled attention](#removing-scheduled-attention)
3. Start `ivenna serve` with the existing mailbox and `DATA_DIR`. Startup removes the old cursor column if present and preserves the mailbox binding, subscription IDs, accepted report keys, and queued reports. Then start the updated clients with their saved IDs.

To return to the old executable after migration, restore the pre-upgrade mailbox, database, and listener progress before restarting it. [Restore an instance](running.md#backups-and-transfers)

### Update subscription listeners

Replace `subscription inspect`, `subscription publish`, and `subscription checkpoint` with a `subscription listen` session. If your listener already uses `listen` with request wrappers, send each report as a top-level JSON object after `"ready"`. Keep the same keys for reports you retry. [Listener protocol](subscriptions.md)

If Ivenna stored source positions, export them by subscription ID from the pre-upgrade database backup. Import each position into the corresponding listener's own state before starting it.

```sh
sqlite3 -readonly -json /path/to/backup/state.sqlite3 \
  'SELECT reference, cursor FROM subscriptions WHERE cursor IS NOT NULL ORDER BY id;'
```

The listener owns later source progress. [Resuming at the source](subscriptions.md#resume-at-the-source)

### Update older channel receivers

- Replace `ivenna receive` and its options with `ivenna channel receive CHANNEL_ID`. Read the `text` field from each JSON line and use the process exit status to interpret the end of the stream. [Receiver sessions](communication.md#receiving-from-a-channel)
- Update senders to handle `channel_no_receiver` and `channel_would_block`. [Channel send outcomes](communication.md#sending-to-a-channel)

## Removing scheduled attention

The first startup without `schedule_attention` retires wakeups that have yet to enter working history, including copies already in `Ivenna Callbacks`. Admitted wakeup observations and dated handover samples remain readable. Host completion callbacks and queued subscription reports still go to their original focuses.

To carry old reminders forward or retain a rollback point, use the matched backup from the [session upgrade](#moving-receivers-and-listeners-to-sessions). If your database and clients are already on the session format, take a matched backup with the old kernel stopped before starting the updated build. Keep the previous executable if you want to roll back. [Backups and transfers](running.md#backups-and-transfers)

1. In the backup, find the selected checkpoint in `Ivenna History`. For each reminder you want to recreate, record its `.at_unix_ms` and `.text` from `.wakeups` in the checkpoint's ZON body. The entry in `.callbacks` with the same `.id` gives its named reference. If `.text` is null, look for the reminder body in `Ivenna Callbacks` with the matching `X-Ivenna-Callback-Id`. [Finding the selected checkpoint](architecture.md#history-storage) · [Callback mail](architecture.md#callback-delivery)
2. After startup, register a subscription in the focus that should receive the reminder. Configure an independent timer listener with the returned ID, the original scheduled time, and the reminder text. [Reports from a schedule](subscriptions.md#reporting-from-a-schedule)

To roll back, restore the matched pre-upgrade backup and start the previous executable. [Restoring a backup](running.md#backups-and-transfers)

## Working history encoding

The updated kernel restores image bytes and upload IDs from records selected by the saved checkpoint. Newly written records store uploaded files by ID and encode inline images losslessly in Base64. This also applies when a fork or handover copies an older record. Older records keep their original bodies until the mail service expires them from Trash.

1. Stop the kernel. Keep the previous executable and make a [matched backup of the mailbox and instance database](running.md#backups-and-transfers).
2. If you use the supplied Stalwart setup, [update and apply your mail plan](../dev/README.md#mail). Check the [working history limits](running.md#working-history-limits) against the largest rounds you expect to save, including retained exchanges that a fork or handover can rewrite in the new encoding.
3. Start the updated executable with the existing mailbox and its paired instance database.

To roll back after the update writes records in the new encoding, stop the kernel, restore the matched backup, and start the previous executable.

## Adopting the new reasoning defaults

The activity reasoning default changed from `high` to `max`. Handovers previously used a fixed effort of `high` and now have a separate setting that defaults to `max`.

The earlier `.env.example` set `LLM_ACTIVITY_REASONING_EFFORT=high` explicitly. Remove that override from the kernel's launch environment to adopt the new activity default. To keep the previous defaults, set both `LLM_ACTIVITY_REASONING_EFFORT` and `LLM_COMPACTION_REASONING_EFFORT` to `high`. Restart the kernel with the chosen settings. See [model requests](running.md#model-requests) and [loading the local environment](../dev/README.md#configuration).

## Upgrading to saved session progress

1. Stop the kernel. Keep the previous executable and make a matched backup of the mailbox and instance database. See [backups and transfers](running.md#backups-and-transfers).
2. Start the updated executable with the existing mailbox and its paired `state.sqlite3`.

Startup restores the saved history from that mailbox and publishes it in the new checkpoint format before history maintenance and the first model request. See [checkpoint saving and restoration](architecture.md#saving-and-restoration).

To roll back, stop the kernel and restore the mailbox and instance database from the pre-upgrade backup. Start the previous executable with that restored pair to resume at the backup's saved state. See [backups and transfers](running.md#backups-and-transfers).

## From feeds to channels

Feed readers paged through stored messages. A channel hands each message to one waiting receiver while the kernel runs. Update senders using the current [channel send outcomes](communication.md#sending-to-a-channel).

### Prepare the existing instance

1. Stop the kernel and locate its current `state.sqlite3`. If `DATA_DIR` traverses a symbolic link before `..`, configure the updated executable with the absolute path of the directory holding that database. The updated kernel follows the link before traversing `..`.
2. Make a matched backup of the instance database and mailbox. Keep the old executable with the backup. See [backups and transfers](running.md#backups-and-transfers).

### Update callers and receivers

| Replace | With |
| --- | --- |
| `create_feed` and `close_feed` | `open_channel` and `close_channel` |
| `send` with `to.feed_id` | `send` with `to.channel_id` |
| `ivenna feed read FEED_ID` | `ivenna channel receive CHANNEL_ID` |

Replace page and sequence tracking with a stream of JSON lines, one per message. See [receiver sessions](communication.md#receiving-from-a-channel).

Start the updated kernel with the existing instance database and mailbox to resume subscriptions and working history. Open a channel for each stream you want to continue. Give its ID to the receiving program and start the receiver before sending. See [channel receiver deployment](running.md#channel-receivers).

### Optional feed cleanup

The updated kernel leaves old feed data in `feeds` and `feed_messages`. Inspect or export it from the backup if needed. After validating the upgrade, you can remove these tables from the live database. Verify the backup, stop the kernel, and run this transaction against the existing `state.sqlite3`.

```sql
BEGIN IMMEDIATE;
DROP TABLE IF EXISTS feed_messages;
DROP TABLE IF EXISTS feeds;
COMMIT;
```

## From an earlier channel build

Use the [session upgrade](#moving-receivers-and-listeners-to-sessions) for the receiver and update senders that handled `channel_not_ready`. See [send outcomes](communication.md#sending-to-a-channel).

Reuse a channel ID if the checkpoint saved its registration. Open a replacement channel for any registration absent from the checkpoint and give the new ID to the receiver. Builds before channel checkpoints saved no registrations. Some later builds kept only registrations whose opening focus was still present. See [channel lifetimes](communication.md#channel-lifetimes).

## Reading tool results

- Identify commands in `inspect_host_shell` by `command_id` and `focus_id`. The list drops `command_preview`. See [continuing and controlling a command](host.md#continuing-and-controlling-a-command).
- Read file upload failures through `error.code` and `error.message`. The result drops `error.http_status`. See [upload outcomes and diagnostics](content.md#complete-files).
