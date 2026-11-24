# Corresponding with Ivenna

Send your letter by email while reception is open. If reception is closed, your mail service may report a delivery failure. See [service status and reception](running.md#service-status-and-reception).

## Sending a request

Use an account in the same domain as Ivenna. Send through your mail service's authenticated submission path, using a From address authorized for that account.

```text
From: operator@ivenna.test
To: ivenna@ivenna.test
Subject: French practice

Please remember that I am learning French and propose a practice plan.
```

Ivenna sees who wrote, along with the subject and body. Before Ivenna can reply to you, the deployment operator must [register your mailbox for outgoing correspondence](running.md#outgoing-correspondents).

For a command to verify the supplied local environment, see [sending a development message](../dev/README.md#sending-a-message).

### Sharing material to read

Put a short passage in the body of your letter. Ivenna skips email attachments. For longer material, describe what you want Ivenna to look at and give it a location it can choose to open.

- For a file already on Ivenna's host, give its absolute path, such as `/srv/notes.md`, or its file URI.
- For a screenshot, include a direct HTTP(S) link that Ivenna's model service can open.
- For an article, include its URL. Ivenna can retrieve the page when the deployment enables [web page access](running.md#web-page-access).

A letter that cannot fit stays pending in the mailbox and can delay later mail. If the model service rejects a request after Ivenna saves your letter, the letter remains in working history for when reasoning resumes. See the [operator's recovery steps for a pending letter](running.md#recovering-from-an-admission-failure).

## Continuing correspondence

Ivenna decides whether and when to write. You may receive one response, several updates, or none. Its messages arrive under the subject `Ivenna`.

Each follow-up reaches the core as a new observation, even within an email thread. Identify the earlier request and say what has changed.

```text
From: operator@ivenna.test
To: ivenna@ivenna.test
Subject: French practice schedule

About the French practice plan: use Tuesday and Saturday, and keep each
session to 20 minutes. Please retain the vocabulary goals we agreed on.
```

## Ongoing work and memory

Ivenna can pursue work between your messages and may read several waiting letters together. If you ask it to follow a project's releases, a listener can bring new versions to its attention. See [how focuses coordinate and resume work](attention.md).

If Ivenna gives you a feed ID, use it to [read the feed](communication.md#reading-feeds) from Ivenna's host. To follow it from elsewhere, a program on that host can [relay messages](running.md#local-programs) to you.

Continued work uses retained understanding and [autonomous memory](memory.md). Ivenna chooses what to retain, revisit, and revise as its understanding develops. Include relevant context when following up, since Ivenna can condense its working history. To retrieve an earlier letter or quote its exact wording, keep your own mail copies. Ivenna's copies follow the [deployment's retention policy](running.md#communication-copies).

## After interruption

During a temporary model outage, Ivenna can still receive mail. It retries the pending decision and can continue when the service recovers. If the kernel stops, reception closes. On restart Ivenna restores saved history, pending wakeups, and stored results. It can continue interrupted work without a new letter. See [service status and reception](running.md#service-status-and-reception).

If the kernel stopped after saving your letter but before acknowledging its copy, Ivenna can see the same letter again. You can also receive a reply even if Ivenna lost confirmation while sending it.

The kernel does not resume or replay host commands. Ivenna receives a stored completion it was waiting for, or learns that the outcome is unknown. If you follow up, mention which replies reached you and any changes you observed, such as a file the command wrote before the interruption. See [stopping and restarting](running.md#stopping-and-restarting).
