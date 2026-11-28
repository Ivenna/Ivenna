-- Upgrade to IVST version 1 from a legacy database that has the cursor column.
ALTER TABLE subscriptions DROP COLUMN cursor;
