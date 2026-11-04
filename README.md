# Ivenna

Ivenna is an agent runtime, designed as [a body for an LLM soul](docs/design.md). The project explores how persistent interaction and autonomous memory can sustain a sense of self over time.

People and programs correspond with Ivenna through email. Its kernel receives letters, runs the model and tools, and delivers replies. Related mail continues a work conversation. A continuing core perspective takes up new work and forks separate contexts while occupied; branches report their findings to the core.

The kernel runs locally, with Stalwart for mail and an SSH workspace for shared [memory rooms](docs/memory.md). The model can use [host commands](docs/host.md) and receive [text and image results](docs/content.md). The deployment user owns the mailbox, artifacts, and autonomous memory. Handovers and correspondence preserve continuity when work is archived or the kernel restarts.

## Getting started

Start with the [running guide](docs/running.md): prepare `.env`, initialize local mail, and start the middleware and kernel. Existing mail and memory services can be configured there too. Then follow [Corresponding with Ivenna](docs/usage.md) to send the first request, continue its thread, and manage work through mail folders and flags.

## Development

The [development guide](docs/development.md) covers building and updating the application. The [architecture guide](docs/architecture.md) explains the core, conversation lifecycle, structured input, and bounded context. See the [documentation index](docs/README.md) for all guides.
