#!/usr/bin/env bash
# Idempotent Railway provision + deploy script, run from GitHub Actions.
# First run (no PROJECT_ID env): creates project, service, /data volume,
# public domain, and sets base variables. Every run: upserts variables,
# uploads code via `railway up`, waits for deploy, verifies /health and /mcp.
#
# Required env: RAILWAY_API_TOKEN
# Optional env: PROJECT_ID, ENVIRONMENT_ID, SERVICE_ID, APP_DOMAIN (state from repo vars),
#               WHOOP_CLIENT_ID, WHOOP_CLIENT_SECRET, ENCRYPTION_SECRET
set -euo pipefail

API="https://backboard.railway.com/graphql/v2"
PROJECT_NAME="${PROJECT_NAME:-whoop-mcp}"
SERVICE_NAME="${SERVICE_NAME:-whoop-mcp-server}"

req() { # $1 = graphql doc, $2 = variables json (compact)
  local resp
  resp=$(curl -sS --max-time 30 -X POST "$API" \
    -H "Authorization: Bearer ${RAILWAY_API_TOKEN}" \
    -H "Content-Type: application/json" \
    --data "$(jq -cn --arg q "$1" --argjson v "${2:-\{\}}" '{query:$q,variables:$v}')")
  if [ -z "$resp" ]; then
    echo "EMPTY_RESPONSE from API" >&2
    return 1
  fi
  if echo "$resp" | jq -e '.errors // empty' >/dev/null 2>&1; then
    echo "GRAPHQL_ERROR: $(echo "$resp" | jq -c '.errors')" >&2
    return 1
  fi
  echo "$resp"
}

echo "== Railway deploy: $(date -u +%FT%TZ) =="

# --- State fallback: load IDs from committed state file ----------------------
STATE_FILE=".deploy/state.json"
if [ -z "${PROJECT_ID:-}" ] && [ -s "$STATE_FILE" ]; then
  PROJECT_ID=$(jq -r '.projectId // empty' "$STATE_FILE")
  ENVIRONMENT_ID=${ENVIRONMENT_ID:-$(jq -r '.environmentId // empty' "$STATE_FILE")}
  SERVICE_ID=${SERVICE_ID:-$(jq -r '.serviceId // empty' "$STATE_FILE")}
  APP_DOMAIN=${APP_DOMAIN:-$(jq -r '.domain // empty' "$STATE_FILE")}
  [ -n "$PROJECT_ID" ] && echo "State loaded from $STATE_FILE (project $PROJECT_ID)"
fi

# --- 0) Token sanity --------------------------------------------------------
if ME=$(req 'query { me { name email } }' '{}' 2>/dev/null); then
  echo "Token OK — account: $(echo "$ME" | jq -r '.data.me.name // "?"')"
else
  echo "NOTE: 'me' query failed (workspace token or scope issue) — attempting to continue"
fi

# --- 1) Provision on first run ---------------------------------------------
if [ -z "${PROJECT_ID:-}" ]; then
  echo "== First run: provisioning project '$PROJECT_NAME' =="

  if ! PC=$(req 'mutation($input: ProjectCreateInput!){ projectCreate(input:$input){ id name } }' \
    "$(jq -cn --arg n "$PROJECT_NAME" '{input:{name:$n}}')"); then
    echo "projectCreate failed — introspecting ProjectCreateInput to aid debugging:" >&2
    req 'query { __type(name: "ProjectCreateInput") { inputFields { name type { kind name ofType { name } } } } }' '{}' 2>/dev/null | jq -c '.data.__type.inputFields' >&2 || true
    exit 1
  fi
  PROJECT_ID=$(echo "$PC" | jq -r '.data.projectCreate.id')
  echo "projectId: $PROJECT_ID"

  ENVS=$(req 'query($p: String!){ environments(projectId:$p){ edges { node { id name } } } }' \
    "$(jq -cn --arg p "$PROJECT_ID" '{p:$p}')")
  ENVIRONMENT_ID=$(echo "$ENVS" | jq -r '(.data.environments.edges[] | select(.node.name=="production") | .node.id) // .data.environments.edges[0].node.id')
  echo "environmentId: $ENVIRONMENT_ID"

  SERVICE_ID=$(req 'mutation($input: ServiceCreateInput!){ serviceCreate(input:$input){ id name } }' \
    "$(jq -cn --arg p "$PROJECT_ID" --arg n "$SERVICE_NAME" '{input:{projectId:$p, name:$n}}')" | jq -r '.data.serviceCreate.id')
  echo "serviceId: $SERVICE_ID"
  sleep 2

  VOLUME_ID=$(req 'mutation($input: VolumeCreateInput!){ volumeCreate(input:$input){ id name } }' \
    "$(jq -cn --arg p "$PROJECT_ID" --arg s "$SERVICE_ID" --arg e "$ENVIRONMENT_ID" '{input:{projectId:$p, serviceId:$s, environmentId:$e, mountPath:"/data"}}')" | jq -r '.data.volumeCreate.id')
  echo "volumeId: $VOLUME_ID (mounted at /data)"

  APP_DOMAIN=$(req 'mutation($input: ServiceDomainCreateInput!){ serviceDomainCreate(input:$input){ id domain } }' \
    "$(jq -cn --arg s "$SERVICE_ID" --arg e "$ENVIRONMENT_ID" '{input:{serviceId:$s, environmentId:$e, targetPort:3000}}')" | jq -r '.data.serviceDomainCreate.domain')
  echo "domain: $APP_DOMAIN"
