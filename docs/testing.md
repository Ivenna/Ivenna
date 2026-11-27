# Testing

Tests catch consequential regressions as Ivenna's interfaces evolve. The [development guide](development.md) explains how validation fits into a change.

## Choosing tests

Start with the intended behavior and how its failure would be noticed. Check whether an existing test exercises that outcome. When the design changes, update tests that still describe the intended behavior and remove outdated expectations. A small, reversible change may need only review and a build.

Add a regression test for an implemented behavior when its failure would be costly or hard to notice. Keep it with the component that owns the behavior. Use existing test machinery and exercise an observable result with the smallest fixture that reaches it.

## Running checks

Use the Zig version in [`.zig-version`](../.zig-version). Check tracked Zig files, build Ivenna, and run the Zig tests from the repository root.

```sh
git ls-files -z '*.zig' '*.zig.zon' | xargs -0 zig fmt --check
zig build
zig build test
```

The root test step includes the registered library suites and the CLI suite. To run the CLI suite by itself, run `zig build test` from `apps/ivenna`. Library roots include internal test files through `test` blocks in `src/root.zig`. To add a package suite, register it in the root build and dependency manifest. See the [root build](../build.zig), [application build](../apps/ivenna/build.zig), and [dependency manifest](../build.zig.zon).

For the [memory protocol tests](../apps/memory/tests.nu), install Nushell at the version used in the memory [Containerfile](../apps/memory/Containerfile). These tests also use the standard `ln` command:

```sh
nu --no-config-file --no-history apps/memory/tests.nu
```

The script uses Nushell's standard assertions, sends JSON requests directly to the handler in temporary workspaces, and removes those workspaces afterward. It uses no configuration or data from the development instance. Keep CI's Nushell version aligned with the Containerfile when upgrading it.

## Automated coverage

The [CI workflow](../.github/workflows/ci.yml) invokes these checks on Linux. The suites use local fixtures and run without deployed services or model credentials.

### Test boundaries

- **Command line and channels.** Process tests check the session commands and publish subscription reports while the kernel is stopped. Channel tests check one message per waiting read, closure with an already matched message, and output pipes closing during a wait or write. [CLI tests](../apps/ivenna/src/cli_test.zig)
- **Instance state.** Subscription tests cover replay after admission, delivery of reports queued before withdrawal, and recognition of an open listener until its last session closes. Format upgrade tests check that existing data survives the switch. [Subscription store](../packages/instance_state/src/subscriptions.zig) · [Instance database](../packages/instance_state/src/database.zig)
- **Focus execution.** Registry fixtures cover routing, report admission, and repeated receipts. A kernel test checks that reception closes when the inbox cannot acknowledge a new copy of a consumed callback. Restart tests check which observation source goes first and which measurement drives the first soft-compaction decision. [Kernel tests](../packages/agent/src/kernel.zig) · [Session registry tests](../packages/agent/src/sessions.zig)
- **Checkpoint recovery.** Fixtures exercise save failures before publication and after a write reaches storage. They check that a failed save blocks subsequent writes and maintenance and that restart restores the selected state, including tool results, channel and activity registrations, wakeups, and activity reports. Startup tests verify republication of an unchanged checkpoint with its paired subscription catalog. Separate coverage follows a channel through the end of its opening activity, restart, and close. [Kernel tests](../packages/agent/src/kernel.zig) · [Session registry tests](../packages/agent/src/sessions.zig)
- **Handovers and working history.** Context tests check that sampled registrations accompany the summary. Kernel tests check the next ordinary request for a new activity's original assignment after compaction and one copy of an admitted observation after restart. History tests exercise read batching and fork records written in earlier formats. The fork writes file IDs and Base64 images, and both sessions reload with the original IDs and image bytes. [Context tests](../packages/agent/src/context.zig) · [Kernel tests](../packages/agent/src/kernel.zig) · [History tests](../packages/agent/src/history.zig)
- **Mail.** A local JMAP server verifies recipient lookup before draft creation and the address stored on the draft. Connection failures exercise mailbox read recovery, uncertain submission, and confirmation of callback and history writes. Checkpoint tests cover size rejection, an unconfirmed preparation that prevents publication, keyword readback by message ID after an unconfirmed publication, and startup selection across pages of prepared, published, and earlier-format checkpoints. Retention tests verify which messages move to Trash. [Email transport](../packages/email/src/email_transport.zig) · [Checkpoint tests](../packages/email/src/history.zig) · [Retention tests](../packages/email/src/mail.zig)
- **Model requests.** Configuration and kernel tests cover reasoning effort. A kernel test checks that new observations take priority over connection status within the request budget. HTTP fixtures check request encoding and limits, compare uploaded bytes with their source, and confirm inference receives returned file IDs in order. Upload cases also cover rejection and loss of confirmation. [Configuration test](../apps/ivenna/src/cli_test.zig) · [Kernel tests](../packages/agent/src/kernel.zig) · [Responses tests](../packages/responses/src/provider_test.zig)
- **Web resources.** A fixture verifies that two focuses can read one page snapshot from a single fetch. [Web reader tests](../packages/resources/src/web_test.zig)

