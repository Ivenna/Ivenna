# Upgrading Ivenna

## Resuming with continuity notes

1. Stop the kernel and independent subscription listeners. Keep the previous executable with a matched backup of the mailbox and instance database. [Backups and transfers](running.md#backups-and-transfers)
2. If you are upgrading across the move to sessions, back up listener state, update the client programs, and recover any stored source positions and pending reminders you want to carry forward. [Older receivers](#update-older-channel-receivers) · [Listeners and source positions](#update-subscription-listeners) · [Scheduled reminders](#removing-scheduled-attention)
3. Install the updated build and run `ivenna serve` with the existing configuration, mailbox, data directory, and memory workspace. Wait for readiness, then start listeners with the updated executable. [Updating the executable](running.md#updating-the-executable) · [Checking readiness](running.md#service-status-and-reception)

Startup moves the instance database to the new migration record format before reception opens. To roll back after that upgrade commits, restore the matched backup, including any listener state you backed up, and start the previous executable. [Instance database](architecture.md#instance-database) · [Restore an instance](running.md#backups-and-transfers)

The updated kernel restores earlier handovers and continuity notes. In captured inference input, read the note under `continuity.text` and identify the main focus by `current.role` set to `main`. The focus keeps its `core-1` reference. [Input contract](input.md#continuity-notes) · [Earlier history formats](architecture.md#saving-and-restoration)

## Moving receivers and listeners to sessions

Use these steps when moving from individual receiver or subscription commands to sessions. This transition also retires `schedule_attention`. Startup applies the database changes even for an instance with no receivers or listeners.

1. Stop the kernel and its receiver and listener processes, including independent clients. Keep the previous executable with a matched backup of the mailbox, instance database, and listener state. [Backups and transfers](running.md#backups-and-transfers)
2. Install the same updated build for the kernel and its clients. Update your programs, carry forward any saved source positions, and recover the time and text of any pending reminders you want to keep. [Subscription listeners](#update-subscription-listeners) · [Channel receivers](#update-older-channel-receivers) · [Removing scheduled attention](#removing-scheduled-attention)
3. Start `ivenna serve` with the existing mailbox and `DATA_DIR`. The database migration preserves the mailbox binding, subscription IDs, accepted report keys, and queued reports. Once the kernel is ready, start the updated clients with their saved IDs and recreate any reminders you recovered. [Instance database migration](architecture.md#instance-database) · [Checking readiness](running.md#service-status-and-reception)

To roll back, restore the matched backup, including listener state, and start the previous executable. [Restore an instance](running.md#backups-and-transfers)

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

Use the matched backup from the [session upgrade](#moving-receivers-and-listeners-to-sessions) to recover reminders. Take this backup before first startup even if your clients already use sessions.

1. Find the selected checkpoint in the backup's `Ivenna History` folder. In its ZON body, record `.at_unix_ms` and `.text` for the desired entry in `.wakeups`. The matching `.id` in `.callbacks` gives its named reference. If `.text` is null, find the reminder text in `Ivenna Callbacks` using the corresponding `X-Ivenna-Callback-Id` header. [Checkpoint selection](architecture.md#history-storage) · [Callback mail](architecture.md#callback-delivery)
2. After startup, have the intended focus register a subscription. Configure an independent timer listener with the subscription ID, original scheduled time, and reminder text. [Reports from a schedule](subscriptions.md#reporting-from-a-schedule)

## Working history encoding

The updated kernel restores image bytes and upload IDs from records selected by the saved checkpoint. Newly written records store uploaded files by ID and encode inline images losslessly in Base64. This also applies when a fork or context replacement copies an older record. Older records keep their original bodies until the mail service expires them from Trash.

1. Stop the kernel. Keep the previous executable and make a [matched backup of the mailbox and instance database](running.md#backups-and-transfers).
2. If you still need the earlier Stalwart plan update for image and file encoding, [update and apply your mail plan](../dev/README.md#mail). Check the [working history limits](running.md#working-history-limits) against the largest rounds you expect to save, including retained exchanges that a fork or context replacement can rewrite in the new encoding.
3. Start the updated executable with the existing mailbox and its paired instance database.

To roll back after the update writes records in the new encoding, stop the kernel, restore the matched backup, and start the previous executable.

## Adopting the new reasoning defaults

The activity reasoning default changed from `high` to `max`. Quiet reflection uses the separate setting introduced for compaction, which defaults to `max`.

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
