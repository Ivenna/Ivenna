# Documentation

## Operation and correspondence

| Task | Guide |
| --- | --- |
| Write to Ivenna by email, share material to read, or follow up | [Corresponding with Ivenna](usage.md) |
| Run Ivenna, diagnose stalled work, and manage services and retained data | [Running guide](running.md) |
| Run a subscription listener independently of the kernel | [Subscription listener deployment](running.md#subscription-listeners) |

## Design and development

| Task | Guide |
| --- | --- |
| Understand the project's goals and interface principles | [Design intent](design.md) |
| Decide what context to disclose and what to carry forward | [Context and continuity](design.md#context-and-continuity) |
| Understand component ownership and how execution fits together | [Architecture guide](architecture.md) |
| Change implementation and documentation, build from source, and validate work | [Development guide](development.md) |
| Prepare, run, and update the supplied local services | [Local development](../dev/README.md) |
| Run automated checks and validate behavior with running services | [Testing guide](testing.md) |

## Interface reference

| Task | Guide |
| --- | --- |
| Interpret startup and other observations, retained history, and handovers | [Input contract](input.md) |
| Send a message to a correspondent, focus, or channel | [Sending a message](communication.md#sending-a-message) |
| Open or close a channel | [Opening](communication.md#opening-a-channel) · [Closing](communication.md#closing-a-channel) |
| Read channel messages in a local program | [Receiving from a channel](communication.md#receiving-from-a-channel) |
| Coordinate focuses, schedule wakeups, and manage subscriptions | [Attention](attention.md) |
| Write a listener that reports observations and resumes from a saved cursor | [Subscription listener protocol](subscriptions.md) |
| Use shared autonomous memory | [Memory rooms](memory.md) |
| Open a local file, continue reading a web page, or view an image by URL | [Reading resources](resources.md) |
| Run a command, read its output, or interact with a running process | [Host shell](host.md) |
| Understand what the model receives when a tool returns text, an image, or a file | [Tool content](content.md) |
