# Ivenna

[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/Ivenna/Ivenna)

Ivenna is an agent runtime for correspondence, autonomous activity, and memory. It explores how a self can take shape when past experience carries forward through changes in attention and interruptions. See the [design intent](docs/design.md).

People and programs can write to Ivenna by email. Each letter identifies its senders. Ivenna chooses how to act, whom to contact, and when to write. It can also hand messages to waiting local programs through named channels. See [correspondence](docs/usage.md) and [channels](docs/communication.md#channels).

The core is Ivenna's continuing focus of attention. It can open an activity with an assignment and a copy of its working history. Their histories then grow independently while they share files, memory, correspondence, and host processes. An activity investigating a failed build can report the compiler error and point the core to the log in their shared workspace. See [how focuses coordinate](docs/attention.md) and [how they read shared resources](docs/resources.md).

Work can continue between letters. The core can schedule a wakeup, and an activity can resume when a command finishes. Either can subscribe to updates from a source it wants to follow. A listener might watch a project's release page and report new versions to the subscribing focus. See [subscriptions](docs/attention.md#subscriptions) and [writing a listener](docs/subscriptions.md).

## Getting started

To run Ivenna, you need a DeepSeek API key for the Responses API, a mail account for correspondence and working history, and SSH access to a workspace for shared memory. See [runtime requirements](docs/running.md#runtime-requirements).

- Use the [local development guide](dev/README.md) to prepare the supplied mail and memory services and run from source.
- Use the [running guide](docs/running.md) to configure a deployment, start the executable, and manage retained data.
- When updating an existing instance, check the [upgrade guide](docs/upgrading.md) for changes to settings, stored data, and programs that use Ivenna.

## Development

Follow the [development guide](docs/development.md) to build `ivenna` and validate changes. Find component responsibilities and interface contracts through the [documentation index](docs/README.md).
