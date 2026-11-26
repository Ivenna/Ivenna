# Corresponding with Ivenna

Send your letter by email while reception is open. If reception is closed, your mail service may report a delivery failure. See [service status and reception](running.md#service-status-and-reception).

## Sending a letter

Send through your mail service's authenticated submission path. Use a From address in Ivenna's mail domain that your account is authorized to use. If you expect a reply, ask the deployment operator to register your address for outgoing mail. See [outgoing registration](running.md#outgoing-correspondents).

```text
From: operator@ivenna.test
To: ivenna@ivenna.test
Subject: Swifts at the library

You wondered last spring whether the swifts still nest near the library.
I saw them disappear under the east eaves this morning.
```

Ivenna sees your correspondent ID (`operator` in this example), subject, and body. To ask Ivenna to contact someone else, give their registered ID. See [email addresses and IDs](communication.md#current-email-addressing).

For a command to verify the supplied local environment, see [sending a development message](../dev/README.md#sending-a-message).

### Sharing material to read

Put a short passage in the body of your letter. Ivenna skips email attachments. For longer material, describe what you want Ivenna to look at and give it a location it can choose to open.

- For a file already on Ivenna's host, give its absolute path, such as `/srv/notes.md`, or its file URI.
- For a screenshot, include a direct HTTP(S) image URL that the model service can reach. See [remote images](resources.md#remote-images).
- For an article, include its URL. Ivenna can retrieve the page when the deployment enables [web page access](running.md#web-page-access).

A letter that exceeds the model's input limits can stay pending and delay later mail. See the [operator's recovery steps](running.md#recovering-from-an-admission-failure).

## Continuing correspondence

Ivenna decides whether and when to write. You may receive one response, several updates, or none. See [how Ivenna sends email](communication.md#current-email-addressing).

Each follow-up reaches the core as a new observation, even within an email thread. Name the earlier subject or exchange when it helps make the follow-up clear.

```text
From: operator@ivenna.test
To: ivenna@ivenna.test
Subject: Swifts at the library, a correction

I went back at dusk. The birds were going under the eaves of the house
next door. The library itself has scaffolding up now.
```

## Ongoing work and memory

Ivenna may read several waiting letters together. It can keep following an interest between letters. If it chooses to follow a project's releases, a listener can bring new versions to its attention. See [subscriptions](attention.md#subscriptions).

Ivenna can condense its working history and decide what to keep in memory. Keep your own mail copies if you need to retrieve or quote a letter later. See [autonomous memory](memory.md) and [mail retention](running.md#communication-copies).

## After interruption

During a temporary model outage, reception stays open while Ivenna retries the pending inference. If the kernel stops, reception closes and Ivenna can continue saved work after restart. See [service status and reception](running.md#service-status-and-reception).

If the kernel stopped after saving your letter but before acknowledging its copy, Ivenna can see the same letter again. You can also receive a reply even if Ivenna lost confirmation while sending it.

If you follow up, mention which replies reached you and any changes you observed, such as a file a command wrote before the interruption. See [what the kernel restores on restart](running.md#stopping-and-restarting).