The email, Responses, and web reader tests check that canceling a stalled HTTP exchange closes the connection. The local server checks for further request bytes and open connections. Measuring bytes received over TLS requires exercising the request writer against a local HTTPS server. [Local server](../tests/http.zig) · [Model transport](architecture.md#model-transport)

## Validating with running services

Use the [local environment](../dev/README.md) to validate restart and communication through the configured services.

Use the [channel walkthrough](../dev/README.md#trying-a-channel) to check send feedback, successive reads, and stream exit on close.

To check channel recovery, have an activity open a channel and give you its complete ID before it ends. Receive one message with an [independent receiver](running.md#channel-receivers), then [restart the kernel](running.md#stopping-and-restarting). Reconnect with the same ID, send a different message, and verify that it reaches the receiver. Close the channel when done.

Use the [subscription walkthrough](../dev/README.md#trying-a-subscription-listener) to check publication through a listener session and delivery after a restart.

### Evaluating compaction

Compare the focus's saved epoch before and after a summary attempt. In a new epoch, look for the handover, any pending work carried forward, and the observations admitted with it. For an activity that compacted its inherited history on opening, check that its original assignment follows the handover. If the epoch stays the same, check stderr for the reason. See [context budgets](running.md#context-budgets) and [persistent working history](architecture.md#persistent-working-history).

Compare the sample with the channel and subscription registrations active at its `observed_at` time and with the original scheduled times of pending wakeups. Check that later callbacks and reports reach the focus that arranged them. See [sampled state](input.md#sampled-state).

### Evaluating continuity across interruptions

Follow an encounter whose meaning depends on an earlier one. For example, a correspondent mentions learning French to speak with their grandmother. After a handover or restart, they say they now look forward to calling her. Look at Ivenna's reply or next action for evidence that it connects this news to the earlier conversation. See [a self in the world](design.md#a-self-in-the-world).

To check retained images, capture the inference request after a tool opens an image, then replace the source and restart with the same mailbox and instance database. While the exchange is still in working history, compare the decoded image bytes from the request after restart with the original bytes. See [tool content retention](content.md#context-and-continuity).

### Evaluating context disclosure

Use a fixture or capture an inference request from a running instance. Compare the IDs in `current` with the sessions open when the request was assembled. Include a receiver between reads and a subscription whose last listener has closed to check the two lifetimes. See [channel receivers and subscription listeners](input.md#channel-receivers-and-subscription-listeners).

To judge whether an observation helps, keep the model and starting history fixed when comparing requests that differ in what they show. Try one case where the observation explains new work and one where it is incidental. Compare Ivenna's interpretation or next action. Record request size separately. See [context and continuity](design.md#context-and-continuity).