else
  echo "== Existing deployment: project $PROJECT_ID =="
  if [ -z "${ENVIRONMENT_ID:-}" ]; then
    ENVIRONMENT_ID=$(req 'query($p: String!){ environments(projectId:$p){ edges { node { id name } } } }' \
      "$(jq -cn --arg p "$PROJECT_ID" '{p:$p}')" | jq -r '(.data.environments.edges[] | select(.node.name=="production") | .node.id) // .data.environments.edges[0].node.id')
  fi
fi

if [ -z "${APP_DOMAIN:-}" ] || [ -z "${SERVICE_ID:-}" ] || [ -z "${ENVIRONMENT_ID:-}" ]; then
  echo "FATAL: missing state (SERVICE_ID/ENVIRONMENT_ID/APP_DOMAIN). Check repo variables." >&2
  exit 1
fi

# --- 2) Upsert variables (values never printed) ------------------------------
VARS=$(jq -cn \
  --arg redirect "https://${APP_DOMAIN}/callback" \
  --arg enc "${ENCRYPTION_SECRET:-}" \
  --arg cid "${WHOOP_CLIENT_ID:-}" \
  --arg cs "${WHOOP_CLIENT_SECRET:-}" '
  {MCP_MODE:"http", DB_PATH:"/data/whoop.db", PORT:"3000", WHOOP_REDIRECT_URI:$redirect}
  + (if $enc != "" then {ENCRYPTION_SECRET:$enc} else {} end)
  + (if $cid != "" then {WHOOP_CLIENT_ID:$cid} else {} end)
  + (if $cs != "" then {WHOOP_CLIENT_SECRET:$cs} else {} end)')

req 'mutation($input: VariableCollectionUpsertInput!){ variableCollectionUpsert(input:$input) }' \
  "$(jq -cn --argjson vars "$VARS" --arg p "$PROJECT_ID" --arg e "$ENVIRONMENT_ID" --arg s "$SERVICE_ID" \
     '{input:{projectId:$p, environmentId:$e, serviceId:$s, skipDeploys:true, variables:$vars}}')" >/dev/null
echo "Variables set: $(echo "$VARS" | jq -r 'keys | join(", ")')"

# --- 3) Mint a project token and upload code ---------------------------------
# Workspace tokens work for the GraphQL API but not for `railway link`,
# so we mint a project-scoped token and hand that to the CLI instead.
echo "== Minting project deploy token =="
if ! PT_RESP=$(req 'mutation($input: ProjectTokenCreateInput!){ projectTokenCreate(input:$input) }' \
  "$(jq -cn --arg p "$PROJECT_ID" --arg e "$ENVIRONMENT_ID" '{input:{projectId:$p, environmentId:$e, name:"ci-deploy"}}')"); then
  echo "projectTokenCreate failed — introspecting input type:" >&2
  req 'query { __type(name: "ProjectTokenCreateInput") { inputFields { name type { kind name ofType { name } } } } }' '{}' 2>/dev/null | jq -c '.data.__type.inputFields' >&2 || true
  exit 1
fi
PROJECT_TOKEN=$(echo "$PT_RESP" | jq -r 'if (.data.projectTokenCreate|type)=="object" then (.data.projectTokenCreate.token // .data.projectTokenCreate.value // empty) else .data.projectTokenCreate end')
[ -n "$PROJECT_TOKEN" ] || { echo "FATAL: empty project token" >&2; exit 1; }

echo "== railway up (build logs follow) =="
env -u RAILWAY_API_TOKEN RAILWAY_TOKEN="$PROJECT_TOKEN" railway up --ci --service "$SERVICE_ID" \
  || env -u RAILWAY_API_TOKEN RAILWAY_TOKEN="$PROJECT_TOKEN" railway up --ci --service "$SERVICE_NAME"

# --- 4) Wait for deployment success -----------------------------------------
echo "== Waiting for deployment to become SUCCESS =="
DEPLOY_ID=""
STATUS="UNKNOWN"
for i in $(seq 1 60); do
  DEP=$(req 'query($input: DeploymentListInput!){ deployments(input:$input, first:1){ edges { node { id status createdAt } } } }' \
    "$(jq -cn --arg p "$PROJECT_ID" --arg e "$ENVIRONMENT_ID" --arg s "$SERVICE_ID" '{input:{projectId:$p, environmentId:$e, serviceId:$s}}')" || true)
  DEPLOY_ID=$(echo "$DEP" | jq -r '.data.deployments.edges[0].node.id // empty')
  STATUS=$(echo "$DEP" | jq -r '.data.deployments.edges[0].node.status // "UNKNOWN"')
  echo "  [$i] deployment $DEPLOY_ID status: $STATUS"
  case "$STATUS" in
    SUCCESS) break ;;
    FAILED|CRASHED|REMOVED)
      echo "== Deployment $STATUS — dumping logs ==" >&2
      req 'query($id: String!, $limit: Int){ buildLogs(deploymentId:$id, limit:$limit){ timestamp message } }' \
        "$(jq -cn --arg id "$DEPLOY_ID" '{id:$id, limit:120}')" 2>/dev/null | jq -r '.data.buildLogs[]?.message' | tail -60 || true
      req 'query($id: String!, $limit: Int){ deploymentLogs(deploymentId:$id, limit:$limit){ timestamp message severity } }' \
        "$(jq -cn --arg id "$DEPLOY_ID" '{id:$id, limit:120}')" 2>/dev/null | jq -r '.data.deploymentLogs[]?.message' | tail -60 || true
      exit 1 ;;
  esac
  sleep 10
