# Documentation

## Using Ivenna

| Task | Guide |
| --- | --- |
| Write to Ivenna by email, share material to read, or follow up | [Corresponding with Ivenna](usage.md) |
| Send to a correspondent or another focus | [Sending a message](communication.md#sending-a-message) |
| Open a channel, send to it, or write a receiver | [Channels](communication.md#channels) |
| Coordinate focuses, schedule wakeups, and manage subscriptions | [Attention](attention.md) |
| Write a listener that reports observations and resumes from a saved cursor | [Subscription listener protocol](subscriptions.md) |
| Record, find, or revise something in shared memory | [Memory rooms](memory.md) |
| Read a local file, retrieve a web page, or open an image | [Reading resources](resources.md) |
| Run a command, read its output, or interact with a running process | [Host shell](host.md) |

## Running an instance

| Task | Guide |
| --- | --- |
| Run Ivenna from source with the supplied mail and memory services | [Local development](../dev/README.md) |
| Configure a deployment, diagnose stalled work, and manage retained data | [Running guide](running.md) |
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
