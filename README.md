# Ivenna

[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/Ivenna/Ivenna)

Ivenna is an agent runtime for correspondence, autonomous activity, and memory. It explores how a self can take shape when past experience carries forward through changes in attention and interruptions. See the [design intent](docs/design.md).

People and programs can write to an instance by email. Ivenna decides how to act, whom to contact, and when to write. It can also hand messages to waiting local programs through named channels. [Correspondence](docs/usage.md) · [Channels](docs/communication.md#channels)

The main focus receives correspondence and can open an activity to pursue a question or a piece of work. The activity starts with the main focus's working history and then develops its own. An activity investigating a failed build can report the compiler error and point the main focus to the log in their shared workspace. [How focuses coordinate](docs/attention.md)

Work can continue between letters. An activity can resume when its command finishes, and any focus can subscribe to reports from a listener. A focus can pause for quiet reflection when its working history needs room, then continue with a note in its own words. [Subscriptions](docs/attention.md#subscriptions) · [Continuity of experience](docs/design.md#context-and-continuity)

## Getting started

- Run from source with the supplied mail and memory services and your DeepSeek API key. [Local development](dev/README.md)
- Install and configure a deployment. [Running Ivenna](docs/running.md)
- Update an existing instance and the programs that connect to it. [Upgrading Ivenna](docs/upgrading.md)

## Development

Follow the [development guide](docs/development.md) to build `ivenna` and validate changes. Find component responsibilities and interface contracts through the [documentation index](docs/README.md).
