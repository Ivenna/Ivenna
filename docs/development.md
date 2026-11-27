# Development

The design guide sets Ivenna's goals and interface principles. The architecture and running guides describe the current implementation and its deployment. See the [design intent](design.md), [architecture guide](architecture.md), and [running guide](running.md).

## Development conventions

The project is exploratory. Data structures, interfaces, and module boundaries are not yet settled; change them directly to match the design.

Leave behavior that needs further design as an unavailable or explicitly limited placeholder. Describe what works and what remains undecided.

When a design changes, remove superseded runtime interfaces and state. Keep the decoding needed to read retained history at the storage boundary. Avoid migration frameworks.

Communication and memory are operating requirements of the whole runtime. Component boundaries organize responsibilities within that contract. Keep safeguards at the boundary that owns the requirement, use the guarantees established there, and remove duplicated checks in downstream components.

## Design and implementation

Start with the intended behavior and its reason, then establish responsibilities and interfaces. Explain design changes through their effects on Ivenna, its correspondents, or the deployment user. Implementation experience can inform these choices; a current code path or service limitation alone does not establish a design requirement.

Use the [documentation index](README.md) to find the guide for a task. Put behavioral choices and their reasons in the design guide, operations and outcomes in the owning interface guide, and implementation details in the architecture guide. CLI help gives readers the syntax, defaults, and results they need at the command line.

Use the running guide for deployment and service procedures and the local development guide for the supplied environment. Put steps specific to updating an existing deployment in the [upgrade guide](upgrading.md). Pull requests describe the difference from their target branch. Release notes describe user-visible changes and link to upgrade steps when needed.

Keep project guidance focused on Ivenna's interfaces, integration choices, and their operational effects. Refer readers to component documentation for general use and administration, keeping Ivenna-specific settings and procedures here.

Design can name an operation or concept when it expresses a behavioral choice, such as explicit sending or work ownership. When behavior changes, update the affected design, interface contracts, model-facing resources, and implementation together. When replacing a mechanism while preserving behavior, update its implementation and architecture description. Describe any remaining implementation limitation and its effect in the relevant interface or operational guide.

## Implementation boundaries

### Packages and dependencies

Organize packages around cohesive capabilities, keeping their types, rules, resources, and implementation together. Public interfaces should let callers use a capability without coordinating its internal components. Keep supporting mechanisms with their owning capability. Applications select implementations, load deployment settings, and own program startup and shutdown.

