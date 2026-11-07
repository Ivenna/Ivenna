# Ivenna

Ivenna is an agent runtime, designed as [a body for an LLM soul](docs/design.md). Through ongoing communication and autonomous activity, the project explores how interaction and memory can sustain a sense of self over time.

A core session coordinates Ivenna's attention and correspondence. It can fork activity sessions that inherit its retained understanding and pursue their own assignments. These focuses share files, autonomous memory, communication, and host processes while developing their own subsequent histories.

People and programs communicate with Ivenna through messages. The model observes who said what, chooses how to act, and decides when to communicate and whom to address through an [explicit sending tool](docs/communication.md). Its sessions can pursue work and wait for tools independently, and scheduled wakeups let it reconsider work without new correspondence. Saved understanding and memory support continuation across restart.

The current implementation uses email for correspondence and working history, shared [memory rooms](docs/memory.md) over SSH, and [host commands](docs/host.md) for activities. Communication and memory must be available for it to run. The deployment user owns the records, memory, and artifacts; the [running guide](docs/running.md) describes service requirements and retained data.

## Getting started

Choose a setup path:

- Use the [local development guide](dev/README.md) to prepare the supplied mail and memory services and run from source.
- Use the [running guide](docs/running.md) to configure another deployment, start the executable, and manage retained data.

Once Ivenna is ready to receive mail, follow [Corresponding with Ivenna](docs/usage.md) to send a message and continue the correspondence.

## Development

The monorepo contains the Ivenna application, the remote memory service, and runtime libraries for execution, shared contracts, and concrete capabilities. The [development guide](docs/development.md) covers conventions, builds, and validation; the [architecture guide](docs/architecture.md) explains package boundaries, dependencies, and execution ownership. See the [documentation index](docs/README.md) for interface and operational references.
