# Design intent

Ivenna is a body for an LLM soul: a runtime through which the model can act, perceive results, and organize memory. The project explores how persistent interaction and autonomous memory can sustain a sense of self over time. Ongoing communication and autonomous activity guide its interaction design.

This guide sets the intended behavior and interface principles. See the [documentation index](README.md) for interface contracts and the [architecture guide](architecture.md) for the current implementation.

## Capabilities and acquired knowledge

The runtime exposes capabilities to a model with broad prior knowledge, like a knowledgeable person encountering the tools at hand. Interfaces should make available actions discoverable and their effects understandable.

The model draws on prior knowledge and interaction to choose programs and use tools. Its identity, preferences, working methods, and memory organization can develop with that experience.

## Runtime availability

Communication and autonomous memory are required for Ivenna to operate. Infrastructure, model, and session-execution failures end the runtime and its concurrent work. Defined tool outcomes, such as a missing memory entry, a capacity limit, or a command's nonzero exit, remain observations for the model.

The receiving boundary checks Ivenna's reception status before accepting correspondence. Reception closes during startup, shutdown, or failure; sender retry and queuing belong to the sender. See [reception readiness](running.md#service-status-and-reception) for the precheck's limits.

## Model-facing descriptions and results

Tool descriptions explain how to choose an operation, invoke it, and interpret its result. Keep them concise and leave room for the model's knowledge and judgment. Detailed field references and implementation explanations belong in developer documentation unless they affect use.

Task and message text remain free-form. Each inference combines current execution facts with one purpose: ordinary work with observations, or handover generation. Earlier observations, model output, tool replies, handovers, and autonomous memory carry understanding; transient execution state supplements that understanding. The [input contract](input.md) defines these lifetimes and structures.

Tool results preserve operation outcomes, source descriptions, and supported media together. When content cannot be supplied, retain its source information and describe the omission.

## Communication with people and programs

Messages enter the core as observations of who said what, with correspondent IDs and observation time. Receiving one does not imply that Ivenna was addressed or must respond. These IDs connect observations with explicit outgoing communication and its retained model/tool exchanges.

Ivenna chooses whether to communicate, to whom, and what to say through `send_message`. An activation can send zero, one, or several messages; final text remains an internal result or work report. The [communication guide](communication.md) defines these interfaces.

## Internal work and state

A task describes work to accomplish. A session has a stable identity, retained understanding, and an event queue. An activation continues its work through model/tool rounds, admitting further events between complete rounds so new information can adjust the next decision without interrupting an inference or tool.

A final response ends the activation when no queued arrivals or core attention signal require more reasoning. The session can then sleep and later resume with its retained understanding. The runtime manages context residency and restoration. Activation completion, task success, memory residency, and data retention have separate lifecycles; durable input acknowledgement transfers responsibility independently of task completion.

## Core and concurrent attention

One core session coordinates Ivenna, relating correspondence to retained understanding and shared memory. Sustained work moves to separate sessions so the core can return to its queue. Core responsiveness depends on both an independent execution lane and short coordination turns.

Core and work sessions can explicitly fork an activation's whole work and retained context to a new child. The caller returns to its queue; their histories then grow independently. A work activation's final result reaches its direct parent and the core automatically, with one copy when they coincide. The core also learns the identity, parent, and assignment of nested forks.

Execution limits separately bound registered sessions, pending events, pending callbacks, background commands, and concurrent work. Eligible work sessions receive rotating opportunities to start activations; running activations are not preempted. See [scheduling and capacity](architecture.md#scheduling-and-capacity).

Sessions share one body: files, memory, communication, and host processes. They can hold different understanding and must account for effects another session may already have produced. Ivenna chooses what to remember and how to organize shared autonomous memory wherever its attention is focused.

## Events and waiting

Ivenna interprets observations; the runtime owns delivery and resumption. A known destination must not depend on a model remembering to relay a result or wake a sleeping session. Direct session messages identify their sender; the receiver weighs their content against its own evidence and understanding.

Each inference receives a complete snapshot of the finite runtime state exposed by the interface. This remains self-contained after a fork, restart, or compaction, at the cost of repeated request bytes. A delta interface would also need a baseline, addition and removal semantics, and recovery when that baseline becomes invalid. Task meaning and prior effects remain in model messages, handovers, and memory. Concurrent attention can schedule the core to reconsider fresh state without adding a historical event.

Every session can schedule a durable one-time `wakeup` for itself. Work sessions can run host commands in the background and receive completion callbacks. Sources bind to their receiving session before starting and retain that destination across forks. See [session communication](communication.md#session-communication-and-wakeups) and [background commands](host.md#background-commands).

Sleeping sessions keep their identities and histories. At the registered-session limit, new forks fail while existing sessions remain addressable. Automatic identity retirement is not implemented.

## Context and continuity

Working contexts retain observations, complete model output, and tool results across interruption. Limits cover complete model requests and generated responses, with byte counts and token allowances stated separately.

Compaction first reads retained LLM messages to generate a handover without continuing tasks or admitting waiting observations. After successful generation and validation, the runtime replaces those messages with the system prompt and handover for the next ordinary inference. The free-form handover preserves commitments, uncertainty, effects, and the identities needed to continue; session relationships persist.

Startup restores sessions, unread internal work, callback registrations, and wakeups. Interrupted work resumes with a startup observation; dormant branches wait for an event. Host processes and old tool calls are not replayed. A missing host completion becomes an interrupted observation with unknown effects, while a stored result remains available. Persistence does not establish exactly-once effects. The [startup contract](architecture.md#startup-and-interruption) defines reconstruction and its limits.

## Data ownership

The deployment user owns Ivenna's correspondence, working histories, artifacts, and autonomous memory, and chooses where they live. Keep them open to inspection and management.

These stores have separate retention lifecycles. History remains available while a retained context needs it; other material follows deployment policy. See [history retention](architecture.md#history-retention) and [running Ivenna](running.md#data-and-retention). Diagnostics remain separate from the source material and handovers used for continuity.
