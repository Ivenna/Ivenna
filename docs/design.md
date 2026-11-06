# Design intent

Ivenna is a body for an LLM soul: a runtime through which the model can act, perceive results, and organize memory. The project explores how persistent interaction and autonomous memory can sustain a sense of self over time. Ongoing communication and autonomous activity guide its interaction design.

## Capabilities and acquired knowledge

Core interfaces expose the body's capabilities to a model with broad prior knowledge, like a knowledgeable person encountering the tools at hand. They should make available actions discoverable and their effects understandable.

Program choices and general tool use draw on the model's prior knowledge and what it learns through interaction. Its identity, preferences, working methods, and memory organization can develop with that experience.

## Runtime availability

Communication and autonomous memory are required for Ivenna to operate. The runtime starts with both available; infrastructure failures in either end the runtime and its concurrent work. Errors propagated by model and session execution also end the runtime. Defined tool outcomes, such as a missing memory entry, a capacity limit, or a command's nonzero exit, remain observations for the model to understand.

Ivenna exposes its health and whether reception is open. Senders must expect reception to close when Ivenna is starting, stopping, or unavailable. The receiving boundary checks that state before accepting new messages. Retry and queuing by a sender belong to that sender; automatic offline reception and recovery are outside the current design.

## Model-facing descriptions and results

Tool descriptions explain how to choose and invoke an operation and interpret its result. Model input identifies each observation's source, content, and context, with the runtime state needed to understand ongoing work. Results convey the state and outcome of the particular invocation.

Keep these interfaces concise and leave room for the model's knowledge and judgment. Detailed field references and implementation explanations belong in developer documentation unless they affect how the interface is used or interpreted.

Keep task text and message text free-form. Working history preserves understanding for continuation; current execution state and summary instructions apply to the inference that uses them. The system prompt explains their meaning and response scope; the [input contract](input.md) defines their structure.

Tool results can combine text, media, and information about an operation's outcome and source. Classifying or interpreting one source preserves the other observations in the result. When a provider or budget cannot carry content, retain its source information and describe the omission.

## Communication with people and programs

People and programs communicate with Ivenna through messages. Each arrival enters the core as an observation of who said what. An observation does not imply that the words were addressed specifically to Ivenna or require a response. Ivenna relates it to its ongoing understanding and work.

The communication interface supplies received text, the IDs of participants it came from, and observation time. Retained model and tool exchanges preserve Ivenna's outgoing communication with its chosen recipient IDs. Correspondent IDs link observations with explicit communication actions. Understanding correspondents and their relationships to Ivenna can inform coordination. Policies based on correspondent IDs, including any participant whitelist or scheduling distinctions, remain undecided.

Ivenna explicitly chooses whether to send a message, to whom, and what it says through `send_message`. An activation can send zero, one, or several messages. Final model text supplies an internal result in the core or a report to a work session's parent; outgoing communication requires an explicit send. The [communication guide](communication.md) describes the interface and its current implementation.

## Internal work and state

Work is defined by a task and the understanding needed to continue it. A session owns a working context and a queue. An activation handles a bounded group of already queued inputs, assignments, or reports together through model and tool rounds. It ends with a final response or a fork that passes the group's work to a child. Events arriving during an activation remain queued for later processing.

Execution state coordinates ongoing work in process memory. Retained working contexts persist independently of execution, while communication records which correspondence has been processed. These forms have their own responsibilities and lifecycles.

Activation completion, task completion, context release, and data retention have separate lifecycles. A broader task can remain open after an activation ends.

## Core and concurrent attention

One core session coordinates Ivenna throughout the kernel's lifetime. It handles a queue of observations and keeps its turns focused on reception and coordination. It can send a brief message directly; sustained work moves to separate sessions so the core can receive further input. Later messages still enter the core.

Forking is an explicit model decision available to core and work sessions alike. It passes the whole activation's work to another focus of Ivenna's attention with the complete retained working context, including any earlier handover. The caller's activation ends and it returns to its queue; the child starts an activation for its assignment.

A work session's final text returns one combined result for that activation to the session that forked it. The report remains queued until that parent can process it, potentially alongside other queued events, in a later activation. Nested work returns through each creating parent, preserving the relationship between the work and its result.

After a fork, the histories grow independently. The core retains its reception and coordination history; execution detail accumulates in the session carrying out the work. This keeps the core's context useful for further coordination and forks.

The runtime bounds retained contexts and concurrent work globally and preserves scheduling opportunities for the core. Forking returns the core to its queue without waiting for the work session. A single LLM session still processes one request at a time; core responsiveness depends on keeping coordination turns short as well as scheduling them promptly.

These contexts share a body: files, memory, communication, and host processes. Sessions account for effects another session may already have produced. Fork assignments and direct-parent reports organize work from the core through its descendants.

A work session keeps its context while its work or descendants still need it. The context can be released after completion while the broader task awaits further input. The [architecture guide](architecture.md#activation-completion-and-context-release) describes these lifetimes and how child results are retained until processing.

Peer assignments, steering retained work, and parallel subtasks within one activation remain undecided. Session identities and parent relationships survive with their retained contexts. Unread internal assignments and reports are retained until admission; activation ownership lasts for one process.

## Context and continuity

Working contexts retain observations, complete model output, and tool results. The core and every still-retained work context preserve that understanding across runtime interruption. Working history has a lifetime independent of host execution artifacts.

Limits cover the complete model request, including instructions, tool definitions, observations, and tool results, as well as the generated response. Each limit states what it measures; byte counts and model tokens are separate units.

When context needs to be shortened, the kernel asks the model for a handover. The replacement context should preserve commitments, relevant uncertainty, completed effects, and correspondent IDs and relationships needed for continued understanding. The handover remains free-form text.

Startup restores saved working histories and session relationships, then gives each retained session a fresh activation with a startup observation. Current execution state describes the new runtime; earlier observations describe what was known then. This preserves understanding while acknowledging the interruption. Ivenna decides how to relate that history to the present and what to do next. The [startup contract](architecture.md#startup-and-interruption) defines what survives and what is rebuilt.

An interrupted action may already have affected the world before its result was retained. Persistence supplies historical evidence; it does not establish that effects occurred exactly once or that external state is unchanged. The runtime does not replay past tool calls. Automatic retry and reconnection after runtime failure remain undefined.

## Data ownership

The deployment user owns Ivenna's correspondence, retained working histories, artifacts, and autonomous memory, and chooses where they live. Keep these forms open to inspection, retention, and management within the user's deployment. Storage implementations preserve their distinct ownership and retention needs.

Diagnostics support troubleshooting and analysis. Keep them separate from the source material and handovers used for continuity.

## Reference designs

These references inform context, scheduling, and handoff mechanisms within Ivenna's own design intent.

[OpenAI Agents SDK handoffs](https://developers.openai.com/api/docs/guides/agents/orchestration#use-handoffs-for-delegated-ownership) provide a reference for transferring responsibility. [Codex thread forks](https://learn.chatgpt.com/docs/app-server#start-or-resume-a-thread) provide a reference for continuing stored history in a separate context. Ivenna uses context inheritance and explicit work ownership within one body.

[pi's sessions and context](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/sessions.md) distinguish stored history from the active branch supplied to a model request. Its [agent interface](https://github.com/earendil-works/pi/blob/main/packages/agent/README.md) provides a reference for queued follow-up input.
