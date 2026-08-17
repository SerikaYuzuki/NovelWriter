-- Vault context is part of the authenticated ciphertext binding. This is a
-- v2-only database: a pre-existing row without context is evidence of a
-- legacy database and must stop migration rather than receive invented data.
DO $$
BEGIN
    IF to_regclass('auth_v1.external_identity_secrets') IS NULL THEN
        RAISE EXCEPTION 'auth_v1.external_identity_secrets is missing';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
         WHERE table_schema='auth_v1'
           AND table_name='external_identity_secrets'
           AND column_name='vault_context'
    ) THEN
        ALTER TABLE auth_v1.external_identity_secrets ADD COLUMN vault_context TEXT;
    END IF;

    IF EXISTS (
        SELECT 1 FROM auth_v1.external_identity_secrets
         WHERE vault_context IS NULL OR vault_context = ''
    ) THEN
        RAISE EXCEPTION 'legacy external_identity_secrets rows require explicit v2 vault context';
    END IF;

    ALTER TABLE auth_v1.external_identity_secrets ALTER COLUMN vault_context SET NOT NULL;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS external_identity_secrets_vault_context_idx
    ON auth_v1.external_identity_secrets(vault_context);

ALTER TABLE auth_v1.provider_credentials
    ADD COLUMN IF NOT EXISTS revoke_attempts INTEGER NOT NULL DEFAULT 0
        CHECK (revoke_attempts >= 0),
    ADD COLUMN IF NOT EXISTS revoke_lease_until TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS revoke_next_attempt_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS revoke_last_error TEXT;
