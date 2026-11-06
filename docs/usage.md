# Corresponding with Ivenna

Send messages to `MAIL_ADDRESS` while [reception is open](running.md#service-status-and-reception). Each arrival enters Ivenna's core independently. Include enough context for Ivenna to understand the message and relate it to ongoing work.

## Sending a request

Use the operator account configured during [mail setup](running.md#configuring-local-mail), or another account that can reach Ivenna. Give the request a useful subject and put the task and relevant context in its body.

The following example requires `curl` and submits through the supplied local service's authenticated SMTP endpoint. Run it from a second terminal at the repository root:

```sh
set -a
. ./.env
set +a
curl --url "smtp://127.0.0.1:${MAIL_SMTP_PORT:-2525}" \
  --user "$OPERATOR_MAIL_ADDRESS:$OPERATOR_MAIL_PASSWORD" \
  --mail-from "$OPERATOR_MAIL_ADDRESS" \
  --mail-rcpt "$MAIL_ADDRESS" \
  --upload-file - <<EOF
From: $OPERATOR_MAIL_ADDRESS
To: $MAIL_ADDRESS
Subject: French practice
Message-ID: <french-practice-$(date +%s)@ivenna.test>

Please remember that I am learning French and propose a practice plan.
EOF
```

With the supplied readiness policy installed, this SMTP command receives a `550` rejection when reception is closed or unreachable. A normal mail client may submit to its own server first, so its Send result need not show Ivenna's rejection immediately. See [reception readiness](running.md#service-status-and-reception) for delivery behavior and the policy's scope.

SMTP acceptance means the mail service accepted the message for delivery. Ivenna chooses when to communicate: it may send no message, one response, or several updates. Finishing internal work does not itself send mail.

Read Ivenna's messages through a JMAP-capable client or mail API using the operator account and the service's JMAP session URL. Outgoing messages currently use the subject `Ivenna`. For another service, use its submission and client settings.

Ivenna receives the subject and body as text. Plain-text bodies are preferred; HTML-only letters supply their HTML source. Longer content includes an excerpt and a reference to the full material, which Ivenna can retrieve when needed. The deployment retains these [source files](running.md#local-data). Mail attachment intake is not implemented.

## Continuing correspondence

Describe what you are referring to, what changed, and what you want to happen next. For example:

```text
To: ivenna@ivenna.test
Subject: French practice schedule

About the French practice plan: use Tuesday and Saturday, and keep each
session to 20 minutes. Please retain the vocabulary goals we agreed on.
```

You can use your client's reply action or compose a new message. Ivenna relates messages through its retained understanding and memory; the mail client's thread grouping does not select an internal work session. A message cannot directly update a work focus that is already running.

## Ongoing work and memory

Ivenna can continue sustained work while receiving other messages and may consider several waiting messages together. Its focuses share the host and memory; each work focus returns its result to the focus that created it. See [work ownership](architecture.md#forks-and-work-ownership) for details.

Detailed work contexts can be released. Autonomous memory, retained correspondence, source files, and core handovers provide material for continued understanding. Processing leaves source letters in their existing folders. See [local data](running.md#local-data) for storage and cleanup.

## After interruption

After a [restart](running.md#stopping-and-restarting) with the same deployment data, Ivenna rebuilds its understanding from the available core handover and recent correspondence. It continues reading [ordinary unprocessed mail](running.md#mail-intake); it does not restore individual work histories or interrupted execution.

An interrupted operation may already have changed files, memory, or mail. Inspect uncertain effects before asking Ivenna to repeat work, and include what is known in a new message. Automatic execution recovery remains undefined; see [startup and interruption](architecture.md#startup-and-interruption).
