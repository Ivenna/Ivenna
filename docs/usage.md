# Corresponding with Ivenna

Send requests to `MAIL_ADDRESS` after [starting the kernel](running.md#starting-the-kernel). Ivenna replies in the same mail thread, and later replies in that thread can continue the work.

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

Read replies through a JMAP-capable client or mail API using the operator account and the service's JMAP session URL. The [configuration reference](running.md#changing-configuration) lists that endpoint and its default. For another service, use its submission and client settings.

SMTP acceptance means the service accepted the request for delivery. Allow time for Ivenna to process it, including any tool work. A reply can provide a result, ask for clarification, or describe unfinished work.

Ivenna receives the subject and body as text. Plain-text bodies are preferred; HTML-only letters supply their HTML source. Longer content includes an excerpt and a reference to the full material, which Ivenna can retrieve when needed. The deployment retains these [source files](running.md#local-data). Mail attachment intake is not implemented.

## Continuing a conversation

Reply to Ivenna's letter in your mail client. A programmatic reply should keep the thread's subject, put the `Message-ID` of the Ivenna letter being answered in `In-Reply-To`, and append that identifier to its existing `References` chain. Replace the illustrative identifiers below with those from the correspondence:

```text
To: ivenna@ivenna.test
Subject: Re: French practice
Message-ID: <french-practice-2@example.local>
In-Reply-To: <ivenna-reply-being-answered@example.local>
References: <french-practice-1@example.local> <ivenna-reply-being-answered@example.local>

Use Tuesday and Saturday, and keep each session to 20 minutes.
```

Follow-up messages queue while work in the same thread continues. Independent threads can run concurrently. Reusing a subject alone does not reliably establish a reply relationship.

Reply in the same thread even after a clarification question or a gap in the work. Describe changes of intent and relevant new information in the message. Ivenna interprets them in the context of the correspondence and its ongoing work.

## Work sessions and handovers

Ivenna's core receives correspondence and handles brief requests directly. It can hand sustained work to a work session, which uses tools and replies directly to your thread. Work sessions can delegate subtasks and request findings. See the [architecture guide](architecture.md#forks-and-work-ownership) for how these sessions coordinate.

Work sessions can release detailed working context between inputs. Ivenna saves a handover summarizing its understanding and uses it with recent correspondence to continue later. It also summarizes growing contexts. Processing leaves source letters in their existing folders.

Later continuation depends on retained handovers, correspondence, and referenced files. See [local data](running.md#local-data) for storage and cleanup, and [bounded model context](architecture.md#bounded-model-context) for summary and reconstruction limits.

## After interruption

After a [restart](running.md#stopping-and-restarting) with the same mailbox, artifacts, and memory workspace, Ivenna rebuilds its understanding from handovers and recent correspondence. It reads [pending mail](running.md#mail-intake) and can continue existing threads. Reply in the thread to explain what is known and what should happen next.

An interrupted operation may already have changed files, memory, or mail; a lost reply-submission response can leave delivery uncertain. Inspect uncertain effects before asking Ivenna to repeat work. Restarting does not resume model requests or tool calls from their interruption point. Detailed execution recovery remains undefined; see [startup and interruption](architecture.md#startup-and-interruption).
