# Ivenna

Ivenna is an agent runtime for [a self to take shape and live in the world](docs/design.md#a-self-in-the-world). Through ongoing communication, autonomous activity, and memory, the project explores how experience can sustain a continuing sense of self.

People and programs can write to Ivenna by email. Ivenna sees who wrote, chooses how to act, and decides when to reply or whom else to contact. It can also create named feeds for people and programs to read at their own pace. See [Corresponding with Ivenna](docs/usage.md) and [Communication](docs/communication.md).

The core is Ivenna's continuing focus of attention. It can open an activity with an assignment and a copy of its working history. From then on their histories grow independently, while both share files, memory, correspondence, and host processes. An activity investigating a failed build can report the compiler error and give the core a log path to read if it needs more context. See [how focuses coordinate](docs/attention.md) and [how they read shared resources](docs/resources.md).

Work can continue between letters. The core can schedule a wakeup, and an activity can resume when a command finishes. Either can subscribe to a source such as a project's release feed. A separate listener watches the feed and brings new releases to the attention of the subscribing focus. See [subscriptions](docs/attention.md#subscriptions) and [writing a listener](docs/subscriptions.md).

## Getting started

Ivenna needs an email service for correspondence and working history, and SSH access to its shared [memory rooms](docs/memory.md). The deployment user owns the records, memory, and artifacts.

- Use the [local development guide](dev/README.md) to prepare the supplied mail and memory services and run from source.
- Use the [running guide](docs/running.md) to configure another deployment, start the executable, and manage retained data.

## Development

To build the kernel and the subscription reporter, `ivenna-report`, follow the [build instructions](docs/development.md#repository-and-build). For package boundaries and how to validate a change, see the [architecture guide](docs/architecture.md) and the [testing guide](docs/testing.md). The [documentation index](docs/README.md) lists the operational and interface guides by task.
