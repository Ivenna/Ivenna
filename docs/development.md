# Development

The [design intent](design.md) guides product and interface decisions; the [architecture guide](architecture.md) explains implementation responsibilities and ownership. Follow the [running guide](running.md) for deployment and configuration.

## Development conventions

The project is exploratory. Data structures, interfaces, and module boundaries are not yet settled; change them directly to match the design.

Leave behavior that needs further design as an unavailable or explicitly limited placeholder. Describe what works and what remains undecided. When a design changes, remove superseded behavior and state; do not retain compatibility paths or introduce migration frameworks.

Communication and memory are operating requirements of the whole runtime. Component boundaries organize responsibilities within that contract. Keep safeguards at the boundary that owns the requirement, use the guarantees established there, and remove duplicated checks in downstream components.

During development, do not write tests in advance or introduce test frameworks. Use the [local development environment](../dev/README.md) to run the kernel on the host and middleware in containers.

## Design and implementation

Start with the intended behavior and its reason, then establish responsibilities and interfaces. Explain design changes through their effects on Ivenna, its correspondents, or the deployment user. Implementation experience can inform these choices; a current code path or service limitation alone does not establish a design requirement.

Keep each document focused on its role:

| Document | Scope |
| --- | --- |
| Design guide | Goals, behavioral choices, interface principles, and their reasons |
| Development guide | Change conventions, implementation boundaries, builds, and validation |
| Interface guides | Operations, fields, formats, and outcomes |
| Model-facing resources | Semantics needed to choose actions and interpret observations |
| Architecture guide | The current implementation's package ownership, dependencies, algorithms, synchronization, storage representation, and service protocols |
| Running and local development guides | Deployment configuration and service procedures |

Keep project guidance focused on Ivenna's interfaces, integration choices, and their operational effects. Refer readers to component documentation for general use and administration, keeping Ivenna-specific settings and procedures here.

Design can name an operation or concept when it expresses a behavioral choice, such as explicit sending or work ownership. When behavior changes, update the affected design, interface contracts, model-facing resources, and implementation together. When replacing a mechanism while preserving behavior, update its implementation and architecture description. Describe any remaining implementation limitation and its effect in the relevant interface or operational guide.

## Implementation boundaries

### Packages and dependencies

Organize packages around cohesive capabilities, keeping their types, rules, resources, and implementation together. Public interfaces should let callers use a capability without coordinating its internal components. Keep supporting mechanisms with their owning capability. Applications select implementations, load deployment settings, and own program startup and shutdown.

