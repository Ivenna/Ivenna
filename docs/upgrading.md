# Upgrading Ivenna

## From feeds to channels

Channels hand each message to one waiting receiver while the kernel runs. A channel has its own ID. See [channel lifetimes](communication.md#channel-lifetimes) for when receivers can reuse it.

### Prepare the existing instance

1. Stop the kernel and locate its current `state.sqlite3`. If `DATA_DIR` traverses a symbolic link before `..`, configure the updated executable with the absolute path of the directory holding that database. The updated kernel follows the link before traversing `..`.
2. Make a matched backup of the instance database and mailbox. Keep the old executable with the backup. The old `feeds` and `feed_messages` tables are available for inspection or export from the backup. See [backups and transfers](running.md#backups-and-transfers).

### Update callers and receivers

| Replace | With |
| --- | --- |
| `create_feed` and `close_feed` | `open_channel` and `close_channel` |
| `send` with `to.feed_id` | `send` with `to.channel_id` |
| `ivenna feed read FEED_ID` | `ivenna receive CHANNEL_ID` |

Replace page and sequence tracking with one JSON line per receive result. Use `--timeout MS` for a bounded wait or `--follow` for a stream. See [sending to a channel](communication.md#sending-to-a-channel) and [receiving from a channel](communication.md#receiving-from-a-channel).

Start the updated kernel with the existing instance database and mailbox to resume subscriptions and working history. Open a channel for each stream you want to continue. Give its ID to the receiving program and start the receiver before sending. See [channel receiver deployment](running.md#channel-receivers).

## Updating channel receivers

Use `receive --timeout MS` for the bounded wait previously selected by `--wait MS`. Handle `channel_would_block` in place of `channel_not_ready`. After upgrading a kernel that ran without channel checkpoints, open channels for the streams you want to resume and give receivers their IDs. Subsequent restarts restore saved channels whose opening focuses return. See [channel receive and send outcomes](communication.md#channels).

## Reading tool results

- Identify commands in `inspect_host_shell` by `command_id` and `focus_id`. The list drops `command_preview`. See [continuing and controlling a command](host.md#continuing-and-controlling-a-command).
- Read file upload failures through `error.code` and `error.message`. The result drops `error.http_status`. Look up the service's HTTP status in the kernel log. See [complete files](content.md#complete-files).
