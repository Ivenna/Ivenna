# Corresponding with Ivenna

Send messages to Ivenna while [reception is open](running.md#service-status-and-reception). Each arrival enters Ivenna's core independently. Include enough context for Ivenna to understand the message and relate it to ongoing work.

## Sending a request

Use a correspondent account in the same domain as Ivenna's configured address. For example, `operator@ivenna.test` can correspond with `ivenna@ivenna.test`. The message body carries the task and its context:

```text
To: <Ivenna's address>
Subject: French practice

Please remember that I am learning French and propose a practice plan.
```

Your mail service can report a delivery failure when Ivenna's [reception is closed](running.md#service-status-and-reception).

Ivenna sees who said what: your readable correspondent ID (`operator` in this example) and your message text. Every From address must map to a supported ID in the configured domain; otherwise the message is excluded from intake. To ask Ivenna to contact someone else, describe that request and their correspondent ID in the text. See [email addressing](communication.md#current-email-addressing) for supported addresses.

Ivenna chooses when to communicate: it may send no message, one response, or several updates. Finishing internal work does not itself send you mail. Read messages sent to you through your mail client; outgoing messages currently use the subject `Ivenna`.

Ivenna receives the complete subject and body as text. Plain-text bodies are preferred; HTML-only letters supply their HTML source. Each message must fit the [complete-request budget](running.md#configuration) with the instructions and context needed to process it. Oversized input that cannot fit after context compaction stops the runtime. Mail attachment intake is not implemented.

For a command to verify the supplied local environment, see [sending a development message](../dev/README.md#sending-a-message).

## Continuing correspondence

Follow-up messages enter the core as new observations. Ivenna relates them through retained understanding and memory; mail thread grouping does not select an internal work session. Identify the earlier request and describe the changes that should inform ongoing work. For example:

```text
To: <Ivenna's address>
Subject: French practice schedule

About the French practice plan: use Tuesday and Saturday, and keep each
session to 20 minutes. Please retain the vocabulary goals we agreed on.
```

## Ongoing work and memory

Ivenna can continue sustained work while receiving other messages and may consider several waiting messages together. It can schedule one-time observations for its own continued work or run host commands in the background, allowing work to resume without a new message from you. Processing depends on runtime availability and capacity; a scheduled time does not guarantee a reply at that time.

Continued work uses retained understanding and autonomous memory. Working histories can be condensed, so include relevant context in follow-up messages when detail may no longer be available.

Ivenna moves its incoming copy to Trash after saving the complete observation, before working on that input. This does not indicate that the task is finished. Its outgoing copies enter Trash after confirmed submission. The mail service controls their eventual deletion; your received copies stay in your own account. See [data and retention](running.md#data-and-retention) for storage and cleanup.

## After interruption

After a [restart](running.md#stopping-and-restarting), Ivenna restores saved understanding and can continue interrupted work without new correspondence. Scheduled observations and stored host results remain available for continued work.

Host processes are not restored, and old tool calls are not replayed. A background command without a stored result is reported as interrupted with an unknown outcome; it may already have changed files or other external state. Include any known changes when corresponding about interrupted work. A message can also appear again if interruption occurred between saving its observation and acknowledging the original. The [restart guide](running.md#stopping-and-restarting) explains these limits.
