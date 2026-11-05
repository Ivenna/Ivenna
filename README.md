# Ivenna

Ivenna is an agent runtime, designed as [a body for an LLM soul](docs/design.md). The project explores how persistent interaction and autonomous memory can sustain a sense of self over time.

People and programs correspond with Ivenna through email. A permanent core coordinates incoming work and can fork its current understanding into work sessions. These sessions use tools, reply directly, and can fork further work. Related mail follows its responsible session.

The kernel runs locally, with Stalwart for mail and an SSH workspace for shared [memory rooms](docs/memory.md). The model can use [host commands](docs/host.md) and receive [text and image results](docs/content.md). The deployment user owns the mailbox, artifacts, and autonomous memory. Handovers and correspondence preserve continuity when working contexts are released or the kernel restarts.

## Getting started

Start with the [running guide](docs/running.md): prepare `.env`, initialize local mail, and start the middleware and kernel. Existing mail and memory services can be configured there too. Then follow [Corresponding with Ivenna](docs/usage.md) to send the first request, continue its thread, and manage work through mail folders and flags.

## Development

The [development guide](docs/development.md) covers conventions, builds, and application updates. The [architecture guide](docs/architecture.md) explains component ownership and execution. See the [documentation index](docs/README.md) for interface and operational references.
