# Upgrading Ivenna

## Moving receivers and listeners to sessions

1. Stop the kernel and its receivers and listeners. Keep the old executable with a [matched backup of the mailbox and instance database](running.md#backups-and-transfers).
2. Update the kernel and client executables together. Adapt [subscription listeners](#update-subscription-listeners) and [channel receivers](#update-older-channel-receivers) before restarting them.
3. Start the new kernel with the existing mailbox and instance database. When it opens the database, it updates the format marker in place and preserves subscriptions, accepted report keys, and queued reports. Start the updated clients with their saved IDs.

The earlier executable cannot open the upgraded database. To roll back, stop the updated processes and restore the matched backup and corresponding listener progress before starting the old executable. See [backups and transfers](running.md#backups-and-transfers).

### Update subscription listeners

Replace the old `subscription inspect`, `subscription publish`, and `subscription checkpoint` commands with a `subscription listen` session. For an earlier `listen` session that used request wrappers, send reports directly after `"ready"`. Keep using the same report keys. See the [listener protocol](subscriptions.md).

If Ivenna stored a listener's source position, import that value into the listener's own state before resuming. Read saved positions from the old database backup.

```sh
sqlite3 -readonly -json /path/to/backup/state.sqlite3 \
  'SELECT reference, cursor FROM subscriptions WHERE cursor IS NOT NULL ORDER BY id;'
```

Upgraded databases retain the old values for offline export. After the upgrade, the [listener owns source progress](subscriptions.md#resume-at-the-source).

### Update older channel receivers

- Replace `ivenna receive` in all forms with `ivenna channel receive CHANNEL_ID`. Read the `text` field from each JSON line and use the process exit status to interpret the end of the stream. The updated socket protocol requires the new receiver and kernel together. See [receiver sessions](communication.md#receiving-from-a-channel).
- Update senders to handle `channel_no_receiver` as well as `channel_would_block`. See [channel send outcomes](communication.md#sending-to-a-channel).

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
