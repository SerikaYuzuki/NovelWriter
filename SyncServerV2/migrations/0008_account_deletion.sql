-- Only an explicit authenticated request starts a grace period. Apple events
-- and account.state='deletionPending' are deliberately not inputs to this queue.
CREATE TABLE auth_v1.account_deletions (
    request_id UUID PRIMARY KEY,
    account_id TEXT NOT NULL REFERENCES auth_v1.accounts(account_id),
    state TEXT NOT NULL CHECK (state IN ('pending','cancelled','deleted')),
    requested_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    delete_after TIMESTAMPTZ NOT NULL,
    cancelled_at TIMESTAMPTZ,
    deleted_at TIMESTAMPTZ,
    CHECK (delete_after = requested_at + interval '720 hours'),
    CHECK ((state='pending' AND cancelled_at IS NULL AND deleted_at IS NULL)
        OR (state='cancelled' AND cancelled_at IS NOT NULL AND deleted_at IS NULL)
        OR (state='deleted' AND cancelled_at IS NULL AND deleted_at IS NOT NULL))
);
CREATE UNIQUE INDEX account_deletions_one_pending ON auth_v1.account_deletions(account_id) WHERE state='pending';
CREATE INDEX account_deletions_due ON auth_v1.account_deletions(delete_after) WHERE state='pending';
