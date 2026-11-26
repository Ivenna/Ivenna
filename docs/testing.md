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

- **Command line and channels.** Process tests exercise help and argument errors without deployment settings, subscription publication with the kernel stopped, and single-read timeouts. The channel tests check one message per waiting request and that closing a channel releases the connection while preserving a matched message. Pipeline tests cover a reader closing after one flushed message and during a blocked write. [CLI tests](../apps/ivenna/src/cli_test.zig)
- **Instance state.** Two subscription connections exercise cursor conflicts, retries after acknowledgement, and whether queued reports retain their destination after withdrawal. [Subscription store](../packages/instance_state/src/subscriptions.zig)
- **Focus execution.** Registry fixtures cover routing, report admission, and repeated receipts. A kernel test checks that reception closes when the inbox cannot acknowledge a new copy of a consumed callback. Restart tests check which observation source goes first and which measurement drives the first soft-compaction decision. [Kernel tests](../packages/agent/src/kernel.zig) · [Session registry tests](../packages/agent/src/sessions.zig)
- **Checkpoint recovery.** Fixtures exercise save failures before publication and after a write reaches storage. They check that a failed save blocks subsequent writes and maintenance and that restart restores the selected state, including tool results, channel and activity registrations, wakeups, and activity reports. Startup tests verify republication of an unchanged checkpoint with its paired subscription catalog. Separate coverage follows a channel through the end of its opening activity, restart, and close. [Kernel tests](../packages/agent/src/kernel.zig) · [Session registry tests](../packages/agent/src/sessions.zig)
- **Handovers and working history.** Context tests check the registrations and descriptions saved with a summary. Kernel tests inspect the next ordinary request for a new activity's original assignment after compaction and for a single copy of an admitted observation after restart. A persistence test restores an older history, appends to it, and forks it. It checks that new records omit the uploaded file's bytes and that both sessions reload with the original reference. [Context tests](../packages/agent/src/context.zig) · [Kernel tests](../packages/agent/src/kernel.zig) · [History tests](../packages/agent/src/history.zig)
- **Mail.** A local JMAP server verifies recipient lookup before draft creation and the address stored on the draft. Connection failures exercise mailbox read recovery, uncertain submission, and confirmation of callback and history writes. Checkpoint tests cover size rejection, an unconfirmed preparation that prevents publication, keyword readback by message ID after an unconfirmed publication, and startup selection across pages of prepared, published, and earlier-format checkpoints. Retention tests verify which messages move to Trash. [Email transport](../packages/email/src/email_transport.zig) · [Checkpoint tests](../packages/email/src/history.zig) · [Retention tests](../packages/email/src/mail.zig)
- **Model requests.** Configuration and kernel tests cover reasoning effort defaults, overrides, and selection for handovers. HTTP fixtures check the effort and size of the encoded request, capture file bytes on upload, and verify that inference receives the returned file IDs in order. Other upload cases exercise rejection and a lost response. [Configuration test](../apps/ivenna/src/cli_test.zig) · [Kernel tests](../packages/agent/src/kernel.zig) · [Responses tests](../packages/responses/src/provider_test.zig)
- **Web resources.** A fixture verifies that two focuses can read one page snapshot from a single fetch. [Web reader tests](../packages/resources/src/web_test.zig)

The email, Responses, and web reader tests check that canceling a stalled HTTP exchange closes the connection. The local server checks for further request bytes and open connections. Measuring bytes received over TLS requires exercising the request writer against a local HTTPS server. [Local server](../tests/http.zig) · [Model transport](architecture.md#model-transport)

## Validating with running services

Use the [local environment](../dev/README.md) to validate restart and communication through the configured services. Replay representative work with the same model and starting history when comparing changes to model context.

Use the [channel walkthrough](../dev/README.md#trying-a-channel) to check send feedback, successive reads, and stream exit on close.

To check channel recovery with the running services, have an activity open a separate channel and give you its complete ID before it ends. Receive one message with an [independent receiver](running.md#channel-receivers), then [restart the kernel](running.md#stopping-and-restarting). With no new sends, a bounded read using the same ID should return `timeout`. Start another read, send a different message, and verify that it arrives through the restored channel. Close the channel when done.

### Evaluating compaction

Compare the focus's saved epoch before and after a summary attempt. In a new epoch, look for the handover, any pending work carried forward, and the observations admitted with it. For an activity that compacted its inherited history on opening, check that its original assignment follows the handover. If the epoch stays the same, check stderr for the reason. See [context budgets](running.md#context-budgets) and [persistent working history](architecture.md#persistent-working-history).

Compare the sample with the channel and subscription registrations active at its `observed_at` time and with the original scheduled times of pending wakeups. Check that later callbacks and reports reach the focus that arranged them. See [sampled state](input.md#sampled-state).

### Evaluating continuity across interruptions

Follow an encounter whose meaning depends on an earlier one. For example, a correspondent mentions learning French to speak with their grandmother. After a handover or restart, they say they now look forward to calling her. Look at Ivenna's reply or next action for evidence that it connects this news to the earlier conversation. See [a self in the world](design.md#a-self-in-the-world).

### Evaluating context disclosure

A request assembled by a fixture or captured from a running instance can show which facts reached a focus on a given turn.

To judge whether a cue helps, compare Ivenna's responses on the same starting history with and without the cue. For a reference, try one setting where it helps explain a new observation and another where it is incidental. Look for changes in Ivenna's interpretation or next action. Record request size separately. See [context and continuity](design.md#context-and-continuity).
