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

Ivenna sees the sender's correspondent ID (`operator` in this example), subject, and body. The deployment operator registers the addresses Ivenna can write to, including yours if you expect a reply. To ask Ivenna to contact someone else, give their registered ID. See [outgoing registration](running.md#outgoing-correspondents).

For a command to verify the supplied local environment, see [sending a development message](../dev/README.md#sending-a-message).

### Sharing material to read

Put a short passage in the body of your letter. Ivenna skips email attachments. For longer material, describe what you want Ivenna to look at and give it a location it can choose to open.

- For a file already on Ivenna's host, give its absolute path, such as `/srv/notes.md`, or its file URI.
- For a screenshot, include a direct HTTP(S) link that Ivenna's model service can open.
- For an article, include its URL. Ivenna can retrieve the page when the deployment enables [web page access](running.md#web-page-access).

A letter that exceeds the model's input limits can stay pending and delay later mail. See the [operator's recovery steps](running.md#recovering-from-an-admission-failure).

## Continuing correspondence

Ivenna decides whether and when to write. You may receive one response, several updates, or none. See [how Ivenna sends email](communication.md#current-email-addressing).

Each follow-up reaches the core as a new observation, even within an email thread. Identify the earlier request and say what has changed.

```text
From: operator@ivenna.test
To: ivenna@ivenna.test
Subject: French practice schedule

About the French practice plan: use Tuesday and Saturday, and keep each
session to 20 minutes. Please retain the vocabulary goals we agreed on.
```

## Ongoing work and memory

Ivenna can pursue work between your messages and may read several waiting letters together. If you ask it to follow a project's releases, a listener can bring new versions to its attention. See [subscriptions](attention.md#subscriptions).

If Ivenna gives you a feed ID, use it to read the feed from the kernel host. A program on that host can relay selected messages to readers elsewhere. See [reading feeds](communication.md#reading-feeds) and [local programs](running.md#local-programs).

Ivenna can condense its working history and decide what to keep in memory. When following up, include any earlier detail the new request depends on. Keep your own mail copies if you need to retrieve or quote a letter later. See [autonomous memory](memory.md) and [mail retention](running.md#communication-copies).

## After interruption

During a temporary model outage, reception stays open while Ivenna retries the pending inference. If the kernel stops, reception closes and Ivenna can continue saved work after restart. See [service status and reception](running.md#service-status-and-reception).

If the kernel stopped after saving your letter but before acknowledging its copy, Ivenna can see the same letter again. You can also receive a reply even if Ivenna lost confirmation while sending it.

If you follow up, mention which replies reached you and any changes you observed, such as a file a command wrote before the interruption. See [what the kernel restores on restart](running.md#stopping-and-restarting).
