CREATE TABLE channels (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    stem TEXT NOT NULL,
    reference TEXT AS (stem || '-' || id) UNIQUE,
    description TEXT NOT NULL,
    closed INTEGER NOT NULL DEFAULT 0 CHECK (closed IN (0, 1))
) STRICT;
CREATE INDEX open_channels_by_id ON channels(id) WHERE closed=0;
CREATE TABLE messages (
    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
    channel INTEGER NOT NULL REFERENCES channels(id),
    focus_id TEXT NOT NULL,
    text TEXT NOT NULL,
    published_at_unix_ms INTEGER NOT NULL
) STRICT;
-- The sequence is the rowid and already sorts entries within each channel.
CREATE INDEX messages_by_channel ON messages(channel);

CREATE VIEW feeds AS
SELECT reference AS channel_id, description, closed FROM channels;

CREATE VIEW feed_messages AS
SELECT channels.reference AS channel_id, sequence, focus_id, text, published_at_unix_ms
FROM messages JOIN channels ON channels.id = messages.channel;
