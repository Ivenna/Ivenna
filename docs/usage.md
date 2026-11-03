# Using sessions

Ivenna persists sessions and their history. Once you create a session, use the same session ID for subsequent inputs. The examples below use `http://127.0.0.1:5882`; replace this address when connecting to another service. See the [running guide](running.md) for local startup instructions.

## Creating a session

Submit a JSON object containing the default fields to use for each input. Submit `{}` if you have no default fields:

```sh
curl http://127.0.0.1:5882/sessions \
  -H 'Content-Type: application/json' \
  -d '{"language":"en","timezone":"Asia/Shanghai"}'
```

A successful response returns `201` and the session record. Save its `id`. The initial `state` is `{"waiting":{}}`; creating a session does not start model processing.

## Submitting input and checking results

Assuming the session ID is `1`, submit the first input:

```sh
curl http://127.0.0.1:5882/sessions/1/inputs \
  -H 'Content-Type: application/json' \
  -d '{"message":"Please remember that I am learning French."}'
```

A `202` response with `{"id":1,"status":"accepted"}` confirms that the input has been accepted for background processing. Query the session to read its execution state and saved history:

```sh
curl http://127.0.0.1:5882/sessions/1
```

If `state` contains the `pending` or `running` branch, processing is still in progress; query again later. The service manages model execution, which continues after the submission request ends. The `messages` field contains saved history, so output from an in-progress model and tool turn appears after that turn is checkpointed.

When the session reaches `waiting`, read any new assistant messages in `messages`. The model requests a pause by returning no tool calls or by calling `wait_for_input`; queued inputs keep execution running. If the session reaches `failed`, its state carries the error name; see [continuing and resuming](#continuing-and-resuming) to try again after addressing the failure.

## Continuing and resuming

Submit subsequent inputs to the same `/sessions/1/inputs` endpoint. If the session is running, new inputs are queued and incorporated after the current turn. If the session is `waiting` or `failed`, new input schedules it to continue processing.

To continue execution without new input, call:

```sh
curl -X POST http://127.0.0.1:5882/sessions/1/resume
```

The resume endpoint accepts sessions in `waiting`, `failed`, or `pending` state and continues with their existing history. It returns `409` if the session is running or does not exist.

## Input fields

Request bodies for session creation and input submission must be JSON objects. Fields saved at creation serve as defaults. Each input overrides matching top-level fields for that input only. Merging happens only at the top level: an object or array supplied for a field replaces that field's default value in full.

For example, if the session's default `language` is `en` and an input submits `{"language":"fr","message":"Summarize what we know."}`, the language field sent to the model for that input is `fr`. The next input uses `en` again unless it overrides the field. The service passes fields such as `language` and `timezone` to the model without interpreting them.

The service always sets `session_id` to the current session ID. If `message` is still absent after merging, it is set to an empty string. Add other fields as needed. The merged fields become YAML content in a user message sent to the model.

## API and session records

The API returns JSON. Replace `:id` with the ID returned when creating a session.

| Endpoint | Request body | Successful response |
| --- | --- | --- |
| `POST /sessions` | Default fields object | `201`, full session record |
| `POST /sessions/:id/inputs` | Fields for this input | `202`, `id` and `status: "accepted"` |
| `GET /sessions/:id` | None | `200`, full session record |
| `POST /sessions/:id/resume` | None | `202`, `id` and `status: "accepted"` |

The `status` in a `202` response indicates that the request was accepted. The `state` in a session record describes its execution state. A session record contains:

| Field | Meaning |
| --- | --- |
| `id` | Session ID for subsequent requests |
| `user_fields` | Default fields saved when the session was created |
| `state` | Current session state, containing exactly one branch from the table below |
| `messages` | Saved system and user messages, complete model output, and tool results |
| `pending_inputs` | Accepted inputs not yet incorporated into the history |

| `state` value | Meaning |
| --- | --- |
| `{"waiting":{}}` | Processing has paused; submit new input or call the resume endpoint to continue |
| `{"pending":{}}` | Queued for background execution |
| `{"running":{}}` | Processing a model request or tool operation |
| `{"failed":"ModelHttpFailure"}` | Execution failed; the branch value is the error name, shown here as `ModelHttpFailure` |

HTTP error responses use `{"error":"error_code"}`. Common errors are:

| Status | Error code | Cause |
| --- | --- | --- |
| `400` | `invalid_user_fields` or `invalid_input` | Creation or input body is invalid JSON or is not an object |
| `404` | `session_not_found` | Reading a session or submitting input to a session that does not exist |
| `404` | `not_found` | Unrecognized endpoint or invalid session ID |
| `405` | `method_not_allowed` | Endpoint does not support the HTTP method; the `Allow` header lists its supported method |
| `409` | `session_not_available` | Resuming a running session or a session that does not exist |

## Behavior over time

After a service restart, sessions previously in `pending` or `running` state continue from their saved history. Memory operations and host shell commands completed before the interruption may run again if their results had not yet been saved. See [failure and recovery](architecture.md#failure-and-recovery) for checkpoint and recovery boundaries.

Each session has its own default fields and history; all sessions share the [memory workspace](memory.md) and [deployment host](host.md). Long sessions are limited by the model's context window. See [model input and history](architecture.md#model-input-and-history) for how history is stored and sent.
