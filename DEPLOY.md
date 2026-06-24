# Deploying to Railway

This app deploys as a standard Phoenix release via the `Dockerfile` in this repo.
Railway auto-detects the Dockerfile and builds it.

## What this deploy is

A **standalone** instance of the Phoenix app with its **own** PostgreSQL database —
great for running the app live and testing the ElevenLabs webhook. It is **not yet
connected to the live Django app's data**; that link (a shared, per-tenant database) is
the multitenancy slice planned separately.

## One-time Railway setup

1. **Source:** this GitHub repo (deploys from `main`).
2. **PostgreSQL:** add the Railway Postgres plugin (done).
3. **Volume:** **not needed** — the app stores nothing on local disk; all data is in Postgres.
4. **Environment variables** (app service → Variables):

   | Variable | Value |
   |---|---|
   | `DATABASE_URL` | `${{Postgres.DATABASE_URL}}` (reference the Postgres service) |
   | `SECRET_KEY_BASE` | a 64+ char random key — generate with `mix phx.gen.secret` |
   | `PHX_HOST` | your public domain, e.g. `florina-production.up.railway.app` |
   | `PHX_SERVER` | `true` |
   | `ELEVENLABS_WEBHOOK_SECRET` | the `wsec_…` value (from the team `.env`) |

   `PORT` is injected by Railway automatically — do not set it.

5. **Run migrations on deploy:** set the deploy / pre-deploy command to:

   ```
   /app/bin/migrate
   ```

   It creates the tables (Oban jobs + the call table) on first deploy. Safe to re-run.

6. **Public domain:** Settings → Networking → Generate Domain, then put it in `PHX_HOST`.
7. **Health check path:** `/healthz`.

## After it's live

- Point the ElevenLabs webhook URL to `https://<your-domain>/webhooks/elevenlabs`, with
  the matching `ELEVENLABS_WEBHOOK_SECRET` set.
- (Later) Twilio → `https://<your-domain>/webhooks/twilio` once that slice ships.

## Optional local sanity check (build the production release)

```bash
MIX_ENV=prod mix release
SECRET_KEY_BASE=$(mix phx.gen.secret) PHX_SERVER=true \
  DATABASE_URL=ecto://alex@localhost/florina_dev \
  _build/prod/rel/florina/bin/server
```
