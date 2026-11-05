# Development

The [design intent](design.md) guides product and interface decisions; the [architecture guide](architecture.md) explains implementation responsibilities and ownership. Follow the [running guide](running.md) for deployment and configuration.

## Development conventions

The project is exploratory. Data structures, interfaces, and module boundaries are not yet settled; change them directly to match the design. Start from Ivenna's overall behavior, establish responsibilities and interfaces, then implement in useful increments. Explain choices through the behavior they establish and the reasons for choosing them.

Leave behavior that needs further design as an unavailable or explicitly limited placeholder. Describe what works and what remains undecided. When a design changes, remove superseded behavior and state; do not retain compatibility paths or introduce migration frameworks.

Communication and memory are operating requirements of the whole runtime. Component boundaries organize responsibilities within that contract. Keep safeguards at the boundary that owns the requirement, use the guarantees established there, and remove duplicated checks in downstream components.

During development, do not write tests in advance or introduce test frameworks. Run the application locally; containerize only middleware.

## Implementation boundaries

### Types and protocols

Follow the component boundaries in the [architecture guide](architecture.md#responsibilities). Decode external protocols in their owning components and give execution code typed operations. Work, session scheduling, and model observations must not depend on mail records, headers, folders, or native thread identifiers.

Model coexisting fields together and mutually exclusive alternatives as distinct variants in language types and structured data. Keep variant-specific fields tied to their discriminator.

[Input](../packages/agent/src/input.zig) defines the closed observation union and its payload types. Construct those variants directly and render their declared fields. Native input can have content alone or include provenance and context. Keep reply targets and source bookkeeping in [Work](../packages/agent/src/work.zig), independently of that provenance; derive routing, response destinations, and persistence from the explicit work bindings.

### Model-facing resources

Treat prompts and tool descriptions as editable interfaces:

| Resource | Purpose |
| --- | --- |
| [system.md](../packages/agent/src/system.md) | Ongoing instructions, observation meanings, and response scope |
| [tools.json](../packages/agent/src/tools.json) | Operation parameters, behavior, and results |
| [compaction.md](../packages/agent/src/compaction.md) | Handover summary instructions |

Put task facts and observations in user input. Keep model-facing descriptions concise; detailed field references belong in the [input contract](input.md). Update the owning resource, renderer, and documentation together when a contract changes.

Keep external replies, internal findings, handovers, and diagnostics distinct. Submit reply text as the intended answer. Preserve text, media, and source descriptions together when handling [tool content](content.md).

### Execution and storage

Sessions synchronizes contexts, queues, and routes. The kernel coordinates adapter operations and owns worker task scopes. Infrastructure and execution failures propagate to the kernel's task scope, which cancels and joins all work before shared dependencies are released. Copy or transfer values that must outlive a model-round arena. Ordinary tool outcomes remain model observations.

Keep context release and stored-record retention independent. Follow the architecture contracts for [source publication](architecture.md#email-boundary-and-source-materials), [internal state](architecture.md#internal-mail-state), and [context lifetime](architecture.md#turn-completion-and-context-release).

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

Build the application and exercise the affected behavior through communication and model/tool work:

| Area changed | Checks |
| --- | --- |
| Execution | Tool-result continuation, handoff, requested findings, follow-up routing, reopening, and context release |
| Failure handling | Required-capability failures stop the runtime and join concurrent work; ordinary tool outcomes allow continuation |
| Email | Reply recipients and threading, material projection, and intake independent of read, starred, or archived state |
| Internal state | Private consumption and outbound markers, keyed handovers, receipt cleanup, and affected retention behavior |
| Model-facing interfaces | Complete serialized requests, YAML observations, response variants, tool selection, and budget accounting |

Report the checks performed. Distinguish reconstruction of understanding from execution recovery.
