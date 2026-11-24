CREATE TABLE mailbox_binding (
    singleton INTEGER PRIMARY KEY CHECK (singleton=1),
    identity TEXT NOT NULL,
    bound INTEGER NOT NULL DEFAULT 0 CHECK (bound IN (0, 1))
) STRICT;
INSERT INTO mailbox_binding(singleton, identity) VALUES(1, lower(hex(randomblob(16))));
CREATE TABLE subscriptions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    reference TEXT AS (name || '-' || id) UNIQUE,
    focus_id TEXT NOT NULL,
    listener TEXT NOT NULL,
    cursor TEXT
) STRICT;
CREATE INDEX subscriptions_by_focus ON subscriptions(focus_id);
-- Each report keeps its destination after the registration is withdrawn.
CREATE TABLE subscription_reports (
    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
    reference TEXT NOT NULL,
    focus_id TEXT NOT NULL,
    text TEXT NOT NULL,
    source_time INTEGER,
    received INTEGER NOT NULL
) STRICT;
CREATE INDEX subscription_reports_by_focus ON subscription_reports(focus_id);
-- Keep keys until withdrawal so a listener that loses its receipt can retry
-- even after the focus receives the report. See docs/subscriptions.md#withdrawal.
CREATE TABLE accepted_report_keys (
    subscription_id INTEGER NOT NULL REFERENCES subscriptions(id) ON DELETE CASCADE,
    key TEXT NOT NULL,
    PRIMARY KEY(subscription_id, key)
) WITHOUT ROWID, STRICT;
