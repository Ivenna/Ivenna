# Ivenna

Ivenna is an agent runtime, designed as [a body for an LLM soul](docs/design.md). Through ongoing communication and autonomous activity, the project explores how interaction and memory can sustain a sense of self over time.

People and programs communicate with Ivenna through email. Ivenna interprets correspondence in context and decides how to respond. A permanent core coordinates ongoing activity and can fork its current understanding into work sessions. These sessions use tools, answer their intended audience, and can fork further work.

Internal mail records support execution state and continuity. External correspondence and internal state share mail storage, with distinct responsibilities and lifecycles.

The kernel runs locally, with an SSH workspace for shared [memory rooms](docs/memory.md). Work sessions can use [host commands](docs/host.md) and receive [text and image results](docs/content.md). The deployment user owns the mailbox, state records, artifacts, and autonomous memory. Handovers and source material support reconstruction of understanding when working contexts are released or the kernel restarts.

## Getting started

Start with the [running guide](docs/running.md): prepare `.env`, initialize local mail, and start the middleware and kernel. Existing mail and memory services can be configured there too. Then follow [Corresponding with Ivenna](docs/usage.md) to send a message and continue the correspondence.

## Development

The [development guide](docs/development.md) covers conventions, builds, and application updates. The [architecture guide](docs/architecture.md) explains execution and component ownership. See the [documentation index](docs/README.md) for interface and operational references.
