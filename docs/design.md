# Design intent

Ivenna is a body for an LLM soul: a runtime through which the model can act, perceive results, and organize memory. The project explores how persistent interaction and autonomous memory can sustain a sense of self over time. Ongoing communication and autonomous activity guide its interaction design.

## Capabilities and acquired knowledge

Core interfaces expose the body's capabilities to a model with broad prior knowledge, like a knowledgeable person encountering the tools at hand. They should make available actions discoverable and their effects understandable.

Program choices and general tool use draw on the model's prior knowledge and what it learns through interaction. Its identity, preferences, working methods, and memory organization can develop with that experience.

## Runtime availability

Communication and autonomous memory are required for Ivenna to operate. The runtime starts with both available; infrastructure failures in either end the runtime and its concurrent work. Errors propagated by model and session execution also end the runtime. Defined tool outcomes, such as a missing memory entry, a capacity limit, or a command's nonzero exit, remain observations for the model to understand.

## Model-facing descriptions and results

Tool descriptions explain how to choose and invoke an operation and interpret its result. Model input identifies each observation's source, content, and context, with the runtime state needed to understand ongoing work. Results convey the state and outcome of the particular invocation.

Keep these interfaces concise and leave room for the model's knowledge and judgment. Detailed field references and implementation explanations belong in developer documentation unless they affect how the interface is used or interpreted.

Model input uses a common session envelope and distinct observation forms for incoming content, assignments, findings, handovers, current state, and summary requests. The system prompt describes their meaning and response scope. Task text and source material remain free-form within those fields, with optional provenance, context, and references to original source details.

Tool results can combine text, media, and information about an operation's outcome and source. Classifying or interpreting one source preserves the other observations in the result. When a provider or budget cannot carry content, retain its source information and describe the omission.

## External communication

People and programs communicate with Ivenna through email. This boundary receives material, identifies correspondents, preserves reply relationships, and submits answers to the intended audience. Email provides asynchronous correspondence through existing clients and services.

The email boundary supplies content and source information to the input protocol. Subjects, bodies, and correspondent identities provide material for understanding a request. The boundary owns the headers and delivery records used to submit the model's answer. Reply text carries that answer without appended session state or housekeeping prose.

Requests, changes of intent, and other correspondence are content for Ivenna to understand in context. The communication interface preserves that content and its intended audience; Ivenna decides how to respond and relate it to ongoing work.

## Internal work and state

Work is defined by a task and the understanding needed to continue it. A session owns a working context and a queue. An activation handles one input or assignment and can span many model and tool rounds. Ordinary arrivals enter the queue for later processing.

Execution state coordinates ongoing work in process memory. Mail storage records which correspondence has been processed and retains handovers for continuation. External correspondence and internal state have their own responsibilities and lifecycles within the shared mail service.

A response without tool calls ends the current activation while the broader task may remain open. Activation completion, task completion, context release, and mail retention have separate lifecycles.

## Core and concurrent attention

One core session coordinates Ivenna throughout the kernel's lifetime. It handles a queue of observations and keeps its turns focused on reception, assignment, and coordination. It can answer a brief request directly; sustained work moves to separate sessions so the core can receive further input.

Forking is an explicit model decision available to core and work sessions alike. A fork is another focus of Ivenna's attention, continuing from the caller's complete current working context, including any earlier handover. It receives an assignment, any source references, and current runtime state. A handoff transfers the active work and responsibility for its result. A subtask can return requested findings to its parent. Work sessions can reply directly to the people they are responsible for answering.

After a fork, the histories grow independently. The core retains its reception and coordination history; execution detail accumulates in the session carrying out the work. This keeps the core's context useful for further coordination and forks.

The runtime bounds retained contexts and concurrent work globally and preserves scheduling opportunities for the core. Handoffs return the core to its queue without waiting for the work session. A single LLM session still processes one request at a time; core responsiveness depends on keeping coordination turns short as well as scheduling them promptly.

These contexts share a body: files, memory, communication, and host processes. Sessions account for effects another session may already have produced and exchange findings relevant to their work.

A work session's context lifetime depends on the work, input, and children it still owns. A context can be released while the broader task awaits more input.

## Context and continuity

Runtime transcripts hold the detail needed for model and tool execution. They have bounded lifetimes and sizes. Bound the complete model request, including instructions, tool definitions, observations, and tool results, and bound the generated response. State what each limit measures; a byte count does not establish token usage.

When context needs to be shortened, the kernel asks the model for a handover. The replacement context should preserve commitments, relevant uncertainty, completed effects, and source references needed for continued work. Handovers can be retained in internal state for later recall. Working context can also be compacted in process memory; durable recovery for independent internal work remains undecided.

After a restart or a conversation's reopening, Ivenna rebuilds its working understanding from communication and handovers. This sustains continuity without restoring every intermediate model or tool state. An interrupted action may already have affected the world, so uncertain outcomes need inspection before repetition.

Automatic retry, reconnection, and execution resumption after runtime failure remain undefined.

## Local data and ownership

The deployment user owns Ivenna's mailbox, artifacts, and autonomous memory, and chooses where they live. External correspondence and internal state records both use mail storage, with their ownership and retention kept distinct. Artifacts and autonomous memory remain files. Keep these forms open to inspection, retention, and management within the user's deployment.

Diagnostic records support troubleshooting and analysis, with their own retention and export lifecycle. They are separate from the source material and handovers used for continuity.

## Reference designs

These references inform context, scheduling, and handoff mechanisms within Ivenna's own design intent.

[OpenAI Agents SDK handoffs](https://developers.openai.com/api/docs/guides/agents/orchestration#use-handoffs-for-delegated-ownership) provide a reference for transferring conversation responsibility. [Codex thread forks](https://learn.chatgpt.com/docs/app-server#start-or-resume-a-thread) provide a reference for continuing stored history in a separate thread. Ivenna's handoff combines context inheritance with communication responsibility.

[pi's sessions and context](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/sessions.md) distinguish stored history from the active branch supplied to a model request. Its [agent interface](https://github.com/earendil-works/pi/blob/main/packages/agent/README.md) provides a reference for queued follow-up input.
