# Ivenna

Ivenna is an agent runtime, designed as [a body for an LLM soul](docs/design.md). Through ongoing communication and autonomous activity, the project explores how interaction and memory can sustain a sense of self over time.

People and programs communicate with Ivenna through email. It interprets each message alongside ongoing activity and coordinates work through a core session and other focuses of attention. Ivenna chooses when to communicate and whom to address through an [explicit sending tool](docs/communication.md); one incoming message can lead to zero, one, or several outgoing messages.

Ivenna combines email, [host commands](docs/host.md), and shared [memory rooms](docs/memory.md) accessed over SSH. Communication and memory must be available for it to run. It exposes [health and reception readiness](docs/running.md#service-status-and-reception), and tools can return [text and images](docs/content.md).

The deployment user owns the mailbox, autonomous memory, and [runtime data](docs/running.md#data-and-retention). Retained material supports continued understanding when working contexts are released or the kernel restarts.

## Getting started

Use the [running guide](docs/running.md) to configure services, start the kernel, and manage retained data. For development with the supplied mail and memory services, follow the [local development guide](dev/README.md).

Once Ivenna is ready to receive mail, follow [Corresponding with Ivenna](docs/usage.md) to send a message and continue the correspondence.

## Development

The monorepo contains the Ivenna application, the remote memory service, and runtime libraries for execution, shared contracts, and concrete capabilities. The [development guide](docs/development.md) covers conventions, builds, and validation; the [architecture guide](docs/architecture.md) explains package boundaries, dependencies, and execution ownership. See the [documentation index](docs/README.md) for interface and operational references.
