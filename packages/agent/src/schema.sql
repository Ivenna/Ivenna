-- Current development schema. Edit directly and rebuild the development database as needed.
BEGIN;

CREATE TABLE IF NOT EXISTS agent_sessions (
    id bigserial PRIMARY KEY,
    user_fields jsonb NOT NULL CHECK (jsonb_typeof(user_fields) = 'object'),
    status text NOT NULL DEFAULT 'waiting'
        CHECK (status IN ('waiting', 'pending', 'running', 'failed')),
    messages_json jsonb NOT NULL DEFAULT '[]' CHECK (jsonb_typeof(messages_json) = 'array'),
    pending_inputs jsonb NOT NULL DEFAULT '[]' CHECK (jsonb_typeof(pending_inputs) = 'array'),
    error_message text CHECK ((status = 'failed') = (error_message IS NOT NULL)),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

COMMIT;
