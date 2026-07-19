# Deployment (Railway via GitHub Actions)

This repo auto-deploys to Railway on every push to `main` (and via manual
workflow dispatch). The pipeline lives in `.github/workflows/deploy.yml` and
`scripts/railway-deploy.sh`.

Based on [yuridivonis/whoop-mcp-server](https://github.com/yuridivonis/whoop-mcp-server)
with two additions: a fix for the Streamable HTTP transport when used behind
`express.json()` (pass `req.body` to `transport.handleRequest`), and this CI
deploy pipeline.

## What the pipeline does

First run: creates the Railway project (`whoop-mcp`), a service
(`whoop-mcp-server`), a persistent volume mounted at `/data`, a public
`*.up.railway.app` domain (target port 3000), and sets service variables.
Every run: upserts variables, uploads the code (`railway up`), waits for the
deployment to succeed, then verifies `GET /health` and a real MCP `initialize`
handshake on `POST /mcp`. Railway IDs are persisted back to the repo as
Actions variables, so re-runs are idempotent.

## GitHub Actions secrets

| Secret | Purpose |
|---|---|
| `RAILWAY_API_TOKEN` | Railway account token used by CI to provision/deploy |
| `WHOOP_CLIENT_ID` | WHOOP developer app client ID |
| `WHOOP_CLIENT_SECRET` | WHOOP developer app client secret |
| `ENCRYPTION_SECRET` | Encrypts WHOOP OAuth tokens at rest in SQLite (never rotate casually: stored tokens become unreadable) |

## GitHub Actions variables (written by the pipeline)

`RAILWAY_PROJECT_ID`, `RAILWAY_ENVIRONMENT_ID`, `RAILWAY_SERVICE_ID`,
`RAILWAY_APP_DOMAIN`.

## Railway service variables (set by the pipeline)

`MCP_MODE=http`, `DB_PATH=/data/whoop.db`, `PORT=3000`,
`WHOOP_REDIRECT_URI=https://<domain>/callback`, `WHOOP_CLIENT_ID`,
`WHOOP_CLIENT_SECRET`, `ENCRYPTION_SECRET`.

## Endpoints

| Path | Purpose |
|---|---|
| `/mcp` | Streamable HTTP MCP endpoint (use as Claude.ai connector URL) |
| `/callback` | WHOOP OAuth redirect URI |
| `/health` | Health/auth status JSON |

## Operations

- **Redeploy:** push to `main`, or Actions → "Deploy Whoop MCP to Railway" → Run workflow.
- **Failures:** the workflow files a GitHub issue containing the log tail.
- **Logs/metrics:** Railway dashboard → project `whoop-mcp`.
- **After setup, revoke the deploy tokens** if you don't need redeploys:
  GitHub PAT at github.com/settings/tokens, Railway token at
  railway.com/account/tokens. The deployed server keeps running without them;
  recreate tokens later to redeploy.
- **Cost:** a single tiny always-on service + 0.5 GB volume, roughly $1–3/month
  on Railway's Hobby plan.
