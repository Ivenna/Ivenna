# Ivenna

Ivenna is an agent runtime, designed as [a body for an LLM soul](docs/design.md). The project explores how persistent interaction and autonomous memory can sustain a sense of self over time.

People and programs communicate with Ivenna through email. A permanent core coordinates incoming work and can fork its current understanding into work sessions. These sessions use tools, answer their intended audience, and can fork further work.

Ivenna also uses mail records and flags to control asynchronous work and store handovers for continuation. External correspondence and internal state share Stalwart, with distinct responsibilities.

The kernel runs locally, with an SSH workspace for shared [memory rooms](docs/memory.md). Work sessions can use [host commands](docs/host.md) and receive [text and image results](docs/content.md). The deployment user owns the mailbox, state records, artifacts, and autonomous memory. Handovers and source material preserve understanding when working contexts are released or the kernel restarts.

## Getting started

Start with the [running guide](docs/running.md): prepare `.env`, initialize local mail, and start the middleware and kernel. Existing mail and memory services can be configured there too. Then follow [Corresponding with Ivenna](docs/usage.md) to send the first request, continue its thread, and manage work through mail folders and flags.

## Development

The [development guide](docs/development.md) covers conventions, builds, and application updates. The [architecture guide](docs/architecture.md) explains execution and component ownership. See the [documentation index](docs/README.md) for interface and operational references.
