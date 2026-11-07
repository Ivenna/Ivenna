# Design intent

Ivenna is a body for an LLM soul: a runtime through which the model can act, perceive results, and organize memory. The project explores how persistent interaction and autonomous memory can sustain a sense of self over time. Ongoing communication and autonomous activity guide its interaction design.

This guide sets the intended behavior and interface principles. See the [documentation index](README.md) for interface contracts and the [architecture guide](architecture.md) for the current implementation.

## Capabilities and acquired knowledge

The runtime's interfaces expose the body's capabilities to a model with broad prior knowledge, like a knowledgeable person encountering the tools at hand. They should make available actions discoverable and their effects understandable.

Program choices and general tool use draw on the model's prior knowledge and what it learns through interaction. Its identity, preferences, working methods, and memory organization can develop with that experience.

## Runtime availability

Communication and autonomous memory are required for Ivenna to operate. The runtime starts with both available; infrastructure failures in either end the runtime and its concurrent work. Failures in model and session execution also end the runtime. Defined tool outcomes, such as a missing memory entry, a capacity limit, or a command's nonzero exit, remain observations for the model to understand.

Ivenna exposes its health and whether reception is open. Senders must expect reception to close when Ivenna is starting, stopping, or unavailable. The receiving boundary checks that state before accepting new messages. Retry and queuing by a sender belong to that sender; automatic offline reception and recovery are outside the current design.

## Model-facing descriptions and results

Tool descriptions explain how to choose and invoke an operation and interpret its result. Model input identifies each observation's source, content, and context, with the runtime state needed to understand ongoing work. Results convey the state and outcome of the particular invocation.

Keep these interfaces concise and leave room for the model's knowledge and judgment. Detailed field references and implementation explanations belong in developer documentation unless they affect how the interface is used or interpreted.

Keep task text and message text free-form. Each inference receives a turn combining current execution facts with one purpose: ordinary work with new observations, or handover generation with summary instructions. Earlier observations, model output, tool replies, and handovers carry the understanding needed to continue. New observations remain in that history; transient execution state does not. The system prompt explains these lifetimes and response scope; the [input contract](input.md) defines their structure.

Tool results can combine text, media, and information about an operation's outcome and source. Classifying or interpreting one source preserves the other observations in the result. When a provider or budget cannot carry content, retain its source information and describe the omission.

## Communication with people and programs

People and programs communicate with Ivenna through messages. Each arrival enters the core as an observation of who said what. An observation does not imply that the words were addressed specifically to Ivenna or require a response. Ivenna relates it to its ongoing understanding and work.

The communication interface supplies received text, the IDs of participants it came from, and observation time. Retained model and tool exchanges preserve Ivenna's outgoing communication with its chosen recipient IDs. Correspondent IDs link observations with explicit communication actions. Understanding correspondents and their relationships to Ivenna can inform coordination. Policies based on correspondent IDs, including any participant whitelist or scheduling distinctions, remain undecided.

Ivenna explicitly chooses whether to send a message, to whom, and what it says through `send_message`. An activation can send zero, one, or several messages. For ordinary work, final model text supplies an internal result in the core or a report to a work session's parent and the core. The [communication guide](communication.md) describes the interface and its current implementation.

## Internal work and state

Work is defined by a task and the understanding needed to continue it. A session has a stable identity, retained understanding, and an event queue. An activation continues work through model and tool rounds. Before each new inference, it can admit queued events after the preceding model response and its complete tool batch have been retained. New observations can therefore inform the next decision without interrupting a running inference or tool.

Execution state coordinates ongoing work. Retained working contexts persist independently of execution. Incoming correspondence is acknowledged once its complete observation is durably retained, independently of task completion.

A final response ends the activation once queued arrivals and any pending core attention signal have been considered, leaving the session sleeping when no work remains. It does not certify task success or retire the session. A later event wakes the same session with its retained understanding. The runtime can unload sleeping contexts and restore them from durable history; Ivenna does not need to decide which histories occupy memory. Activation completion, task completion, memory residency, and data retention have separate lifecycles.

## Core and concurrent attention

One core session coordinates Ivenna throughout the kernel's lifetime. It has no parent. It relates incoming observations to its retained understanding and shared memory, and can maintain memory or send a brief message directly. Sustained work moves to separate sessions so the core can return to its queue. Later messages still enter the core.

Forking is an explicit model decision available to core and work sessions alike. It passes the activation's work to another focus of Ivenna's attention with the complete retained working context, including any earlier handover. The caller's activation ends and it returns to its queue; the child starts an activation for its assignment. The child and its parent remain addressable after either activation ends.

A work session's final text returns one combined result for that activation to its direct parent and the core, with one copy when they are the same session. The runtime delivers both reports without asking a model to relay them. When a work session creates a child, the core also observes its identity, parent, and assignment; the core already knows its own forks through their tool exchanges. Parent relationships preserve the origin of work; they do not require other notifications to travel through the parent chain.

