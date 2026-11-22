# Development

The [design intent](design.md) guides product and interface decisions; the [architecture guide](architecture.md) explains implementation responsibilities and ownership. Follow the [running guide](running.md) for deployment and configuration.

## Development conventions

The project is exploratory. Data structures, interfaces, and module boundaries are not yet settled; change them directly to match the design.

Leave behavior that needs further design as an unavailable or explicitly limited placeholder. Describe what works and what remains undecided. When a design changes, remove superseded behavior and state; do not retain compatibility paths or introduce migration frameworks.

Communication and memory are operating requirements of the whole runtime. Component boundaries organize responsibilities within that contract. Keep safeguards at the boundary that owns the requirement, use the guarantees established there, and remove duplicated checks in downstream components.

## Design and implementation

Start with the intended behavior and its reason, then establish responsibilities and interfaces. Explain design changes through their effects on Ivenna, its correspondents, or the deployment user. Implementation experience can inform these choices; a current code path or service limitation alone does not establish a design requirement.

Keep each document focused on its role:

| Document | Scope |
| --- | --- |
| Design guide | Goals, behavioral choices, interface principles, and their reasons |
| Development guide | Change conventions, implementation boundaries, builds, and validation |
| Testing guide | Test selection, execution, and maintenance |
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

Keep mail identifiers, headers, folders, and thread grouping out of scheduling and model observations. The email adapter produces typed [correspondence and callback envelopes](../packages/agent_contracts/src/inbox.zig); the agent owns callback registration, source attribution, routing, and admission.

[Input](../packages/agent/src/input.zig) owns model-facing observation projection and runtime user-message rendering. Execution projects internal session and delivery state into this interface, exposing facts that help Ivenna choose its next action. Keep runtime state and exact references under program ownership through persistence and compaction. Supply complete references in operation results and observations, and return invalid selections as operation outcomes.

Preserve native [model output and tool replies](../packages/agent_contracts/src/model.zig), copying opaque continuation bytes without interpreting their protocol. Tool results use [Content](content.md) parts.

The agent selects tools and reasoning per request; the model adapter encodes and measures the complete payload with those settings. Use the same encoder for measurement and inference, including tool-result limiting, without mutating a shared provider.

### Model-facing resources

Treat prompts and tool descriptions as editable interfaces:

| Resource | Purpose |
| --- | --- |
| [system.md](../packages/agent/src/system.md) | Runtime orientation, continuity, observation interpretation, action scope, and focus lifecycles shared by all sessions |
| [Agent tools](../packages/agent/src/tools.json) | External expression, opening and reaching focuses, and future attention |
| [Host tools](../packages/host/src/tools.json) | Host shell actions, invocation parameters, and results |
| [Memory tools](../packages/memory/src/tools.json) | Memory actions, invocation parameters, and results |
| [compaction.md](../packages/agent/src/compaction.md) | Understanding to carry into a handover |

