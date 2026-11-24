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

The [CI workflow](../.github/workflows/ci.yml) invokes these checks on Linux. The checks run directly with Zig and Nushell and require no deployed services or model credentials. Extend or replace automated checks when the evidence they provide justifies their execution and maintenance cost.

The email adapter tests use a local HTTP server to drop connections and count the requests that reach it. They check that a mailbox read can recover and that an interrupted send submits its draft at most once. For callbacks and working history, the tests check what stored evidence lets the adapter confirm a write after it loses the response.

The email, Responses, and web page reader tests check that canceling a stalled HTTP exchange closes the connection. The [local server](../tests/http.zig) detects further request bytes or a connection left open. Measuring how many bytes reach a TLS peer requires exercising the [request writer](architecture.md#model-transport) against a local HTTPS server.

The [web reader tests](../packages/resources/src/web_test.zig) check that two focuses can read the same page snapshot with one fetch. The [Responses tests](../packages/responses/src/provider_test.zig) compare measured request sizes with bodies sent over loopback HTTP. They also check what the next inference receives after a file upload fails and whether the adapter repeats an upload whose outcome is uncertain.

The agent tests cover inference retries with the original request, delivery retention across interruption, and the arrivals that wake a focus. The [kernel tests](../packages/agent/src/kernel.zig) also check that a complete tool exchange can reach the next request across a handover and that an observation stays pending when it cannot fit. The session registry tests inject a save failure after receiving a checkpoint to check that activity completion publishes once and a later maintenance pass republishes the same selection when confirmation was lost.

One CLI process test runs help and a mistyped command in an empty environment. It checks that help works before configuration and that argument errors produce JSON on stdout and a diagnostic on stderr. See the [CLI process tests](../apps/ivenna/src/cli_test.zig).

### Message delivery

- **Destination selection.** The decoder rejects a call that selects two destinations. The kernel delivers to the correct owner when a focus and a feed share an ID. The registry tests track which focus IDs are visible as sessions open and end. [Decoder](../packages/agent/src/tools.zig) · [Kernel](../packages/agent/src/kernel.zig) · [Registry](../packages/agent/src/sessions.zig)
- **Correspondence.** A registered ID selects its configured recipient. An unregistered ID stops the call before draft creation. [Email transport](../packages/email/src/email_transport.zig)
- **Feeds.** Closure survives reopening and prevents further publication. The CLI can read a closed feed with the kernel stopped, resume across sequence gaps, and preserve the full message text. [Feed store](../packages/instance_state/src/feeds.zig) · [CLI process tests](../apps/ivenna/src/cli_test.zig)

### Subscription delivery

- **Listener process.** Each request runs `ivenna subscription` against a temporary instance database. The tests check receipts and exit status for publication, same-key retries, cursor changes, invalid fields, and publication after withdrawal. See the [CLI process tests](../apps/ivenna/src/cli_test.zig).
- **Subscription store.** Two SQLite connections exercise publication and withdrawal. The tests check that a cursor conflict leaves the key available, a retry after acknowledgement returns `duplicate`, and a queued report keeps its destination after withdrawal. See the [store tests](../packages/instance_state/src/subscriptions.zig).
- **Focus history.** The kernel tests cover ordered admission across pages, later arrivals, tight request limits, interrupted admission, and withdrawal of a sleeping activity's last subscription. The recovery test rebuilds the kernel against the same test history store and in-memory instance database after a failure before checkpoint commit or a lost confirmation after commit. In both cases the receiving history must contain the report exactly once. See the [kernel tests](../packages/agent/src/kernel.zig).

## Validating with running services

For process restart and communication through the configured services, exercise the running application in the [local development environment](../dev/README.md). See [validation across runtime boundaries](development.md#validation).

### Evaluating compaction

To compare [context settings](running.md#context-budgets), replay representative work from the same starting history with the deployed model in a test instance. After a handover, check whether the focus carries a commitment and a correction forward and can find the original evidence. Check that an activity resumes when its callback or subscription report arrives.

The kernel advances the [focus's saved epoch](architecture.md#persistent-working-history) when it commits a handover. Compare epoch changes across runs and check stderr for interruptions.
