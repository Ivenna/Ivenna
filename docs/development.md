# Development

This guide defines development conventions and explains how to build and update Ivenna. The [design intent](design.md) guides product and interface decisions; the [architecture guide](architecture.md) describes the current implementation. Follow the [running guide](running.md) for environment setup and configuration.

## Development conventions

The project is still in an exploratory phase. Data structures, database tables, interfaces, and module boundaries are not yet settled; change them directly to match the current design.

Work from the design intent down to responsibilities, interfaces, and implementation. Explain design choices through the behavior and relationships they establish and the reasons for choosing them. Include implementation details where they help assess a choice or support work on the current code.

Establish the shape of a change first, then implement it in useful increments. Complex or future areas may remain explicit placeholders; describe what works now and what remains undecided.

Do not retain compatibility code paths for superseded designs. Do not design or maintain migration workflows. Maintain only the current SQLite schema. When it changes, rebuild the local development database as needed, without introducing versioned migrations, upgrade chains, or migration frameworks.

During development, do not write tests in advance or introduce test frameworks. Run the application locally; containerize only middleware.

## Implementation boundaries

Keep protocol decoding in the component that owns the external interface, and give execution code typed operations. Select data according to the consumer's responsibility; a full API record need not be the unit used by the execution loop.

Model coexisting fields together and mutually exclusive alternatives as distinct variants in both language types and structured data such as JSON. Keep variant-specific fields tied to their discriminator; variants with the same payload shape can share fields.

Make the owner and lifetime of returned data explicit. Copy or transfer ownership of values that must outlive temporary storage; copy borrowed database values before their statement ends. Manage concurrent work through `std.Io` task scopes, arranging cancellation and completion before releasing dependencies. Keep synchronization inside the component that owns the shared state.

## Repository and build

Applications live in `apps/`, and reusable modules live in `packages/`:

| Location | Responsibility |
| --- | --- |
| [apps/server](../apps/server) | HTTP API, configuration, and service lifecycle |
| [packages/agent](../packages/agent) | Session execution, model and tool integration, and application state storage |
| [dev/memory](../dev/memory) | Memory container build, SSH entry point, and local startup |

The root build compiles `apps/server` and its dependency, `packages/agent`. Run it from the repository root:

```sh
zig build
```

Build artifacts are installed to `zig-out`; SQLite is compiled into the server. After loading the configuration and preparing the memory workspace, run the service from the same directory:

```sh
zig build serve
```

## Updating the service and memory container

The service code, [system.md](../packages/agent/src/system.md), [tools.json](../packages/agent/src/tools.json), and [schema.sql](../packages/agent/src/schema.sql) are compiled into the local application. After editing them, stop the service and run `zig build serve` to rebuild and restart it. Database schema changes also require the steps in the next section.

The agent package implements remote memory operations in [memory.nu](../packages/agent/src/memory.nu), which the [Containerfile](../dev/memory/Containerfile) installs in the memory container. After editing this handler, the container build file, the SSH server configuration, or the container's entry point, stop the local service, recreate the memory container, and restart the service:

```sh
dev/memory/start.sh down
dev/memory/start.sh up
zig build serve
```

If no container exists, `up` rebuilds the image and creates a container using the same memory volume and SSH keys. For other remote workspaces, update the handler and entry point at the locations described in [using remote memory](running.md#using-remote-memory). See [memory rooms](memory.md) for memory tool usage.

## Changing application data structures

[schema.sql](../packages/agent/src/schema.sql) defines the application's current session tables. The service creates missing tables at startup; editing this file does not update existing tables.

To apply the updated schema locally, stop the service and remove the `state.sqlite` database and any `state.sqlite-journal` file beside it from the configured `DATA_DIR`. On restart, the service creates a database using the current schema. This resets sessions and their history; host output files and the separate memory workspace remain. See [local data](running.md#local-data) for the current layout.
