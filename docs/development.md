# Development

The [design intent](design.md) guides product and interface decisions; the [architecture guide](architecture.md) explains implementation responsibilities and ownership. Follow the [running guide](running.md) for deployment and configuration.

## Development conventions

The project is exploratory. Data structures, interfaces, and module boundaries are not yet settled; change them directly to match the design. Start from Ivenna's overall behavior, establish responsibilities and interfaces, then implement in useful increments. Explain choices through the behavior they establish and the reasons for choosing them.

Leave behavior that needs further design as an unavailable or explicitly limited placeholder. Describe what works and what remains undecided. When a design changes, remove superseded behavior and state; do not retain compatibility paths or introduce migration frameworks.

Communication and memory are operating requirements of the whole runtime. Component boundaries organize responsibilities within that contract. Keep safeguards at the boundary that owns the requirement, use the guarantees established there, and remove duplicated checks in downstream components.

During development, do not write tests in advance or introduce test frameworks. Run the application locally; containerize only middleware.

## Implementation boundaries

### Packages and dependencies

Organize packages around cohesive capabilities, keeping their types, rules, resources, and implementation together. Public interfaces should let callers use a capability without coordinating its internal components. Keep supporting mechanisms with their owning capability. Applications own program startup, configuration, and deployment.

Follow the [architecture guide's responsibilities and dependency graph](architecture.md#responsibilities). Keep execution policy and its contracts in `packages/agent`. Concrete capabilities implement `Inbox`, `Communication.Sender`, `HandoverStore`, `Model.Port`, and `Tools`; `apps/ivenna` selects and assembles them. Capability packages depend on agent contracts, and the agent uses those contracts without importing their implementations.

### Types and protocols

Decode external protocols in their owning components and give execution code typed operations. Work, session scheduling, and model observations must not depend on mail records, headers, folders, or native thread identifiers.

Model coexisting fields together and mutually exclusive alternatives as distinct variants in language types and structured data. Keep variant-specific fields tied to their discriminator.

[Input](../packages/agent/src/input.zig) owns model-input types and YAML rendering. Construct typed payloads at their owning boundaries and use the renderer for model messages. [Work](../packages/agent/src/work.zig) owns delivery events and private consumption receipts. [Communication](../packages/agent/src/communication.zig) defines recipient references and outgoing messages; the adapter resolves references to native destinations. The [input contract](input.md) documents serialized fields.

[Content](../packages/content/src/root.zig) owns tool-result text and image types, byte-source classification, and explicit image reference interpretation. Input material's text and excerpt variants belong to Input; tool results use Content's parts.

[Model](../packages/agent/src/model.zig) defines native history items and model operations. Keep messages and tool results typed. Preserve model output as opaque continuation bytes owned by the producing adapter's format; execution copies and retains them without reading protocol fields. The model adapter measures requests with the same encoder it uses to send them, including declarations and content.

### Model-facing resources

Treat prompts and tool descriptions as editable interfaces:

| Resource | Purpose |
| --- | --- |
| [system.md](../packages/agent/src/system.md) | Input interpretation and response scope needed by the model |
| [Agent tools](../packages/agent/src/tools.json) | Communication and session-fork actions |
| [Host tools](../packages/host/src/tools.json) | Host shell actions, invocation parameters, and results |
| [Memory tools](../packages/memory/src/tools.json) | Memory actions, invocation parameters, and results |
| [compaction.md](../packages/agent/src/compaction.md) | What a handover must preserve |

Each capability owns its tool names, descriptions, and parameter schemas alongside its implementation. Host and Memory register those declarations through `Tools`. Engine combines the registered capabilities with the agent's communication and session declarations for work sessions; core coordination exposes only the agent's declarations, and summarization exposes none. Model adapters add protocol-specific declaration fields when encoding the selected tools.

Put task facts and observations in user input. Keep model-facing descriptions concise; detailed field references belong in the [input contract](input.md). Update the owning resource, implementation, and interface documentation together when a contract changes.

Include runtime rules in these resources when they affect a model decision or the meaning of input, actions, or results. Explain how scheduling and storage are implemented, and how to operate the system, in the architecture and running guides.

Keep outgoing messages, internal reports, handovers, and diagnostics distinct. Outgoing communication occurs through `send_message`. For ordinary work, final model text completes the activation and supplies a core result or parent report; summary text supplies a handover for continued execution. Preserve text, media, and source descriptions together when handling [tool content](content.md).

### Execution and storage

The session registry synchronizes contexts, queues, and activation ownership. The kernel coordinates adapter operations and worker task scopes. Context retains records and complete model/tool exchanges, assembling temporary requests without changing that history. Keep current state and summary instructions in the request.

Infrastructure and execution failures propagate to the application's task scope, which closes reception, cancels, and joins all work before shared dependencies are released. Copy or transfer values that must outlive a model-round arena. Ordinary tool outcomes remain model observations.

The application serves health and reception status. The mail server's receiving boundary uses that status before accepting external SMTP traffic. Keep this gate separate from model reasoning and in-process work queues; its readiness check does not reserve an activation or establish an atomic delivery transaction.

Keep context release and stored-record retention independent. Follow the architecture contracts for [source publication](architecture.md#email-boundary-and-source-materials), [internal state](architecture.md#internal-mail-state), and [context lifetime](architecture.md#activation-completion-and-context-release).

## Repository and build

| Location | Responsibility |
| --- | --- |
| [apps/ivenna](../apps/ivenna) | Configuration, adapter assembly, HTTP status, application startup and shutdown |
| [apps/memory](../apps/memory) | Remote memory handler, image, and SSH entry point |
| [packages](../packages) | Runtime libraries and their resources; see the [architecture map](architecture.md#responsibilities) for each package's interface and responsibility |
| [dev/compose.yaml](../dev/compose.yaml) | Local mail and memory service builds, containers, and volumes |
| [dev/mail](../dev/mail) | Stalwart configuration and native provisioning plan |
| [dev/memory](../dev/memory) | Local SSH key and connection preparation |

Each Zig library declares its module and dependencies in `build.zig` and `build.zig.zon`, with public exports in `src/root.zig`. When adding or moving a unit, update its consuming build declarations, the [root package's exported source paths](../build.zig.zon), and the architecture map. `apps/ivenna` links the libraries into one executable. The memory app is a separately deployed Nushell program built from its Containerfile.

Build the application from the repository root:

```sh
zig build
```

The executable is installed at `zig-out/bin/ivenna`. After loading configuration and preparing middleware, run from the repository root:

```sh
zig build run
```

## Updating the kernel and middleware

The executable embeds the [model-facing resources](#model-facing-resources) from their owning packages. Stop the kernel and run `zig build run` after editing code or these resources. Restart follows the [continuity contract](architecture.md#startup-and-interruption).

The memory [Containerfile](../apps/memory/Containerfile) installs [memory.nu](../apps/memory/src/memory.nu). After changing the handler, container contents, or SSH entry point, stop the kernel, rebuild the image, and recreate the memory service. These commands use the example engine from the [running guide](running.md#prerequisites-and-configuration):

```sh
podman compose -f dev/compose.yaml build --pull --no-cache memory
podman compose -f dev/compose.yaml up -d --wait memory
zig build run
```

This retains the external memory volume and SSH keys. The build context includes only the memory image sources selected by [`.dockerignore`](../.dockerignore). For another workspace, update its handler and entry point as described in [remote memory setup](running.md#using-remote-memory).

Stalwart's account and policy configuration lives in its data store; [config.json](../dev/mail/config.json) selects that store. Apply provisioning-plan changes through [local mail setup](running.md#configuring-local-mail), then return to normal operation. Container recreation retains the stored configuration and mail.

## Validation

Build the application and exercise the affected behavior through communication and model/tool work:

| Area changed | Checks |
| --- | --- |
| Execution | Joint processing of queued events, budget-limited FIFO admission, tool-result continuation, whole-group handoff and receipt consumption, direct-parent reports, and context release |
| Failure handling | Required-capability failures stop the runtime and join concurrent work; ordinary tool outcomes allow continuation |
| Communication | Explicit zero, one, or multiple sends; recipient reference lifetime; final text without implicit sending |
| Email | Standalone submissions, material projection, and independent intake regardless of thread, read, starred, or archived state |
| Service | Health and reception status during startup, operation, and shutdown; SMTP rejection when reception is closed |
| Internal state | Private consumption and outbound markers, core handovers, receipt cleanup, and affected retention behavior |
| Model-facing interfaces | Record and request serialization, response variants, tool selection, and complete-payload budget accounting |

Report the checks performed. Distinguish reconstruction of understanding from execution recovery.
