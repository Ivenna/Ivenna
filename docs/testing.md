# Testing

Tests support Ivenna's exploratory development by catching consequential regressions while leaving interfaces and implementation free to evolve. Keep their setup, execution, and maintenance costs small enough to support routine iteration. The [development guide](development.md) sets the broader change conventions.

## Choosing tests

Choose checks from the intended behavior and the consequences of failure. Add a focused regression test when a failure would be costly or hard to notice during ordinary development. Existing tests can help identify affected behavior; revise or remove their expectations when the design changes.

Choose the smallest check that gives useful evidence at the boundary owning the behavior. Prefer observable outcomes over internal layout, exact prompt wording, or incidental serialization. A small, reversible change may need only review and a build. Judge a test by the failure it can expose and the maintenance it adds.

During development, do not write tests in advance or introduce test frameworks. Keep fixtures and setup limited to what the outcome requires. Keep tests with the component that owns the behavior, and adjust their placement as those responsibilities change.

## Running checks

Run commands from the repository root. Install the Zig version in [`.zig-version`](../.zig-version), then check tracked Zig source formatting, build Ivenna, and run the registered Zig tests:

```sh
git ls-files -z '*.zig' '*.zig.zon' | xargs -0 zig fmt --check
zig build
zig build test
```

The [root build](../build.zig) runs the registered Zig library and application tests. Run `zig build test` from [apps/ivenna](../apps/ivenna) to run only the CLI process tests. Library roots include internal test files through `test` blocks in `src/root.zig`. Adding a package to the test step requires a root build entry and a [dependency manifest](../build.zig.zon) entry.

For the [memory protocol tests](../apps/memory/tests.nu), install Nushell at the version used in the memory [Containerfile](../apps/memory/Containerfile). These tests also use the standard `ln` command:

```sh
nu --no-config-file --no-history apps/memory/tests.nu
```

The script uses Nushell's standard assertions, sends JSON requests directly to the handler in temporary workspaces, and removes those workspaces afterward. It uses no configuration or data from the development instance. Keep CI's Nushell version aligned with the Containerfile when upgrading it.

## Automation and validation limits

The [CI workflow](../.github/workflows/ci.yml) invokes these checks on Linux. The suites use local fixtures and run without deployed services or model credentials.

### Test boundaries

- **Command line.** Process tests check help and argument errors in an empty environment. With a temporary instance database, they check listener receipts and exit statuses and read feeds with the kernel stopped. The feed test resumes across a sequence gap and checks that message text and descriptions arrive intact. [CLI process tests](../apps/ivenna/src/cli_test.zig)
- **Instance state.** Feed tests reopen the database to check closure, sequence continuity, and creator identity. Subscription tests use two connections to verify that a cursor conflict leaves the key available, a retry after acknowledgement returns `duplicate`, and a queued report keeps its destination after withdrawal. [Feed store](../packages/instance_state/src/feeds.zig) · [Subscription store](../packages/instance_state/src/subscriptions.zig)
- **Focus execution.** Tests exercise ordinary turns without destination directories, routing when a focus and feed share an ID, and compaction sampling across activity completion. They also check that a complete tool exchange can survive a handover, observations that exceed the request limit stay pending, and an accepted subscription report enters the receiving history exactly once when a checkpoint fails or loses confirmation. [Kernel tests](../packages/agent/src/kernel.zig) · [Context tests](../packages/agent/src/context.zig) · [Session registry tests](../packages/agent/src/sessions.zig)
- **Mail.** A local JMAP server checks the configured recipient on the wire and verifies that denied sends stop before draft creation. Dropped connections exercise submission reconciliation, mailbox read recovery, and confirmation of callback and history writes. [Email transport](../packages/email/src/email_transport.zig) · [Email tests](../packages/email/src/root.zig)
- **Model transport and resources.** Responses tests compare request measurements with encoded HTTP bodies and exercise file upload outcomes. Web reader tests check that two focuses can read the same page snapshot with one fetch. [Responses tests](../packages/responses/src/provider_test.zig) · [Web reader tests](../packages/resources/src/web_test.zig)

The email, Responses, and web reader tests check that canceling a stalled HTTP exchange closes the connection. The local server checks for further request bytes and open connections. Measuring bytes received over TLS requires exercising the request writer against a local HTTPS server. [Local server](../tests/http.zig) · [Model transport](architecture.md#model-transport)

## Validating with running services

For process restart and communication through the configured services, exercise the running application in the [local development environment](../dev/README.md). See [validation across runtime boundaries](development.md#validation).

### Evaluating compaction

To compare context settings, replay representative work from the same starting history with the deployed model in a test instance. Compare committed handovers by the focus's saved epoch and check stderr for interruptions. See [context budgets](running.md#context-budgets) and [persistent working history](architecture.md#persistent-working-history).

Inspect the saved handover for the expected sampled IDs and observation time. Verify that a later callback or subscription report reaches the focus that arranged it. Follow the focus's subsequent work to see whether it carries a commitment and a correction forward and can find the evidence it used. See [sampled state](input.md#sampled-state).
