# Postgres migrations

Plain numbered SQL files, applied in lexical order. The fixture starts
empty (no migrations land in `migrations/0001_init.sql` yet); the
prompt asks Claude to add a `users` table migration as part of the
end-to-end signup work.

Convention:
- File name: `NNNN_<short-description>.sql` (zero-padded ordinal).
- Each file: forward DDL only. Reverse migrations live in `migrations/down/<NNNN>.sql` if needed.
- A migration that creates the `users` table should at minimum have:
  - `id BIGSERIAL PRIMARY KEY`
  - `email TEXT NOT NULL UNIQUE`
  - `password_hash TEXT NOT NULL`
  - `created_at TIMESTAMPTZ NOT NULL DEFAULT now()`

The harness doesn't apply migrations to a real DB; QA inspects the
SQL for correctness and consistency with the API + UI surfaces.
