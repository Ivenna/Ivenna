# Development

Follow the [running guide](running.md) to set up your environment and configuration. See the [architecture guide](architecture.md) for module dependencies, session execution, and storage, and [AGENTS.md](../AGENTS.md) for development conventions.

## Repository and build

Applications live in `apps/`, and reusable modules live in `packages/`:

| Location | Responsibility |
| --- | --- |
| [apps/server](../apps/server) | HTTP API, configuration, and service lifecycle |
| [packages/agent](../packages/agent) | Session execution, model and memory tool integration, and application state storage |
| [dev/memory](../dev/memory) | Memory container build, SSH entry point, and local startup |
| [compose.yaml](../compose.yaml) | Local PostgreSQL |

The root build compiles `apps/server` and its dependency, `packages/agent`. Run it from the repository root:

```sh
zig build
```

Build artifacts are installed to `zig-out`. After loading the configuration and starting the required containers, run the service from the same directory:

```sh
zig build serve
```

## Updating the service and memory container

The service code, [schema.sql](../packages/agent/src/schema.sql), and [tools.json](../packages/agent/src/tools.json) are compiled into the local application. After editing them, stop the service and run `zig build serve` to rebuild and restart it. Database schema changes also require the steps in the next section.

The agent package implements remote memory operations in [memory.nu](../packages/agent/src/memory.nu), which the [Containerfile](../dev/memory/Containerfile) installs in the memory container. After editing this handler, the container build file, the SSH server configuration, or the container's entry point, stop the local service, recreate the memory container, and restart the service:

```sh
dev/memory/start.sh down
dev/memory/start.sh up
zig build serve
```

If no container exists, `up` rebuilds the image and creates a container using the same memory volume and SSH keys. For other remote workspaces, update the handler and entry point at the locations described in [using remote memory](running.md#using-remote-memory). See [memory rooms](memory.md) for memory tool usage.

## Changing application data structures

[schema.sql](../packages/agent/src/schema.sql) defines the application's current session tables. The service creates missing tables at startup; editing this file does not update existing tables.

To change the database schema, stop the local service, then drop obsolete database objects or recreate the application database specified by `DATABASE_URL`. On restart, the service creates tables using the current schema. The application database and memory volume are independent; preserve the memory volume when recreating the database.
