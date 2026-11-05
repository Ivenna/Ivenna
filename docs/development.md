# Development

The [design intent](design.md) guides product and interface decisions; the [architecture guide](architecture.md) explains implementation responsibilities and ownership. Follow the [running guide](running.md) for deployment and configuration.

## Development conventions

The project is exploratory. Data structures, interfaces, and module boundaries are not yet settled; change them directly to match the design. Work from intended behavior down to responsibilities, interfaces, and implementation. Explain choices through the behavior they establish and the reasons for choosing them.

Establish responsibilities and interfaces first, then implement in useful increments. Complex or future areas may remain explicit placeholders; describe what works and what remains undecided. Keep unresolved behavior unavailable or explicitly limited, rather than inventing it to complete test coverage. Do not retain compatibility paths for superseded designs or introduce migration frameworks.

During development, do not write tests in advance or introduce test frameworks. Run the application locally; containerize only middleware.

## Implementation boundaries

Follow the component boundaries in the [architecture guide](architecture.md#responsibilities). Decode external protocols in their owning components and give execution code typed operations. Work, session scheduling, and model observations must not depend on mail records, headers, folders, or native thread identifiers.

Treat prompts and tool descriptions as editable interfaces. Put ongoing behavioral instructions in [system.md](../packages/agent/src/system.md), operation behavior in [tools.json](../packages/agent/src/tools.json), and task facts and observations in user input. Keep descriptions concise, with detailed field references in the [input contract](input.md). Revise the owning resource, renderer, and documentation together when their contract changes.

[Input](../packages/agent/src/input.zig) owns the closed observation union and its payload types. Construct those variants directly; the renderer serializes them without merging arbitrary fields. Native inputs carry content, optional provenance, and optional context. Do not require communication metadata or source files for work that has none. Original email details are source material to inspect when relevant, not fields in session state. The system prompt describes the shared envelope and variant meanings, while tool definitions explain available operations.

Keep external correspondence, internal work reports, continuity handovers, and diagnostics distinct at their owning interfaces. Delivery code submits the intended answer without adding operational prose. Content handling preserves text, media, and source descriptions together; see [tool content](content.md) for classification and interpretation.

[compaction.md](../packages/agent/src/compaction.md) owns the summary instructions. [Compaction](../packages/agent/src/compaction.zig) constructs the YAML task with the actual session and runtime snapshot, enforces the request budget, and validates the output. Provider owns model protocol encoding and decoding, including requests without tools.

Model coexisting fields together and mutually exclusive alternatives as distinct variants in language types and structured data. Keep variant-specific fields tied to their discriminator.

[Work](../packages/agent/src/work.zig) keeps input, reply targets, and source state independent. Derive routing, response destinations, and persistence from their explicit bindings. Source provenance supplies material for understanding; `SourceState` supplies program bookkeeping. Email projection and submission belong to EmailTransport; input consumption and keyed handovers belong to MailState. Both use the shared mail client and source records described in the [component responsibilities](architecture.md#responsibilities).

Sessions synchronizes contexts, queues, and routes. The kernel coordinates adapter operations and owns worker task scopes. Retain final text and confirmed submission state before later acknowledgment work can fail. Copy or transfer values that must outlive a model-round arena, and cancel and join workers before releasing their dependencies.

Keep activation completion, task completion, context release, source-state lifetime, and mail retention distinct. The sessions registry checks queues, children, and worker ownership before releasing contexts. Shared source-cache cleanup checks the receipts still in use; it does not delete artifacts or change folders. Source artifacts retain their first captured content and are published atomically. Internal handovers use state keys rather than external reply chains. Work without a persistent state key has no cross-restart recovery contract yet. In-process completion state covers confirmed outcomes, not unknown network effects or execution recovery after restart.

## Repository and build

| Location | Responsibility |
| --- | --- |
| [apps/ivenna](../apps/ivenna) | Configuration and application startup |
| [packages/agent](../packages/agent) | Work and session execution, email boundary, internal mail state, native observations, model provider, host and memory tools |
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

The executable embeds [system.md](../packages/agent/src/system.md), [tools.json](../packages/agent/src/tools.json), and [compaction.md](../packages/agent/src/compaction.md). Stop the kernel and run `zig build run` after editing code or these resources. Restart follows the [continuity contract](architecture.md#startup-and-interruption).

The memory [Containerfile](../dev/memory/Containerfile) installs [memory.nu](../packages/agent/src/memory.nu). After changing the handler, container contents, or SSH entry point, stop the kernel and recreate the memory container:

```sh
dev/memory/start.sh down
dev/memory/start.sh up
zig build run
```

This retains the memory volume and SSH keys. For another workspace, update its handler and entry point as described in [remote memory setup](running.md#using-remote-memory).

In [dev/mail](../dev/mail), `compose.yaml` defines normal Stalwart operation and `setup.yaml` enables the official CLI provisioning flow. Configuration lives in Stalwart's data store; `config.json` holds the store connection. Changes to the local provisioning plan can update server settings and account credentials. Apply them through the setup flow, then return to normal operation, retaining the mail volume. See [local mail setup](running.md#configuring-local-mail).

## Validation

Build the application and exercise the changed behavior through communication and model/tool work. For execution changes, check tool-result continuation, handoff and requested findings, follow-up routing, reopening, and working-context release. For email changes, check reply threading and material projection. For state changes, check private consumption and outbound markers, keyed handovers, receipt cleanup, and any affected retention behavior. Confirm that reading, starring, and archiving ordinary correspondence leave its processing unchanged. For model-facing changes, inspect complete serialized requests, including YAML observations, response variants, tool selection, and budget accounting. Report the checks performed and distinguish reconstructed understanding from exact execution recovery.
