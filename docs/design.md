# Design intent

Ivenna is a body for an LLM soul: a runtime through which the model can act, perceive results, and organize memory. The project explores how persistent interaction and autonomous memory can sustain a sense of self over time.

## Capabilities and acquired knowledge

Core interfaces expose the body's capabilities to a model with broad prior knowledge, like a knowledgeable person encountering the tools at hand. They should make available actions discoverable and their effects understandable.

Program choices and general tool use draw on the model's prior knowledge and what it learns through interaction. Its identity, preferences, working methods, and memory organization can develop with that experience.

## Model-facing descriptions and results

Tool descriptions explain what an operation does, how to invoke it, and any interface-specific behavior needed before use or to interpret its results. Include enough information for reliable use; description length follows that need.

Results convey the state and outcome of the particular invocation. Implementation explanations belong in developer documentation unless they affect how the interface is used or interpreted.

## Local data and ownership

The deployment user owns Ivenna's data and chooses where it lives. Keep structured runtime state in embedded SQLite, and keep artifacts and autonomous memory as files. These forms should support inspecting, retaining, and managing the data within the user's deployment.

Session state and history support continued execution. Observation data serves diagnosis and analysis, with its own retention and export lifecycle. A diagnostic record's lifetime should not determine whether a session can resume. Detailed observation interfaces and storage formats can develop as their uses become clear.
