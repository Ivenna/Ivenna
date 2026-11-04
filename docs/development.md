# Development

The [design intent](design.md) guides product and interface decisions; the [architecture guide](architecture.md) explains implementation responsibilities and ownership. Follow the [running guide](running.md) for deployment and configuration.

## Development conventions

The project is exploratory. Data structures, interfaces, and module boundaries are not yet settled; change them directly to match the design. Work from intended behavior down to responsibilities, interfaces, and implementation. Explain choices through the behavior they establish and the reasons for choosing them.

Establish the shape of a change first, then implement it in useful increments. Complex or future areas may remain explicit placeholders; describe what works and what remains undecided. Do not retain compatibility paths for superseded designs or introduce migration frameworks.

During development, do not write tests in advance or introduce test frameworks. Run the application locally; containerize only middleware.

## Implementation boundaries

Keep protocol decoding in the component that owns the external interface, and give execution code typed operations. Mail owns the JMAP subset used by the kernel; Stalwart handles MIME and delivery. [Input](../packages/agent/src/input.zig) renders observations with their source, body, context, and current runtime state.

Treat prompts and tool descriptions as editable interfaces. Put ongoing behavioral instructions in the system prompt, operation behavior in tool descriptions, and task facts and observations in user input. Revise the owning resource, renderer, and documentation together when their contract changes.

[compaction.md](../packages/agent/src/compaction.md) owns the summary instructions. [Compaction](../packages/agent/src/compaction.zig) constructs the YAML task with the actual session and runtime snapshot, enforces the request budget, and validates the output. Provider owns model protocol encoding and decoding, including requests without tools.

Model coexisting fields together and mutually exclusive alternatives as distinct variants in language types and structured data. Keep variant-specific fields tied to their discriminator.

The registry owns contexts, queues, and synchronization; the kernel owns external orchestration and worker task scopes. Copy or transfer values that must outlive a model-round arena. Cancel and join workers before releasing their dependencies.

A mail turn's end and an overall task's completion are separate events. When the turn ends and its queue is empty, archive through the registry's ownership boundary so its branch context or core lease is released together with the active conversation. The permanent core context continues.

## Repository and build

| Location | Responsibility |
| --- | --- |
| [apps/ivenna](../apps/ivenna) | Configuration and application startup |
| [packages/agent](../packages/agent) | Conversation registry, mail, structured input, model execution, host and memory tools |
| [dev/mail](../dev/mail) | Stalwart Compose deployment and native provisioning plan |
| [dev/memory](../dev/memory) | Memory container, SSH entry point, and local startup |

The application and mail integration build with Zig:

```sh
zig build
```

The executable is installed at `zig-out/bin/ivenna`. After loading configuration and preparing middleware, run from the repository root:

```sh
zig build run
```

## Updating the kernel and middleware

The executable embeds [system.md](../packages/agent/src/system.md), [tools.json](../packages/agent/src/tools.json), and [compaction.md](../packages/agent/src/compaction.md). Stop the kernel and run `zig build run` after editing code or these resources. Restart follows the [mail-based continuity contract](architecture.md#startup-and-interruption).

The memory [Containerfile](../dev/memory/Containerfile) installs [memory.nu](../packages/agent/src/memory.nu). After changing the handler, container contents, or SSH entry point, stop the kernel and recreate the memory container:

```sh
dev/memory/start.sh down
dev/memory/start.sh up
zig build run
```

This retains the memory volume and SSH keys. For another workspace, update its handler and entry point as described in [remote memory setup](running.md#using-remote-memory).

In [dev/mail](../dev/mail), `compose.yaml` defines normal Stalwart operation and `setup.yaml` enables the official CLI provisioning flow. Configuration lives in Stalwart's data store; `config.json` holds the store connection. Changes to the local provisioning plan can update server settings and account credentials. Apply them through the setup flow, then return to normal operation, retaining the mail volume. See [local mail setup](running.md#configuring-local-mail).

## Validation

Build the application and exercise the changed behavior through real letters and model/tool work. For execution changes, check tool-result continuation, reply threading, reopening, and release of conversation resources after archival. For model-facing changes, inspect complete serialized requests, including YAML frames, runtime snapshots, tool selection, and budget accounting. Report the checks performed and distinguish reconstructed understanding from exact execution recovery.
