# Documentation

## Using Ivenna

| Task | Guide |
| --- | --- |
| Write to Ivenna by email, share material to read, or follow up | [Corresponding with Ivenna](usage.md) |
| Send to a correspondent, focus, or channel | [Sending a message](communication.md#sending-a-message) |
| Open or close a channel | [Channels](communication.md#channels) |
| Open an activity and follow its work | [Attention](attention.md) |
| Register or withdraw a subscription | [Subscriptions](attention.md#subscriptions) |
| Record, find, or revise something in shared memory | [Memory rooms](memory.md) |
| Read a local file, retrieve a web page, or open an image | [Reading resources](resources.md) |
| Run a command, read its output, or interact with a running process | [Host shell](host.md) |

## Connecting local programs

| Task | Guide |
| --- | --- |
| Connect a receiver and read channel messages | [Channel receiver interface](communication.md#receiving-from-a-channel) |
| Send reports to a subscribed focus | [Subscription listener protocol](subscriptions.md) |

## Running an instance

| Task | Guide |
| --- | --- |
| Install the kernel from a package | [Installing the executable](running.md#installing-the-executable) |
| Run Ivenna from source with the supplied mail and memory services | [Local development](../dev/README.md) |
| Configure a deployment, diagnose stalled work, and manage retained data | [Running guide](running.md) |
| Set mail request limits or recover from a history size error | [Working history limits](running.md#working-history-limits) |
| Set reasoning effort or tune when a focus summarizes its history | [Model requests](running.md#model-requests) · [Context budgets](running.md#context-budgets) |
| Update settings, stored data, or client programs when upgrading an instance | [Upgrade guide](upgrading.md) |
| Configure a host or container for a channel receiver | [Channel receiver deployment](running.md#channel-receivers) |
| Run a subscription listener independently of the kernel | [Subscription listener deployment](running.md#subscription-listeners) |

## Design and development

| Task | Guide |
| --- | --- |
| Understand the project's goals and interface principles | [Design intent](design.md) |
| Review what a focus sees in prompts, observations, tool results, and handovers | [Context and continuity](design.md#context-and-continuity) · [Model-facing resources](development.md#model-facing-resources) |
| Interpret observations, retained records, and handovers | [Input contract](input.md) |
| Understand what the model receives when a tool returns text, an image, or a file | [Tool content](content.md) |
| Understand component ownership and how execution fits together | [Architecture guide](architecture.md) |
| Change implementation and documentation, build from source, and validate work | [Development guide](development.md) |
| Run automated checks and validate behavior with running services | [Testing guide](testing.md) |
| Publish a tagged release, build a snapshot, or package source locally | [Releasing Ivenna](releasing.md) |
