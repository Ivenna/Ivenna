# Corresponding with Ivenna

Send messages to Ivenna's configured email address (`MAIL_ADDRESS`) while [reception is open](running.md#service-status-and-reception). Each arrival enters Ivenna's core independently. Include enough context for Ivenna to understand the message and relate it to ongoing work.

## Sending a request

Use a correspondent account that can reach Ivenna. Send through your mail client, give the request a useful subject, and put the task and relevant context in its body. For example:

```text
To: <Ivenna's address>
Subject: French practice

Please remember that I am learning French and propose a practice plan.
```

Your mail client may confirm submission to its own server before delivery to Ivenna. A rejection while reception is closed can arrive later as a delivery result; see [reception readiness](running.md#service-status-and-reception).

Ivenna chooses when to communicate: it may send no message, one response, or several updates. Finishing internal work does not itself send mail. Read messages sent to you through your mail client; outgoing messages currently use the subject `Ivenna`.

Ivenna receives the subject and body as text. Plain-text bodies are preferred; HTML-only letters supply their HTML source. Longer content includes an excerpt and a reference to the full material, which Ivenna can retrieve when needed. The deployment retains these [source files](running.md#data-and-retention). Mail attachment intake is not implemented.

For a command to verify the supplied local environment, see [sending a development message](../dev/README.md#sending-a-message).

## Continuing correspondence

Describe what you are referring to, what changed, and what you want to happen next. For example:

```text
To: <Ivenna's address>
Subject: French practice schedule

About the French practice plan: use Tuesday and Saturday, and keep each
session to 20 minutes. Please retain the vocabulary goals we agreed on.
```

You can use your client's reply action or compose a new message. Ivenna relates messages through its retained understanding and memory; the mail client's thread grouping does not select an internal work session. A message cannot directly update a work focus that is already running.

## Ongoing work and memory

Ivenna can continue sustained work while receiving other messages and may consider several waiting messages together. Its focuses share the host and memory; each work focus returns its result to the focus that created it. See [work ownership](architecture.md#forks-and-work-ownership) for details.

Detailed work contexts can be released. Autonomous memory, retained correspondence, source files, and core handovers provide material for continued understanding. Processing leaves source letters in their existing folders. See [data and retention](running.md#data-and-retention) for storage and cleanup.

## After interruption

After a [restart](running.md#stopping-and-restarting) with the same deployment data, Ivenna rebuilds its understanding from the available core handover and recent correspondence. It continues reading [ordinary unprocessed mail](running.md#mail-intake); it does not restore individual work histories or interrupted execution.

An interrupted operation may already have changed files, memory, or mail. Inspect uncertain effects before asking Ivenna to repeat work, and include what is known in a new message. Automatic execution recovery remains undefined; see [startup and interruption](architecture.md#startup-and-interruption).
