-- Current development schema. Edit directly and recreate the local database as needed.
BEGIN;

CREATE TABLE IF NOT EXISTS agent_sessions (
    id INTEGER PRIMARY KEY,
    user_fields TEXT NOT NULL CHECK (json_valid(user_fields) AND json_type(user_fields) = 'object'),
    status TEXT NOT NULL DEFAULT 'waiting'
        CHECK (status IN ('waiting', 'pending', 'running', 'failed')),
    messages_json TEXT NOT NULL DEFAULT '[]'
        CHECK (json_valid(messages_json) AND json_type(messages_json) = 'array'),
    pending_inputs TEXT NOT NULL DEFAULT '[]'
        CHECK (json_valid(pending_inputs) AND json_type(pending_inputs) = 'array'),
    error_message TEXT CHECK ((status = 'failed') = (error_message IS NOT NULL)),
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
) STRICT;

COMMIT;