After a fork, the histories grow independently. The core retains its reception and coordination history; execution detail accumulates in the session carrying out the work. This keeps the core's context useful for further coordination and forks.

Separate reasoning settings favor responsive coordination and deeper sustained work. The runtime separately bounds registered sessions, pending events, pending callbacks, background commands, and concurrent work, and preserves an independent execution lane for the core. Work sessions eligible to start an activation receive rotating opportunities to claim available execution slots; running model and tool rounds are allowed to finish. Forking returns the core to its queue without waiting for the work session. Core responsiveness depends on keeping coordination turns short as well as scheduling them promptly.

These contexts share a body: files, memory, communication, and host processes. Core and work sessions can recall, record, and organize the same autonomous memory. Ivenna chooses what to remember and how to organize it wherever its attention is focused. Sessions account for effects another session may already have produced.

## Events and waiting

Ivenna decides what an observation means and how to respond. The runtime owns delivery and resumption: a known destination must not depend on a model remembering to relay a result or reactivate a sleeping session.

Sessions can send observations directly to another session. A message identifies the session that actually sent it; its contents remain evidence for the receiver to interpret alongside its own understanding. Different sessions may hold different or outdated information. Source attribution preserves those distinctions without giving one session's account automatic precedence.

Each inference receives a complete snapshot of the finite runtime state exposed by the interface, including session execution state and pending callbacks. A full snapshot remains self-contained after a fork, restart, or compaction without requiring Ivenna to maintain a baseline of changes. It adds repeated bytes to the request budget. Task meaning, reasoning, prior effects, and external-world understanding remain in model messages, handovers, and autonomous memory rather than being recopied into execution state.

A delta interface would require a defined baseline per session, addition and removal semantics, and recovery when that baseline becomes invalid. The current design keeps the finite snapshot complete; an incremental form needs a concrete use case to justify those additional responsibilities.

Changes in concurrent attention can prompt the core to reconsider that state even without a new event. This scheduling signal does not add a historical notice; the core reasons from its retained understanding and fresh state.

Each session can register a durable one-time `wakeup` for itself. Work sessions can start a host command in the background and return control while it runs. Completion becomes a callback observation for the session that started it. The runtime records the source and destination before starting the activity and retains them until the observation is durably admitted. A fork does not transfer already registered callbacks to the child. The [communication guide](communication.md#session-communication-and-wakeups) and [host guide](host.md#background-commands) define the available operations and their limits.

Sleeping sessions keep their identity and durable working history even when their context is unloaded. At the registered-session limit, creating another session fails explicitly; existing sessions can still receive work. Automatic retirement of old session identities remains undefined. The [architecture guide](architecture.md#activation-completion-and-sleep) describes these lifetimes.

## Context and continuity

Working contexts retain observations, complete model output, and tool results. All registered sessions preserve that understanding across runtime interruption, along with session identities, parent relationships, unread internal events, and pending callback registrations. Working history persists independently of whether its context is loaded and independently of host execution artifacts.

Limits cover the complete model request, including instructions, tool definitions, observations, and tool results, as well as the generated response. Each limit states what it measures; byte counts and model tokens are separate units.

When context needs to be shortened, a maintenance inference reads the retained LLM messages and generates a handover. It does not continue tasks or consume observations waiting for admission. Only after that handover is successfully generated and validated does the runtime replace those messages with the system prompt and handover for a new ordinary inference.

The handover remains free-form text. It should preserve commitments, relevant uncertainty, completed effects, and correspondent IDs and relationships needed for continued understanding. Replacement preserves the session and its relationships.

Startup restores the session registry and wakes the core, interrupted work, and sessions with unread internal input. Sleeping work stays asleep until a real event arrives; its first activation in the new runtime includes a startup observation. Stored callbacks remain eligible for admission and due wakeups deliver after restart. A host activity without a stored completion produces an interrupted observation with an unknown outcome; the runtime does not rerun its command. Current execution state describes the new runtime; earlier observations describe what was known then. Ivenna decides how to relate that history to the present and what to do next. The [startup contract](architecture.md#startup-and-interruption) defines what survives and what is rebuilt.

An interrupted action may already have affected the world before its result was retained. Persistence supplies historical evidence; it does not establish that effects occurred exactly once or that external state is unchanged. The runtime does not replay past tool calls. Automatic retry and reconnection after runtime failure remain undefined.

## Data ownership

The deployment user owns Ivenna's correspondence, retained working histories, artifacts, and autonomous memory, and chooses where they live. Keep these forms open to inspection, retention, and management within the user's deployment.

Correspondence, working history, and host artifacts have separate retention lifecycles. History remains available while any retained context needs it. History no longer needed for continuation follows the deployment user's retention policy. The [architecture guide](architecture.md#history-retention) explains how storage tracks that use; the [running guide](running.md#data-and-retention) describes retention and cleanup in the current deployment.

Diagnostics support troubleshooting and analysis. Keep them separate from the source material and handovers used for continuity.
