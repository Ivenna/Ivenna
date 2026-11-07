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

Use `packages/agent_contracts` for shared communication and capability contracts. Keep execution policy, model-input types and rendering, prompts, and runtime tool declarations in `packages/agent`. Follow the [architecture guide's responsibilities and dependency graph](architecture.md#responsibilities), and update producers and consumers together when changing a shared type or operation.

Keep configuration with the behavior it controls. Execution owns scheduling, context limits, and reasoning selection; capability packages own connection settings and protocol encoding. The application translates environment values into those configurations and owns HTTP listener settings.

### Types and protocols

Decode external protocols in their owning components and supply typed contracts to execution. Rely on the guarantees established there; validate additional requirements at the boundary that owns them. Model coexisting fields together and mutually exclusive alternatives as variants with their own payloads.

Keep mail identifiers, headers, folders, and thread grouping out of scheduling and model observations. The email adapter produces typed [correspondence and callback envelopes](../packages/agent_contracts/src/inbox.zig); the agent owns callback registration, source classification, routing, and admission.

[Input](../packages/agent/src/input.zig) owns runtime user-message rendering. Preserve native [model output and tool replies](../packages/agent_contracts/src/model.zig), copying opaque continuation bytes without interpreting their protocol. Tool results use [Content](content.md) parts.

The agent selects tools and reasoning per request; the model adapter encodes and measures the complete payload with those settings. Use the same encoder for measurement and inference, including tool-result limiting, without mutating a shared provider.

### Model-facing resources

Treat prompts and tool descriptions as editable interfaces:

| Resource | Purpose |
| --- | --- |
| [system.md](../packages/agent/src/system.md) | Input interpretation and response scope needed by the model |
| [Agent tools](../packages/agent/src/tools.json) | Correspondence, activity forks, session coordination, and wakeups |
| [Host tools](../packages/host/src/tools.json) | Host shell actions, invocation parameters, and results |
| [Memory tools](../packages/memory/src/tools.json) | Memory actions, invocation parameters, and results |
| [compaction.md](../packages/agent/src/compaction.md) | What a handover must preserve |

Keep capability tool declarations with their implementation and register capabilities through `Tools`. The agent owns availability policy and must use the same role selection for declaration and invocation.

Put task facts and observations in user input. Prompts and tool descriptions should explain decisions and interpretation; field references belong in the [input contract](input.md), mechanisms in the architecture guide, and procedures in the running guides. Update affected resources and interface documentation together.

### Session execution

Keep queue, activation, context, and callback-registration changes under registry synchronization. The kernel coordinates adapter calls and worker lifetimes. Copy or transfer values that outlive a model-round arena, and admit events only between complete model/tool batches. Follow the [scheduling](architecture.md#scheduling-and-capacity), [fork](architecture.md#activity-forks), [completion](architecture.md#activation-completion-and-sleep), and [callback admission](architecture.md#event-sources-and-callback-admission) contracts.

Keep attention scheduling separate from durable observations and consume its signal only for an ordinary inference. Keep session identity separate from context residency, source destinations fixed for their lifetime, and execution limits separate from storage retention.

A capability may retain a callback ID, never its invocation-scoped registrar. Background host tasks belong to the application runtime: shutdown cancels and joins them before releasing dependencies. Infrastructure and execution failures close reception and end concurrent work; ordinary tool outcomes remain observations.

### Working history

Context owns retained observations, complete model/tool exchanges, and handovers. Input adds current facts and one tagged purpose to each inference; it does not replace the model's understanding. Follow [message assembly](architecture.md#working-history-and-user-messages) and the [two-stage handover contract](input.md#handover-generation-and-replacement).

Measure admission against its resulting state, with independent candidate projections. Confirm admitted records and their checkpoint before acknowledging receipts. Keep callback registration removal and observation persistence together, preserving the duplicate barrier through acknowledgement. Unload only confirmed history selected by the checkpoint.

The agent owns history encoding and retention selection; `HistoryStore` adapters own native representation and protocol limits. Serialize publication and maintenance through the registry, and reconcile against the confirmed checkpoint before retirement. [Startup](architecture.md#startup-and-interruption) reconstructs execution without replaying old calls or processes; storage failures must not silently replace history with an empty context.

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

Build the application and exercise the affected behavior through communication and model/tool work. Select checks relevant to the change:

| Area | Checks |
| --- | --- |
| Execution | FIFO budget admission, complete tool batches, fair dispatch, fork inheritance, role-based tool access, report reservations, direct messages, attention-only turns, and sleeping-session resumption |
| Model-facing interfaces | Record/Turn shapes, observation delivery without duplication, native model/tool messages, summary generation and replacement, and complete-payload budgets |
| Continuity | Durable admission and acknowledgement, cold restoration, startup observations, callbacks and wakeups across restart, and unknown interrupted effects without replay |
| Storage | Record and checkpoint validation, failed publication, committed-chain selection, independent inherited histories, per-session replacement, retention, and preservation of selected records |
| Capabilities and service | Explicit sending, addressing and body projection, independent intake streams, host cancellation and result delivery, content omissions, and health/reception state |
| Failures | Ordinary tool outcomes allow continuation; infrastructure and execution errors close reception and join concurrent work |

Report the checks performed. Distinguish reconstruction of understanding from execution recovery.
