# Ivenna

Ivenna is an agent runtime, designed as [a body for an LLM soul](docs/design.md). Through ongoing communication and autonomous activity, the project explores how interaction and memory can sustain a sense of self over time.

People and programs communicate with Ivenna through email. A permanent core interprets correspondence and coordinates ongoing activity, forking its current understanding into work sessions when needed. Work sessions use tools, answer their intended audience, and can fork further work.

The kernel runs locally, combining email, [host commands](docs/host.md), and shared [memory rooms](docs/memory.md) accessed over SSH. Communication and memory must be available for it to run. Tools can return [text and images](docs/content.md).

The deployment user owns the mailbox, state records, artifacts, and autonomous memory. Handovers and source material provide context for continuing work after a working context is released or the kernel restarts.

## Getting started

Start with the [running guide](docs/running.md): prepare `.env`, initialize local mail, and start the middleware and kernel. Existing mail and memory services can be configured there too. Then follow [Corresponding with Ivenna](docs/usage.md) to send a message and continue the correspondence.

## Development

The [development guide](docs/development.md) covers conventions, builds, and application updates. The [architecture guide](docs/architecture.md) explains execution and component ownership. See the [documentation index](docs/README.md) for interface and operational references.
