# Ivenna

[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/Ivenna/Ivenna)

Ivenna is an agent runtime for correspondence, autonomous activity, and memory. It explores how a self can take shape when past experience carries forward through changes in attention and interruptions. See the [design intent](docs/design.md).

People and programs can write to an instance by email. Each letter identifies its senders. The instance chooses how to act, whom to contact, and when to write. It can also hand messages to waiting local programs through named channels. [Correspondence](docs/usage.md) · [Channels](docs/communication.md#channels)

An instance's main focus receives correspondence and can give a question or piece of work its own activity focus. The activity starts with the main focus's working history and then develops its own. The focuses can draw on shared files and memory. For example, an activity investigating a failed build can report a compiler error and point the main focus to the log. [How focuses coordinate](docs/attention.md)

Work can continue between letters. An activity can resume when its command finishes, and any focus can subscribe to reports from a listener. When working history needs room, a focus can pause for quiet reflection and carry a note forward. [Subscriptions](docs/attention.md#subscriptions) · [Continuity of experience](docs/design.md#context-and-continuity)

## Getting started

Ivenna uses a DeepSeek API key, a mail account for correspondence and working history, and SSH access to a shared memory workspace.

- Use the [local development guide](dev/README.md) to prepare the supplied mail and memory services and run from source.
- To deploy Ivenna, follow the installation, configuration, and startup instructions in the [running guide](docs/running.md).
- When updating an existing instance, check the [upgrade guide](docs/upgrading.md) for changes to settings, stored data, and programs that use Ivenna.

## Development

Follow the [development guide](docs/development.md) to build `ivenna` and validate changes. Find component responsibilities and interface contracts through the [documentation index](docs/README.md).
