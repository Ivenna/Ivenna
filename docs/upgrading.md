# Upgrading Ivenna

## From feeds to channels

Feed readers paged through stored messages. A channel hands each message to one waiting receiver while the kernel runs. Update senders to handle `channel_would_block` when a send cannot hand off the message. See [send outcomes](communication.md#sending-to-a-channel).

### Prepare the existing instance

1. Stop the kernel and locate its current `state.sqlite3`. If `DATA_DIR` traverses a symbolic link before `..`, configure the updated executable with the absolute path of the directory holding that database. The updated kernel follows the link before traversing `..`.
2. Make a matched backup of the instance database and mailbox. Keep the old executable with the backup. See [backups and transfers](running.md#backups-and-transfers).

### Optional feed cleanup

The updated kernel leaves old feed data in `feeds` and `feed_messages`. Inspect or export it from the backup if needed. To remove the old tables from the live database, verify the backup and keep the kernel stopped while running this transaction against the existing `state.sqlite3`.

```sql
BEGIN IMMEDIATE;
DROP TABLE IF EXISTS feed_messages;
DROP TABLE IF EXISTS feeds;
COMMIT;
```

### Update callers and receivers

| Replace | With |
| --- | --- |
| `create_feed` and `close_feed` | `open_channel` and `close_channel` |
| `send` with `to.feed_id` | `send` with `to.channel_id` |
| `ivenna feed read FEED_ID` | `ivenna receive CHANNEL_ID` |

Replace page and sequence tracking with one JSON line per read result. Use `--timeout MS` for a bounded single read or `--follow` to stream message records. See [receive results](communication.md#receiving-from-a-channel).

Start the updated kernel with the existing instance database and mailbox to resume subscriptions and working history. Open a channel for each stream you want to continue. Give its ID to the receiving program and start the receiver before sending. See [channel receiver deployment](running.md#channel-receivers).

## From an earlier channel build

Use `receive --timeout MS` for the bounded wait previously selected by `--wait MS`. Handle `channel_would_block` in place of `channel_not_ready`. Every saved channel now survives a restart, including one whose opening activity has ended; close a channel you no longer need. After upgrading a kernel that ran without channel checkpoints, open channels for the streams you want to resume and give receivers the new IDs. See [send outcomes](communication.md#sending-to-a-channel) and [channel lifetimes](communication.md#channel-lifetimes).

## Reading tool results

- Identify commands in `inspect_host_shell` by `command_id` and `focus_id`. The list drops `command_preview`. See [continuing and controlling a command](host.md#continuing-and-controlling-a-command).
- Read file upload failures through `error.code` and `error.message`. The result drops `error.http_status`. See [upload outcomes and diagnostics](content.md#complete-files).
