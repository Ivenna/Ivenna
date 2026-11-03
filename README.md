# Ivenna

Ivenna is an agent runtime, designed as [a body for an LLM soul](docs/design.md). The project explores how persistent conversations and autonomous memory can sustain a sense of self over time.

The project is currently a prototype. It accepts input through an HTTP service and saves each session's history in local SQLite so you can continue the conversation later. The deployment user owns the data. Ivenna provides shared [memory rooms](docs/memory.md) and [host shell access](docs/host.md).

## Getting started

Follow the [running guide](docs/running.md) to start the service locally, then use the [usage guide](docs/usage.md) to submit input, retrieve results, and continue sessions.

## Development

The [development guide](docs/development.md) covers building from source and changing data structures. The [architecture guide](docs/architecture.md) explains module responsibilities, session execution, and storage boundaries. See the [documentation index](docs/README.md) for all guides.
