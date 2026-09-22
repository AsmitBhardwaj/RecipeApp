-- Delete smoke-test accounts and all their data from production.
-- Safe: targets only smoketest+*@example.com addresses. Run against the
-- production Postgres (Railway). Wrapped in a transaction so it's all-or-nothing.
--
-- Accounts created during the 2026-08-31 signed-in smoke test:
--   smoketest+1788197115@example.com   (API round-trip test)
--   smoketest+ui1788199216@example.com (in-app UI test)
-- The LIKE pattern covers both plus any other smoketest+ rows.

BEGIN;

-- Children first (no explicit FKs are defined, but this order is safe regardless).
DELETE FROM sync_items      WHERE user_id IN (SELECT id FROM users WHERE email LIKE 'smoketest+%@example.com');
DELETE FROM sync_state      WHERE user_id IN (SELECT id FROM users WHERE email LIKE 'smoketest+%@example.com');
DELETE FROM refresh_tokens  WHERE user_id IN (SELECT id FROM users WHERE email LIKE 'smoketest+%@example.com');
DELETE FROM auth_identities WHERE user_id IN (SELECT id FROM users WHERE email LIKE 'smoketest+%@example.com');
DELETE FROM user_recipes    WHERE user_id IN (SELECT id FROM users WHERE email LIKE 'smoketest+%@example.com');

-- Finally the accounts themselves.
DELETE FROM users WHERE email LIKE 'smoketest+%@example.com';

-- Sanity check: should return 0.
SELECT count(*) AS remaining_smoke_accounts FROM users WHERE email LIKE 'smoketest+%@example.com';

COMMIT;
