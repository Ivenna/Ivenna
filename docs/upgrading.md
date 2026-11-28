# Upgrading Ivenna

## Resuming with continuity notes

1. Stop the kernel and independent subscription listeners. Keep the previous executable with a matched backup of the mailbox, instance database, and any listener state. [Backups and transfers](running.md#backups-and-transfers)
2. If your deployment predates receiver and listener sessions, update those clients and recover the source positions and reminder details you want to carry forward. [Moving to sessions](#moving-receivers-and-listeners-to-sessions)
3. Install the updated executable and run `ivenna serve` with the existing configuration, mailbox, data directory, and memory workspace. Wait for reception to open before starting listeners with the updated executable. [Checking readiness](running.md#service-status-and-reception)

Startup updates the instance database's migration format before reception opens. Once the migration commits, roll back by restoring the matched backup and running the previous executable. This applies even before the first quiet reflection. [Instance database](architecture.md#instance-database) · [Restore an instance](running.md#backups-and-transfers)

The updated kernel restores earlier handovers as continuity notes. Programs reading captured inference input should use `continuity.text` in place of `handover.summary` and read `current.role` as `main` for the focus with ID `core-1`. [Continuity notes](input.md#continuity-notes) · [Inference turns](input.md#inference-turns) · [Earlier history formats](architecture.md#saving-and-restoration)

## Moving receivers and listeners to sessions

Before updating an instance that still uses individual receiver or subscription commands, stop its receivers as well. Recover source positions and reminders from the pre-upgrade backup. Update the clients before reconnecting them with their saved IDs. [Upgrade steps](#resuming-with-continuity-notes)

Startup migrates the database even if the instance has no receivers or listeners. It preserves mailbox pairing, subscription IDs, accepted report keys, and queued reports. [Instance database migration](architecture.md#instance-database)

### Update subscription listeners

Replace `subscription inspect`, `subscription publish`, and `subscription checkpoint` with a `subscription listen` session. If your program uses the earlier `listen` protocol with wrapped requests, remove the wrapper and send each report as a top-level JSON object after `"ready"`. Keep the original key for any report you retry. [Listener protocol](subscriptions.md)

If the pre-upgrade database has a `cursor` column, export saved source positions by subscription ID from the backup. Import each position into the corresponding listener's own state before starting it.

```sh
sqlite3 -readonly -json /path/to/backup/state.sqlite3 \
  'SELECT reference, cursor FROM subscriptions WHERE cursor IS NOT NULL ORDER BY id;'
```

The listener owns later source progress. [Resuming at the source](subscriptions.md#resume-at-the-source)

### Update older channel receivers

- Replace `ivenna receive` and its options with `ivenna channel receive CHANNEL_ID`. Read the `text` field from each JSON line and use the process exit status to interpret the end of the stream. [Receiver sessions](communication.md#receiving-from-a-channel)
- Update senders to handle `channel_no_receiver` and `channel_would_block`. [Channel send outcomes](communication.md#sending-to-a-channel)

### Removing scheduled attention

The session upgrade retires scheduled wakeups that have yet to enter working history, including copies already in `Ivenna Callbacks`. Wakeup observations already in history and dated handover samples remain readable. Host completions and queued subscription reports still go to their original focuses.

Use the pre-upgrade backup to recover a reminder before replacing it with a subscription. [Backups and transfers](running.md#backups-and-transfers)

1. Find the selected checkpoint in the backup's `Ivenna History` folder. In its ZON body, record `.at_unix_ms` and `.text` for the desired entry in `.wakeups`. The matching `.id` in `.callbacks` gives its named reference. If `.text` is null, find the reminder text in `Ivenna Callbacks` using the corresponding `X-Ivenna-Callback-Id` header. [Checkpoint selection](architecture.md#history-storage) · [Callback mail](architecture.md#callback-delivery)
2. After startup, have the intended focus register a subscription. Configure an independent timer listener with the subscription ID, original scheduled time, and reminder text. [Reports from a schedule](subscriptions.md#reporting-from-a-schedule)

## Working history encoding

The updated kernel restores image bytes and upload IDs from records selected by the saved checkpoint. Newly written records store uploaded files by ID and encode inline images losslessly in Base64. This also applies when a fork or context replacement copies an older record. Older records keep their original bodies until the mail service expires them from Trash.

1. Stop the kernel. Keep the previous executable and make a [matched backup of the mailbox and instance database](running.md#backups-and-transfers).
2. If you still need the earlier Stalwart plan update for image and file encoding, [update and apply your mail plan](../dev/README.md#mail). Check the [working history limits](running.md#working-history-limits) against the largest rounds you expect to save, including retained exchanges that a fork or context replacement can rewrite in the new encoding.
3. Start the updated executable with the existing mailbox and its paired instance database.

To roll back after the update writes records in the new encoding, stop the kernel, restore the matched backup, and start the previous executable.

## Adopting the new reasoning defaults

The earlier `.env.example` set `LLM_ACTIVITY_REASONING_EFFORT=high` explicitly. Remove that override from the kernel's launch environment to use the current default, or keep it to continue ordinary activity work at `high`. To use `high` for quiet reflection, set `LLM_COMPACTION_REASONING_EFFORT=high`. Restart with the chosen settings. [Configuration defaults](running.md#configuration) · [Loading the local environment](../dev/README.md#configuration)

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
