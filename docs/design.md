# Design intent

Ivenna is a body for an LLM soul: a runtime through which the model can act, perceive results, and organize memory. The project explores how persistent interaction and autonomous memory can sustain a sense of self over time.

## Capabilities and acquired knowledge

Core interfaces expose the body's capabilities to a model with broad prior knowledge, like a knowledgeable person encountering the tools at hand. They should make available actions discoverable and their effects understandable.

Program choices and general tool use draw on the model's prior knowledge and what it learns through interaction. Its identity, preferences, working methods, and memory organization can develop with that experience.

## Model-facing descriptions and results

Tool descriptions explain how to choose and invoke an operation and interpret its result. Model input identifies each observation's source, content, and context, with the runtime state needed to understand ongoing work. Results convey the state and outcome of the particular invocation.

Keep these interfaces concise and leave room for the model's knowledge and judgment. Detailed field references and implementation explanations belong in developer documentation unless they affect how the interface is used or interpreted.

Model input has a common session envelope and a closed set of observation variants, each with its own payload. Incoming content carries optional provenance and context; assignments, findings, handovers, current state, and summary requests have distinct forms. The system prompt describes their meaning and response scope, while task text and source material remain open within those fields. Original source details are available by reference when relevant to the work.

Tool results can combine text, media, and information about an operation's outcome and source. Classifying or interpreting one source preserves the other observations in the result. When a provider or budget cannot carry content, retain its source information and describe the omission.

## External communication

People and programs communicate with Ivenna through email. This boundary receives material, identifies correspondents, preserves reply relationships, and submits answers to the intended audience. Email provides asynchronous correspondence through existing clients and services.

The email boundary supplies content and source information to the input protocol. Subjects, bodies, and correspondent identities provide material for understanding a request. The boundary owns the headers and delivery records used to submit the model's answer. Reply text carries that answer without appended session state or housekeeping prose.

## Internal work and state

Work is defined by a task and the understanding needed to continue it. A session owns a working context and a queue. An activation handles one input or assignment and can span many model and tool rounds. Ordinary arrival supplies another input; it does not interrupt ongoing work or create a fork. Deliberate steering needs an explicit interface.

Internal state makes input eligible, controls activations, and retains understanding for continuation. Mail records and explicit flags provide inspectable state for this asynchronous work. State keys and transitions belong to the execution design, independently of external reply relationships.

External correspondence and internal state are separate uses of mail, each with its own responsibilities and lifecycle. They can share a service and low-level operations. The communication boundary owns replies; internal state owns work controls and durable handovers.

A response without tool calls ends the current activation while the broader task may remain open. Reply submission, internal findings, state acknowledgment, handover storage, and context release have distinct outcomes and lifetimes. Mail retention manages accumulated records separately from working-context lifetime.

## Core and concurrent attention

One core session coordinates Ivenna throughout the kernel's lifetime. It handles a queue of observations and keeps its turns focused on reception, assignment, and coordination. It can answer a brief request directly; sustained work moves to separate sessions so the core can receive further input.

Forking is an explicit model decision available to core and work sessions alike. A fork is another focus of Ivenna's attention, continuing from the caller's complete current working context, including any earlier handover. It receives an assignment, any source references, and current runtime state. A handoff transfers the active work, reply target, and source control when present. A subtask can return requested findings to its parent. Work sessions can reply directly to the people they are responsible for answering.

After a fork, the histories grow independently. The core retains its reception and coordination history; execution detail accumulates in the session carrying out the work. This keeps the core's context useful for further coordination and forks.

The runtime bounds retained contexts and concurrent work globally and preserves scheduling opportunities for the core. Handoffs return the core to its queue without waiting for the work session. A single LLM session still processes one request at a time; core responsiveness depends on keeping coordination turns short as well as scheduling them promptly.

These contexts share a body and its effects on the world. Forking reasoning history does not isolate files, memory, communication, or host processes. Sessions account for effects another session may already have produced and exchange findings relevant to their work.

A work session's context lifetime depends on the work, input, and children it still owns. A context can be released while the broader task awaits more input. Retention of external correspondence and internal state records follows their own lifecycles.

## Context and continuity

Runtime transcripts hold the detail needed for model and tool execution. They have bounded lifetimes and sizes. Bound the complete model request, including instructions, tool definitions, observations, and tool results, and bound the generated response. State what each limit measures; a byte count does not establish token usage.

When context needs to be shortened, the kernel asks the model for a handover. The replacement context should preserve commitments, relevant uncertainty, completed effects, and source references needed for continued work. Internal state persists handovers under stable keys. Work without a persistent key can compact in memory; durable recovery for independently created internal work remains to be defined. Any retained transcript tail must contain complete model and tool exchanges.

After a restart or a conversation's reopening, Ivenna rebuilds its working understanding from communication and handovers. This sustains continuity without restoring every intermediate model or tool state. An interrupted action may already have affected the world, so uncertain outcomes need inspection before repetition.

## Local data and ownership

The deployment user owns Ivenna's mailbox, artifacts, and autonomous memory, and chooses where they live. External correspondence and internal state records both use mail storage, with their ownership and retention kept distinct. Artifacts and autonomous memory remain files. Keep these forms open to inspection, retention, and management within the user's deployment.

Diagnostic records support troubleshooting and analysis, with their own retention and export lifecycle. They are separate from the source material and handovers used for continuity. Dedicated diagnostic interfaces and storage formats can develop as their uses become clear.

## Reference designs

[OpenAI Agents SDK handoffs](https://developers.openai.com/api/docs/guides/agents/orchestration#use-handoffs-for-delegated-ownership) provide a reference for transferring conversation responsibility. [Codex thread forks](https://learn.chatgpt.com/docs/app-server#start-or-resume-a-thread) provide a reference for continuing stored history in a separate thread. Ivenna's handoff combines context inheritance with communication responsibility.

[pi's sessions and context](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/sessions.md) distinguish stored history from the active branch supplied to a model request. Its [agent interface](https://github.com/earendil-works/pi/blob/main/packages/agent/README.md) also distinguishes steering from queued follow-up input.