Use `packages/agent_contracts` for shared communication and capability contracts. Keep execution policy, model-input types and rendering, prompts, and runtime tool declarations in `packages/agent`. Follow the [architecture guide's responsibilities and dependency graph](architecture.md#responsibilities), and update producers and consumers together when changing a shared type or operation.

Keep configuration with the behavior it controls. Execution owns scheduling, context limits, and reasoning selection. Capability implementations own their connection settings and protocol encoding. The application reads deployment settings from the environment and runs the HTTP status and local channel listeners.

### Types and protocols

Decode external protocols in the components that own them and pass typed values to execution. Model coexisting fields together and mutually exclusive alternatives as variants with their own payloads. Let the component performing the action check the current state and report the outcome it can confirm. See [message delivery](architecture.md#message-delivery).

Keep native mail record IDs, headers, folders, and thread grouping in the email adapter. The adapter passes correspondence and callback observations in typed envelopes. The agent owns callback registration, source attribution, routing, and admission. See the [inbox contract](../packages/agent_contracts/src/inbox.zig).

`Input` defines and renders the runtime's user messages. Include the complete ID when an observation or result supplies a reference. Keep the state needed for delivery and resumption in runtime records through persistence and compaction. See the [input contract](input.md) and the [input renderer](../packages/agent/src/input.zig).

Use `Content` for capability results. Commit the adapter's prepared `Model.Content` to working history, and carry the model's continuation items, including reasoning, as opaque bytes. Implement and test inference against DeepSeek's Responses API and uploads against its Files API. See the [model contract](../packages/agent_contracts/src/model.zig), [tool result preparation](architecture.md#tool-results), and [DeepSeek Responses guide](https://api-docs.deepseek.com/guides/responses_api/).

The agent selects the history, observations, tools, and reasoning effort for each request. The adapter measures the request and checks its limits before sending it. Use the same encoder for measurement and inference. Keep request-specific encoding separate from retained history and shared adapter settings. See [bounded model context](architecture.md#bounded-model-context).

### Model-facing resources

Review model-facing text in the request the focus will receive. Read the shared prompt together with the retained history, current turn, and tools available for that inference. Before adding an explanation, ask what the model can already infer and which fact it still needs for the decision at hand. See [what a focus receives](design.md#what-a-focus-receives) and [request assembly](architecture.md#working-history-and-user-messages).

| Resource | Purpose |
| --- | --- |
| [system.md](../packages/agent/src/system.md) | Shared orientation to focuses, observations, communication, and resumption |
| [Agent tools](../packages/agent/src/tools.json) | Send messages, manage channels and subscriptions, open focuses, and schedule wakeups |
| [Host tools](../packages/host/src/tools.json) | Host shell actions, invocation parameters, and results |
| [Resource reader](../packages/resources/src/tools.json) | Locations, views, and read windows. When web access is enabled, the [DeepSeek Fetch client](../packages/resources/src/deepseek.zig) supplies the service and billing notice. |
| [Memory tools](../packages/memory/src/tools.json) | Memory actions, invocation parameters, and results |
| [compaction.md](../packages/agent/src/compaction.md) | Instructions for writing the summary in a handover |

Use the shared prompt for orientation across focuses and turns. Describe what the focus can do and what the call will change. A memory read describes what Ivenna can revisit in its rooms. Put the services involved in those reads and any charges in the deployment documentation. When the focus explicitly chooses to send material to a service, explain the destination and potential charge at that choice. Express allowed values and bounds in the schema and match defaults to runtime behavior. See [tool content](content.md) for what reaches the model and what working history keeps.

Use observations and tool results to convey what happened, which effects are confirmed, and what remains uncertain. When asking for a revision, say what the focus can change. If a handover leaves too little room to continue, ask for a shorter summary and leave the choice of content to Ivenna. Keep the measured size and limit in operator logs with other runtime diagnostics.

Keep capability tool declarations with their implementation and register capabilities through `Tools`. The agent uses the same role selection for declaration and invocation. Agent-owned action recognition, typed arguments, and role selection live together in [tools.zig](../packages/agent/src/tools.zig). The kernel owns the actions' effects.

### Session execution

Execution owns session state and the boundaries at which new observations can affect it. Preserve complete model/tool rounds when changing admission or scheduling. The [architecture guide](architecture.md#sessions-work-and-communication) defines registry synchronization and the lifetimes of activations, contexts, and workers.

Match ownership to lifetime. A capability can start work that outlives the invoking model round or activation. Copy or transfer retained values and cancel and join tasks before releasing their dependencies. The capability manages those resources and publishes their outcomes. The agent manages session lifetimes and routes observations.

Persist the receiving focus before returning a callback or subscription reference. Capabilities register callbacks through the invoking session's registrar. A report can outlive its subscription, so its destination must remain available after withdrawal. See [callback registration](architecture.md#event-sources-and-callback-admission) and [subscription delivery](architecture.md#subscription-delivery).

Keep a session's identity independent of context residency, and retain its history for as long as it can resume. When handling a failure, consider what repeating the operation would do. A fresh inference can revise an unusable summary. A command that already ran has an outcome to preserve. See [runtime availability](design.md#runtime-availability).

### Working history

Context owns the observations, complete model/tool exchanges, and handovers retained for continued reasoning. Admission retains observations, and round commit retains complete exchanges. Candidate measurement leaves history unchanged. The runtime carries sampled state into a handover independently of generated text. Follow [message assembly](architecture.md#working-history-and-user-messages) and the [handover contract](input.md#handover-generation-and-replacement) when changing that boundary.

Trace changed state from the operation that commits it to the startup path that restores it. The saved context, admitted observations, and pending registrations must remain consistent in the checkpoint startup selects, including when a write succeeds and confirmation fails. See the [recovery state inventory](architecture.md#recovery-state) and [storage contract](../packages/agent_contracts/src/history.zig).

Activity expressions are cross-session observations of what the source said, distinct from a committed model/tool round. Preserve unread reports independently of the source context, and advance their consumption with core history admission in the same checkpoint. Compaction output and inherited exchanges must not be published again as new activity expressions.

Storage failures must not silently replace history with an empty context. [Startup](architecture.md#startup-and-interruption) reconstructs understanding and pending work without replaying effects.

## Repository and build

Use the Zig version in [`.zig-version`](../.zig-version). Build the `ivenna` executable from the repository root.

```sh
zig build
```

The [root build](../build.zig) and the [application build](../apps/ivenna/build.zig) both install `zig-out/bin/ivenna`. From either build directory, run `zig build run -- --help` to see the available commands before configuring services. The [local development guide](../dev/README.md#starting-the-kernel) covers service preparation and startup from source.

For release packages, Actions snapshots, and local packages, see [Releasing Ivenna](releasing.md).

Each application owns its entry point. The [memory app](../apps/memory) has a Nushell entry point and a Containerfile. Shared Zig libraries in `packages/` expose their modules through `src/root.zig` and declare dependencies in `build.zig` and `build.zig.zon`. When adding or moving a unit, update its consumers' build declarations, the [root package's exported paths](../build.zig.zon) and the [architecture map](architecture.md#responsibilities).

The CLI provides command summaries and embeds detailed local command help. Rebuild `ivenna` after editing help or model-facing resources. See [cli.zig](../apps/ivenna/src/cli.zig), [local command help](../apps/ivenna/src/help), and [model-facing resources](#model-facing-resources).

## Validation

Build the application and select automated checks for the changed contract. For a change across runtime boundaries, exercise the affected behavior through communication and model/tool work in the local development environment. Start with what Ivenna or its correspondents should observe. Follow the outcome through the components that produce, deliver, and retain it. See the [testing guide](testing.md) and [local development environment](../dev/README.md).

Exercise failure and interruption where they can separate an external effect from its recorded outcome. Confirm that the resulting observation exposes known effects and uncertainty. Where state or tasks survive a call, verify their restoration and cleanup through the owning component's contract. Scale these checks to the changed behavior and affected boundaries.

Report the checks performed and their limits. Distinguish reconstruction of understanding from execution recovery.
