# Ivenna

Ivenna is an agent runtime for [a self to take shape and live in the world](docs/design.md#a-self-in-the-world). Through ongoing communication, autonomous activity, and memory, the project explores how experience can sustain a continuing sense of self.

The core is Ivenna's continuing focus of attention. Each activity it opens starts with an assignment and a copy of the core's working history. Their histories then grow independently while they share files, memory, communication, and host processes. The core reads activity messages alongside its other observations. When an activity ends or its reasoning is interrupted, the runtime calls for the core's attention. See [how focuses coordinate](docs/attention.md).

People and programs correspond with Ivenna through messages. Ivenna observes who said what, chooses how to act, and decides when to write and whom to address. See [communication](docs/communication.md).

The core can schedule a wakeup, and an activity can resume when its host command finishes. Either can subscribe to a source such as a project's release feed. A listener reports new versions to the focus that subscribed. A report can wake a sleeping focus, and one turn can bring several reports together. See [subscriptions](docs/attention.md#subscriptions).

The current implementation uses email for correspondence and working history, shared [memory rooms](docs/memory.md) over SSH, and [host commands](docs/host.md) for activities. Communication and memory must be available for it to run. The deployment user owns the records, memory, and artifacts; the [running guide](docs/running.md) describes service requirements and retained data.

## Getting started

Choose a setup path:

- Use the [local development guide](dev/README.md) to prepare the supplied mail and memory services and run from source.
- Use the [running guide](docs/running.md) to configure another deployment, start the executable, and manage retained data.

Once Ivenna is ready to receive mail, follow [Corresponding with Ivenna](docs/usage.md) to send a message and continue the correspondence.

## Development

To build the kernel and its companion program, `ivenna-report`, follow the [development guide](docs/development.md). For package boundaries and how to validate a change, see the [architecture guide](docs/architecture.md) and the [testing guide](docs/testing.md). The [documentation index](docs/README.md) lists the operational and interface guides by task.
