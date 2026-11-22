BEGIN IMMEDIATE;
CREATE TABLE IF NOT EXISTS metadata (
    singleton INTEGER PRIMARY KEY CHECK (singleton=1),
    identity TEXT NOT NULL,
    bound INTEGER NOT NULL DEFAULT 0
);
INSERT INTO metadata(singleton, identity) VALUES(1, lower(hex(randomblob(16))))
ON CONFLICT(singleton) DO NOTHING;
CREATE TABLE IF NOT EXISTS subscriptions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    reference TEXT AS (name || '-' || id) STORED UNIQUE,
    session_id INTEGER NOT NULL,
    focus_id TEXT NOT NULL,
    reminder TEXT NOT NULL,
    listener TEXT NOT NULL,
    active INTEGER NOT NULL DEFAULT 1,
    external INTEGER NOT NULL DEFAULT 0,
    status TEXT,
    progress TEXT
);
CREATE INDEX IF NOT EXISTS owners ON subscriptions(session_id, id);
CREATE TABLE IF NOT EXISTS reports (
    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
    reference TEXT NOT NULL,
    session_id INTEGER NOT NULL,
    reminder TEXT NOT NULL,
    text TEXT NOT NULL,
    handle TEXT,
    retrieval TEXT NOT NULL,
    version TEXT,
    truncated INTEGER NOT NULL,
    source_time INTEGER,
    received INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS admissions ON reports(session_id, sequence);
CREATE INDEX IF NOT EXISTS reminders ON reports(session_id, reminder, sequence);
CREATE INDEX IF NOT EXISTS backlog ON reports(reference);
CREATE TABLE IF NOT EXISTS producer_keys (
    subscription_id INTEGER NOT NULL REFERENCES subscriptions(id) ON DELETE CASCADE,
    key TEXT NOT NULL,
    PRIMARY KEY(subscription_id, key)
) WITHOUT ROWID;
COMMIT;
