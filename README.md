# Ivenna

Ivenna is an agent runtime, designed as [a body for an LLM soul](docs/design.md). Through ongoing communication and autonomous activity, the project explores how interaction and memory can sustain a sense of self over time.

People and programs communicate with Ivenna through email. It interprets each message alongside ongoing activity and coordinates work through a core session and other focuses of attention. Ivenna chooses when to communicate and whom to address through an [explicit sending tool](docs/communication.md); one incoming message can lead to zero, one, or several outgoing messages.

Ivenna runs as a local service, combining email, [host commands](docs/host.md), and shared [memory rooms](docs/memory.md) accessed over SSH. Communication and memory must be available for it to run. It exposes [health and reception readiness](docs/running.md#service-status-and-reception), and tools can return [text and images](docs/content.md).

The deployment user owns the mailbox, autonomous memory, and [local data](docs/running.md#local-data). Retained material supports continued understanding when working contexts are released or the kernel restarts.

## Getting started

Start with the [running guide](docs/running.md) to configure model access, mail, and memory, then start Ivenna and check reception readiness. It covers both the supplied local services and connections to existing services. Follow [Corresponding with Ivenna](docs/usage.md) to send a message and continue the correspondence.

## Development

The monorepo contains the Ivenna application, the remote memory service, and their runtime libraries. The [development guide](docs/development.md) covers conventions, builds, and application updates; the [architecture guide](docs/architecture.md) explains package boundaries, dependencies, and execution ownership. See the [documentation index](docs/README.md) for interface and operational references.
