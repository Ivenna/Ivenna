# Upgrading Ivenna

## File references in working history

To keep the option of rolling back, back up the mailbox and instance database as a pair before upgrading. Older kernels cannot read a history record containing the new `file_reference` part. See [backups and transfers](running.md#backups-and-transfers).

Start the updated kernel with the existing mailbox and its paired instance database. It reads the DeepSeek file ID from earlier file results. New records refer to an uploaded file by its ID, including when a fork or compaction copies an older result. The original bytes in older mailbox records remain until those records are retired to Trash and expire under the mail service's retention policy.

## Adopting the new reasoning defaults

The activity reasoning default changed from `high` to `max`. Handovers previously used a fixed effort of `high` and now have a separate setting that defaults to `max`.

The earlier `.env.example` set `LLM_ACTIVITY_REASONING_EFFORT=high` explicitly. Remove that override from the kernel's launch environment to adopt the new activity default. To keep the previous defaults, set both `LLM_ACTIVITY_REASONING_EFFORT` and `LLM_COMPACTION_REASONING_EFFORT` to `high`. Restart the kernel with the chosen settings. See [model requests](running.md#model-requests) and [loading the local environment](../dev/README.md#configuration).

## Upgrading to saved session progress

1. Stop the kernel. Keep the previous executable and make a matched backup of the mailbox and instance database. See [backups and transfers](running.md#backups-and-transfers).
2. Start the updated executable with the existing mailbox and its paired `state.sqlite3`.

Startup restores the saved history from that mailbox and publishes it in the new checkpoint format before history maintenance and the first model request. See [checkpoint saving and restoration](architecture.md#saving-and-restoration).

To roll back, stop the kernel and restore the mailbox and instance database from the pre-upgrade backup. Start the previous executable with that restored pair to resume at the backup's saved state. See [backups and transfers](running.md#backups-and-transfers).

## From feeds to channels

Feed readers paged through stored messages. A channel hands each message to one waiting receiver while the kernel runs. Update senders to handle `channel_would_block` when a send cannot hand off the message. See [send outcomes](communication.md#sending-to-a-channel).

### Prepare the existing instance

1. Stop the kernel and locate its current `state.sqlite3`. If `DATA_DIR` traverses a symbolic link before `..`, configure the updated executable with the absolute path of the directory holding that database. The updated kernel follows the link before traversing `..`.
2. Make a matched backup of the instance database and mailbox. Keep the old executable with the backup. See [backups and transfers](running.md#backups-and-transfers).

### Update callers and receivers

| Replace | With |
| --- | --- |
| `create_feed` and `close_feed` | `open_channel` and `close_channel` |
| `send` with `to.feed_id` | `send` with `to.channel_id` |
| `ivenna feed read FEED_ID` | `ivenna receive CHANNEL_ID` |

Replace page and sequence tracking with one JSON line per read result. Use `--timeout MS` for a bounded single read or `--follow` to stream message records. See [receive results](communication.md#receiving-from-a-channel).

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

Update the kernel and receiver executables together. Replace `receive --wait MS` with `receive --timeout MS`, and handle `channel_would_block` in place of `channel_not_ready`. See [receiver deployment](running.md#channel-receivers) and [send outcomes](communication.md#sending-to-a-channel).

Reuse a channel ID if the checkpoint saved its registration. Open a replacement channel for any registration absent from the checkpoint and give the new ID to the receiver. Builds before channel checkpoints saved no registrations. Some later builds kept only registrations whose opening focus was still present. See [channel lifetimes](communication.md#channel-lifetimes).

## Reading tool results

- Identify commands in `inspect_host_shell` by `command_id` and `focus_id`. The list drops `command_preview`. See [continuing and controlling a command](host.md#continuing-and-controlling-a-command).
- Read file upload failures through `error.code` and `error.message`. The result drops `error.http_status`. See [upload outcomes and diagnostics](content.md#complete-files).