Follow the [architecture guide's responsibilities and dependency graph](architecture.md#responsibilities). Shared communication and model types and the `Inbox`, `Communication.Sender`, `HistoryStore`, `Model.Port`, and `Tools` contracts belong to `packages/agent_contracts`. The execution core and capability implementations depend on that package; `apps/ivenna` selects and assembles the implementations. Update producers and consumers together when changing a shared type or operation.

Keep execution policy, model-input rendering, prompts, and runtime tool declarations in `packages/agent`. The agent exposes `Kernel`, `Engine`, and its own `Input` schemas and renderer.

Keep configuration with the behavior it controls. `Kernel.Config` and `Kernel.Limits` belong to execution; `Engine.Reasoning` selects ordinary inference effort by session role. Connection settings and protocol encoding belong to their capability packages. The application translates environment values into those configurations and owns HTTP listener settings.

### Types and protocols

Decode external protocols in their owning components and give execution code typed operations. Callers rely on the guarantees established by language types and supplying components within their documented scope and lifecycle. Validate additional requirements at the boundary that owns them.

Work, session scheduling, and model observations must not depend on mail records, headers, folders, or native thread identifiers.

Model coexisting fields together and mutually exclusive alternatives as distinct variants in language types and structured data. Keep variant-specific fields tied to their discriminator.

[Communication](../packages/agent_contracts/src/communication.zig) defines incoming observations with `from` IDs and outgoing messages addressed by recipient ID. [Inbox](../packages/agent_contracts/src/inbox.zig) owns the incoming-message and receipt envelope and acknowledges durable admission. Construct these typed values at their producing boundary. The email adapter owns the internal domain and conversion between IDs and native addresses.

[Input](../packages/agent/src/input.zig) owns event groups, startup observations, assignments, reports, handovers, execution state, and YAML rendering. Its records incorporate shared incoming messages; temporary requests add current state and instructions. [Work](../packages/agent/src/work.zig) owns delivery and activation lifetimes inside the core. The [input contract](input.md) documents the serialized fields.

[Content](../packages/content/src/root.zig) owns tool-result text and image types, byte-source classification, and explicit image reference interpretation. Observations carry complete text strings; tool results use Content's parts. Content is the sole package dependency of `agent_contracts`.

[Model](../packages/agent_contracts/src/model.zig) defines native history items and model operations. Keep messages and tool results typed. Preserve model output as opaque continuation bytes owned by the producing adapter's format; execution copies and retains them without reading protocol fields.

Keep input rendering separate from provider encoding: Input renders the temporary current-state message; the agent selects tools and reasoning effort for each model request. The model adapter encodes and measures the complete request with those settings, including while applying tool-result limits. Use the same encoder for measurement and inference, and pass settings per request without mutating a shared provider.

### Model-facing resources

Treat prompts and tool descriptions as editable interfaces:

| Resource | Purpose |
| --- | --- |
| [system.md](../packages/agent/src/system.md) | Input interpretation and response scope needed by the model |
| [Agent tools](../packages/agent/src/tools.json) | Communication and session-fork actions |
| [Host tools](../packages/host/src/tools.json) | Host shell actions, invocation parameters, and results |
| [Memory tools](../packages/memory/src/tools.json) | Memory actions, invocation parameters, and results |
| [compaction.md](../packages/agent/src/compaction.md) | What a handover must preserve |

Keep tool names, descriptions, and parameter schemas with their owning implementation. Capability providers register their declarations through `Tools`. Keep tool availability policy in the agent and use the same role selection for declarations and invocation. Model adapters add protocol-specific declaration fields when encoding the selected tools. The [architecture guide](architecture.md#model-requests-and-tools) describes the current assembly and selection.

Put task facts and observations in user input. Keep model-facing descriptions concise; detailed field references belong in the [input contract](input.md). Update the owning resource, implementation, and interface documentation together when a contract changes.

Include runtime rules in these resources when they affect a model decision or the meaning of input, actions, or results. Explain how scheduling and storage are implemented, and how to operate the system, in the architecture and running guides.

Keep outgoing messages, internal reports, handovers, and diagnostics distinct. Outgoing communication occurs through `send_message`. For ordinary work, final model text completes the activation and supplies a core result or parent report; summary text supplies a handover for continued execution. Preserve text, media, and source descriptions together when handling [tool content](content.md).

### Execution and storage

Keep context, queue, and activation changes under the session registry's synchronization; the kernel coordinates adapter operations and worker task scopes. Retain typed event groups, complete model/tool exchanges, and handovers in Context. Derive model input from those entries and append a fresh temporary request for each inference. Keep current state and summary instructions in that request. The [architecture guide](architecture.md#records-context-and-current-requests) describes history ownership and request assembly.

Persist the core and every still-retained work context, preserving complete model/tool exchanges and unread internal assignments and reports. Confirm the selected incoming observations and their checkpoint before acknowledging their receipts; acknowledgement releases transport copies independently of task completion. Restore saved understanding and session relationships with fresh startup activations and the current system prompt. Execution ownership, external deliveries, receipts, and process handles belong to the running process. Loading history must not execute historical tool calls. Storage failures end the runtime through the normal execution failure path.

Keep history encoding, segment identity, committed paths, and retention selection with the agent. Use `HistoryStore` for grouped records, checkpoint publication, and maintenance against that selection. Adapters own native identifiers, placement, protocol limits, and result correlation; storage services own expiry and space reclamation under deployment policy. Keep communication-copy retirement, working-history retention, and host-artifact lifecycles with their owning components.

Confirm records before checkpoint publication. Serialize writes and maintenance through the session registry, and reconcile storage against a confirmed checkpoint before retiring records. Complete native inventory and selection checks before moving objects. The architecture guide defines [history representation and save boundaries](architecture.md#persistent-working-history), [retention selection](architecture.md#history-retention), and the [email storage lifecycle](architecture.md#mail-retention).

Infrastructure and execution failures propagate to the application's task scope, which closes reception, cancels, and joins all work before shared dependencies are released. Copy or transfer values that must outlive a model-round arena. Ordinary tool outcomes remain model observations.

The application serves health and reception status. The mail server's receiving boundary uses that status before accepting incoming SMTP correspondence. Keep this gate separate from model reasoning and in-process work queues; its readiness check does not reserve an activation or establish an atomic delivery transaction.

Follow the architecture contracts for [message projection and addressing](architecture.md#email-boundary), [mail intake and acknowledgement](architecture.md#mail-intake-and-acknowledgement), and [context lifetime](architecture.md#activation-completion-and-context-release).

## Repository and build

| Location | Responsibility |
| --- | --- |
| [apps/ivenna](../apps/ivenna) | Configuration, adapter assembly, HTTP status, application startup and shutdown |
| [apps/memory](../apps/memory) | Remote memory handler, image, and SSH entry point |
| [packages](../packages) | Runtime libraries and their resources; see the [architecture map](architecture.md#responsibilities) for each package's interface and responsibility |
| [dev](../dev/README.md) | Local service orchestration, mail provisioning, and memory SSH preparation |

Each Zig library declares its module and dependencies in `build.zig` and `build.zig.zon`, with public exports in `src/root.zig`. When adding or moving a unit, update its consuming build declarations, the [root package's exported source paths](../build.zig.zon), and the architecture map. `apps/ivenna` links the libraries into one executable. The memory app is a separate Nushell program; its Containerfile packages it for container use.

Install the Zig version in [`.zig-version`](../.zig-version), then build the application from the repository root:

```sh
zig build
```

The executable is installed at `zig-out/bin/ivenna` and embeds the [model-facing resources](#model-facing-resources). Rebuild it after editing code or those resources. The [local development guide](../dev/README.md) covers service preparation, running from source, and updating middleware; the [running guide](running.md#starting-the-kernel) covers starting the built executable.

## Validation

Build the application and exercise the affected behavior through communication and model/tool work:

| Area changed | Checks |
| --- | --- |
| Execution | Joint processing of queued events, budget-limited FIFO admission, durable acknowledgement of only the admitted prefix before model work, tool-result continuation, whole-group handoff, direct-parent reports, report-capacity checks including after restart, and context release |
| Failure handling | Required-capability failures stop the runtime and join concurrent work; ordinary tool outcomes allow continuation |
| Communication | Explicit zero, one, or multiple sends; correspondent ID lifetime; incoming `from` IDs and outgoing tool arguments retained in history; final text without implicit sending |
| Email | Same-domain address conversion, From-address filtering and unsupported-body skips across query pages, confirmed standalone submission and copy retirement, and independent intake regardless of thread, read, starred, or archived state |
| Service | Health and reception status during startup, operation, and shutdown; SMTP rejection when reception is closed |
| History and restart | Complete event groups, model/tool exchanges, and unread internal observations survive restart; model output and media round-trip; forks share inherited segment prefixes; compaction preserves session relationships; startup uses current state; old activations, external deliveries, receipts, and tool calls are not replayed |
| History storage | Metadata queries discover groups and selected reads preserve order; body hashes, predecessor keys, scopes, and committed counts validate history; failed creates prevent checkpoint publication; uncommitted suffixes stay outside restored history; numeric revision selects the current checkpoint after interruption; unchanged saves reuse publication |
| History maintenance | Current groups remain writable; sealed inherited prefixes restore from Archive; unreferenced records, obsolete observations, and old checkpoints enter Trash; selected records survive maintenance; existing Trash remains with the mail service; maintenance failures stop the runtime |
| Communication-copy maintenance | Retirement of acknowledged inputs and abandoned outgoing copies, preservation of pending input and in-progress sends, and service-owned Trash expiry |
| Model-facing interfaces | Record and request serialization, response variants, tool selection, and complete-payload budget accounting |

Report the checks performed. Distinguish reconstruction of understanding from execution recovery.
