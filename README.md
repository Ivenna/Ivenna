# Ivenna

Ivenna is an agent runtime that explores how a sense of self can develop through ongoing communication, autonomous activity, and memory. See the [design intent](docs/design.md#a-self-in-the-world).

People and programs can write to Ivenna by email. Ivenna sees who wrote, chooses how to act, and decides when to reply or whom else to contact. It can also publish to a named feed and share its ID so readers can follow the messages at their own pace. See [correspondence](docs/usage.md) and [feed readers](docs/communication.md#reading-feeds).

The core is Ivenna's continuing focus of attention. It can open an activity with an assignment and a copy of its working history. From then on their histories grow independently, while both share files, memory, correspondence, and host processes. An activity investigating a failed build can report the compiler error and give the core a log path to read if it needs more context. See [how focuses coordinate](docs/attention.md) and [how they read shared resources](docs/resources.md).

Work can continue between letters. The core can schedule a wakeup, and an activity can resume when a command finishes. Either can subscribe to updates from a source it wants to follow. A listener might watch a project's release page and report new versions to the subscribing focus. See [subscriptions](docs/attention.md#subscriptions) and [writing a listener](docs/subscriptions.md).

## Getting started

Ivenna needs a model endpoint, a mail account for correspondence and working history, and SSH access to a workspace for its shared memory. The deployment user owns the records, memory, and artifacts. See [runtime requirements](docs/running.md#runtime-requirements).

- Use the [local development guide](dev/README.md) to prepare the supplied mail and memory services and run from source.
- Use the [running guide](docs/running.md) to configure another deployment, start the executable, and manage retained data.

## Development

Follow the [development guide](docs/development.md) to build `ivenna` and validate changes. Find component responsibilities and interface contracts through the [documentation index](docs/README.md).