Follow the [design's prompt boundary](design.md#a-self-in-the-world) when editing model-facing resources. Keep the system prompt focused on the semantics needed to interpret inputs, use available actions, and continue across activations.

Keep capability tool declarations with their implementation and register capabilities through `Tools`. The agent owns availability policy and must use the same role selection for declaration and invocation.

Keep agent-owned action recognition, typed arguments, and role selection together in [tools.zig](../packages/agent/src/tools.zig); Kernel owns their effects. All sessions use the same system prompt. Express differences in available actions through tool selection, and identify the current focus, task, and circumstances in user input. Ordinary inference, admission measurement, and compaction prepend the same prompt independently of retained history.

Follow the [capability principles](design.md#understanding-and-autonomy) when writing these resources. Read each tool declaration as one interface: names, structure, constraints, and descriptions appear together. Express value choices and bounds structurally, and mirror actual runtime defaults in schema annotations. Use descriptions for the action, its effects, and parameter or result semantics the structure cannot convey. Keep cues of ownership and continuity brief and open to Ivenna's judgment, leaving content, organization, and learned practices to its experience. Preserve precision about the operation behind a suggestive name.

Allow for mistaken reasoning and incomplete recall. Make references discoverable where Ivenna needs them, and report an invalid selection in the operation's result. Prompts explain meaning and invite judgment. The runtime component that owns an operation enforces its requirements.

Put task facts and observations in user input. Prompts and tool descriptions should explain decisions and interpretation; field references belong in the [input contract](input.md), mechanisms in the architecture guide, and procedures in the running guides. Update affected resources and interface documentation together.

### Session execution

Execution owns session state and the boundaries at which new observations can affect it. Preserve complete model/tool rounds when changing admission or scheduling. The [architecture guide](architecture.md#sessions-work-and-communication) defines registry synchronization and the lifetimes of activations, contexts, and workers.

Match ownership to lifetime. A capability can start work that outlives the invoking model round or activation. Copy or transfer retained values and cancel and join tasks before releasing their dependencies. The capability manages those resources and publishes their outcomes. The agent manages session lifetimes and routes observations.

Persist the destination of a future observation before returning its reference. A capability binds a callback through the invoking session's registrar. A subscription can close while accepted reports still await admission, so keep their destination available through delivery. See [callback registration](architecture.md#event-sources-and-callback-admission) and [subscription delivery](architecture.md#subscription-delivery).

Keep a session's identity independent of context residency, and retain its history for as long as it can resume. When handling a failure, consider what repeating the operation would do. A fresh inference can revise an unusable summary. A command that already ran has an outcome to preserve. See [runtime availability](design.md#runtime-availability).

### Working history

Context owns the observations, complete model/tool exchanges, and handovers retained for continued reasoning. Admission retains received observations; round commit retains complete exchanges. Candidate measurement leaves history unchanged. Compaction supplies retained history and sampled runtime state to the summary inference, then carries that same state into the handover independently of the generated text. Follow [message assembly](architecture.md#working-history-and-user-messages) and the [handover contract](input.md#handover-generation-and-replacement) when changing that boundary.

Persistence changes must keep the saved context, admitted observations, and pending registrations consistent, including when saving succeeds but acknowledgement does not. The agent owns history encoding and retention selection; `HistoryStore` adapters own native representation and protocol limits. The [history contract](architecture.md#persistent-working-history) explains publication, restoration, and retirement.

Activity expressions are cross-session observations of what the source said, distinct from a committed model/tool round. Preserve unread reports independently of the source context, and advance their consumption with core history admission in the same checkpoint. Compaction output and inherited exchanges must not be published again as new activity expressions.

Storage failures must not silently replace history with an empty context. [Startup](architecture.md#startup-and-interruption) reconstructs understanding and pending work without replaying effects.

## Repository and build

Use the Zig version in [`.zig-version`](../.zig-version). From the repository root, build the kernel and its companion CLI together.

```sh
zig build
```

The [root build](../build.zig) installs `ivenna` and `ivenna-report` next to each other in `zig-out/bin`. Building from [apps/ivenna](../apps/ivenna) also installs the pair. To build and test the reporter on its own, run `zig build` and `zig build test` from [apps/ivenna-report](../apps/ivenna-report). The [memory app](../apps/memory) has a Nushell entry point and a Containerfile.

Each application owns its entry point. Shared Zig libraries in `packages/` expose their modules through `src/root.zig` and declare dependencies in `build.zig` and `build.zig.zon`. When adding or moving a unit, update its consumers' build declarations, the [root package's exported paths](../build.zig.zon) and the [architecture map](architecture.md#responsibilities).

The kernel executable embeds the [model-facing resources](#model-facing-resources). Rebuild it after editing code or those resources. The [local development guide](../dev/README.md) covers service preparation, running from source, and updating middleware; the [running guide](running.md#starting-the-kernel) covers starting the built executable.

## Validation

Use the [testing guide](testing.md) to select, run, and maintain automated checks.

Build the application. For changes across runtime boundaries, exercise the affected behavior through communication and model/tool work in the [local development environment](../dev/README.md). Choose checks from the contract being changed: establish what Ivenna or its correspondents should observe, then follow that outcome across the components that produce, deliver, and retain it. A boundary change needs evidence from its producers and consumers together.

Exercise failure and interruption where they can separate an external effect from its recorded outcome. Confirm that the resulting observation exposes known effects and uncertainty. Where state or tasks survive a call, verify their restoration and cleanup through the owning component's contract. Scale these checks to the changed behavior and affected boundaries.

Report the checks performed and their limits. Distinguish reconstruction of understanding from execution recovery.