done
if [ "$STATUS" != "SUCCESS" ]; then
  echo "FATAL: deployment did not reach SUCCESS in time (last: $STATUS)" >&2
  exit 1
fi

# --- 5) Verify /health -------------------------------------------------------
echo "== Verifying https://${APP_DOMAIN}/health =="
HEALTH=""
for i in $(seq 1 24); do
  HEALTH=$(curl -fsS --max-time 10 "https://${APP_DOMAIN}/health" 2>/dev/null || true)
  [ -n "$HEALTH" ] && break
  sleep 5
done
echo "health: ${HEALTH:-NO_RESPONSE}"
[ -n "$HEALTH" ] || { echo "FATAL: /health did not respond" >&2; exit 1; }

# --- 6) Verify /mcp initialize handshake ------------------------------------
echo "== Verifying MCP handshake at https://${APP_DOMAIN}/mcp =="
MCP=$(curl -sS --max-time 15 -X POST "https://${APP_DOMAIN}/mcp" \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"ci-check","version":"1.0"}}}' | head -c 500)
echo "mcp initialize response: $MCP"
echo "$MCP" | grep -q 'whoop-mcp-server' || { echo "FATAL: MCP handshake did not return serverInfo" >&2; exit 1; }

# --- 7) Persist state as repo variables (for idempotent re-runs) ------------
if command -v gh >/dev/null 2>&1 && [ -n "${GH_TOKEN:-}" ] && [ -n "${REPO:-}" ]; then
  gh variable set RAILWAY_PROJECT_ID --repo "$REPO" --body "$PROJECT_ID" || true
  gh variable set RAILWAY_ENVIRONMENT_ID --repo "$REPO" --body "$ENVIRONMENT_ID" || true
  gh variable set RAILWAY_SERVICE_ID --repo "$REPO" --body "$SERVICE_ID" || true
  gh variable set RAILWAY_APP_DOMAIN --repo "$REPO" --body "$APP_DOMAIN" || true
  echo "State persisted to repo variables."
fi

# --- 8) Outputs --------------------------------------------------------------
echo "RAILWAY_STATE_JSON={\"projectId\":\"$PROJECT_ID\",\"environmentId\":\"$ENVIRONMENT_ID\",\"serviceId\":\"$SERVICE_ID\",\"domain\":\"$APP_DOMAIN\"}"
{
  echo "## Whoop MCP deployed ✅"
  echo ""
  echo "- **Connector URL:** \`https://${APP_DOMAIN}/mcp\`"
  echo "- **OAuth callback:** \`https://${APP_DOMAIN}/callback\`"
  echo "- **Health:** \`${HEALTH}\`"
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
echo "== DONE =="
