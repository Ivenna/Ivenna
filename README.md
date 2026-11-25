# Ivenna

Ivenna is an agent runtime that explores how a sense of self can develop through ongoing communication, autonomous activity, and memory. See the [design intent](docs/design.md#a-self-in-the-world).

People and programs can write to Ivenna by email. Each letter identifies its senders. Ivenna chooses how to act, whom to contact, and when to write. It can also hand messages to waiting local programs through named channels. See [correspondence](docs/usage.md) and [channels](docs/communication.md#channels).

The core is Ivenna's continuing focus of attention. It can open an activity with an assignment and a copy of its working history. Their histories then grow independently while they share files, memory, correspondence, and host processes. An activity investigating a failed build can report the compiler error and point the core to the log in their shared workspace. See [how focuses coordinate](docs/attention.md) and [how they read shared resources](docs/resources.md).

Work can continue between letters. The core can schedule a wakeup, and an activity can resume when a command finishes. Either can subscribe to updates from a source it wants to follow. A listener might watch a project's release page and report new versions to the subscribing focus. See [subscriptions](docs/attention.md#subscriptions) and [writing a listener](docs/subscriptions.md).

## Getting started

Ivenna needs a model endpoint, a mail account for correspondence and working history, and SSH access to a workspace for its shared memory. The deployment user owns the records, memory, and artifacts. See [runtime requirements](docs/running.md#runtime-requirements).

- Use the [local development guide](dev/README.md) to prepare the supplied mail and memory services and run from source.
- Use the [running guide](docs/running.md) to configure a deployment, start the executable, and manage retained data.
- Use the [upgrade guide](docs/upgrading.md) to update an existing instance across an interface or storage change.

## Development

Follow the [development guide](docs/development.md) to build `ivenna` and validate changes. Find component responsibilities and interface contracts through the [documentation index](docs/README.md).
