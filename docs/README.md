# Documentation

## Operation and correspondence

| Task | Guide |
| --- | --- |
| Write to a running Ivenna, share material to read, or follow up | [Corresponding with Ivenna](usage.md) |
| Prepare, run, and update the supplied local development environment | [Local development](../dev/README.md) |
| Run Ivenna, diagnose stalled work, and manage services and retained data | [Running guide](running.md) |
| Run a local feed reader or subscription listener | [Local programs](running.md#local-programs) |

## Design and development

| Task | Guide |
| --- | --- |
| Understand the project's goals and interface principles | [Design intent](design.md) |
| Understand component ownership and how execution fits together | [Architecture guide](architecture.md) |
| Change implementation and documentation, build from source, and validate work | [Development guide](development.md) |
| Run automated checks and validate behavior with running services | [Testing guide](testing.md) |

## Interface reference

| Task | Guide |
| --- | --- |
| Interpret history records, inference turns, and runtime state | [Input contract](input.md) |
| Send to a channel or manage a feed | [Communication](communication.md) |
| Read feed messages by address and resume from a saved position | [Reading feeds](communication.md#reading-feeds) |
| Coordinate focuses, schedule wakeups, and manage subscriptions | [Attention](attention.md) |
| Write a listener that reports observations and resumes from a saved cursor | [Subscription listener protocol](subscriptions.md) |
| Use shared autonomous memory | [Memory rooms](memory.md) |
| Open a local file, continue reading a web page, or view an image by URL | [Reading resources](resources.md) |
| Run a command, read its output, or interact with a running process | [Host shell](host.md) |
| Understand what the model receives when a tool returns text, an image, or a file | [Tool content](content.md) |
