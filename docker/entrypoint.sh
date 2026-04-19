#!/usr/bin/env bash
# =============================================================================
# StoaChain container entrypoint — chainweb-node runner
# =============================================================================
#
# Translates environment variables into chainweb-node CLI flags. Designed for
# orchestration by the Ancient Holdings Hub (or any other tool that sets env
# vars and issues `docker run`) without needing to know the full flag surface.
#
# Env vars below are authoritative. Anything not modelled here can be passed
# via EXTRA_FLAGS as a raw passthrough.
#
# Design rules:
#   - Booleans are "true" / "false" strings. Anything other than "true" is false.
#   - Mandatory: only P2P_HOSTNAME (the identifier that differs per deployment).
#   - Default profile aligns with what a new operator would want: Recommended
#     profile from lib/stoachain-flags-catalog.ts in the Ancient Holdings repo.
#   - `exec` on the final line so PID 1 is chainweb-node itself (clean SIGTERM
#     from `docker stop` → graceful RocksDB shutdown).
#
# =============================================================================
# Supported environment variables (grouped):
# =============================================================================
#
# Core identity
#   CHAINWEB_VERSION              default: stoa
#   CLUSTER_ID                    default: unset — free-form log tag
#
# Data
#   DB_DIR                        default: /data                — --database-directory
#   BACKUP_DIR                    default: unset — derives as <DB_DIR>/backups
#   ALLOW_READS_IN_LOCAL          default: true                 — explorer-style queries
#   FULL_HISTORIC_PACT_STATE      default: true                 — never GC Pact state
#   DISABLE_RESET_CHAIN_DATABASES default: true                 — belt-and-braces
#
# P2P (peer network)
#   P2P_HOSTNAME                  REQUIRED                      — public hostname
#   P2P_PORT                      default: 1789
#   P2P_INTERFACE                 default: 0.0.0.0
#   P2P_MAX_PEER_COUNT            default: 100
#   P2P_MAX_SESSION_COUNT         default: 30                   — validator ceiling
#   P2P_SESSION_TIMEOUT           default: 600                  — seconds
#   KNOWN_PEER_INFO               default: unset                — space-separated, repeatable
#   IGNORE_BOOTSTRAP_NODES        default: false
#   ENABLE_PRIVATE                default: false                — private peer-discovery mode
#   BOOTSTRAP_REACHABILITY        default: 0.5                  — fraction; 0 skips the preflight
#
# TLS peer identity (persistent cert + key)
#   P2P_CERT_CHAIN_FILE           default: auto (see below)
#   P2P_CERT_KEY_FILE             default: auto (see below)
#
#   Auto behaviour: if both <DB_DIR>/tls-cert.pem and <DB_DIR>/tls-key.pem
#   exist, they're used. Otherwise chainweb-node generates an ephemeral cert
#   on every boot (peer-id flaps across restarts). For any long-lived node,
#   mount or pre-place a cert+key at those paths. The hub's install wizard
#   generates an ECDSA P-384 cert during provisioning.
#
# Mempool
#   ENABLE_MEMPOOL_P2P                default: true
#   MEMPOOL_P2P_MAX_SESSION_COUNT     default: 6
#   MEMPOOL_P2P_SESSION_TIMEOUT       default: 300
#   MEMPOOL_P2P_POLL_INTERVAL         default: 30
#
# Consensus / gas
#   BLOCK_GAS_LIMIT               default: 2000000              — Stoa network max
#   MIN_GAS_PRICE                 default: 0.00000001
#   PACT_QUEUE_SIZE               default: 4096
#   REORG_LIMIT                   default: 480
#   PRE_INSERT_CHECK_TIMEOUT      default: unset                — microseconds
#   CUT_FETCH_TIMEOUT             default: unset                — microseconds
#
# Service API (HTTP; no mTLS)
#   SERVICE_PORT                  default: 1848
#   SERVICE_INTERFACE             default: 127.0.0.1            — localhost-only by default
#
# Mining coordination (external stratum clients like chainweb-mining-client)
#   ENABLE_MINING_COORDINATION    default: false
#   MINING_PUBKEY                 required if coordination on   — hex, space-sep for multiple
#   MINING_REQUEST_LIMIT          default: 1200
#   MINING_UPDATE_STREAM_LIMIT    default: 2000
#   MINING_UPDATE_STREAM_TIMEOUT  default: 240
#   MINING_PAYLOAD_REFRESH_DELAY  default: unset                — microseconds; 2000000 for
#                                                                 low stale rate
#
# Node mining (in-process CPU miner — testing only; NOT for production)
#   ENABLE_NODE_MINING            default: false
#   NODE_MINING_PUBKEY            required if enabled
#
# Backup API
#   ENABLE_BACKUP_API             default: false                — exposes /make-backup
#
# Logging
#   LOG_LEVEL                     default: info                 — quiet|error|warn|info|debug
#   LOG_GAS                       default: false
#
# Runtime (GHC RTS)
#   RTS_ENABLED                   default: true
#   RTS_FLAGS                     default: "-T -N"              — -T = GC stats, -N = all cores
#
# Escape hatch
#   EXTRA_FLAGS                   default: unset                — raw string appended to argv
#
# =============================================================================

set -euo pipefail

: "${P2P_HOSTNAME:?P2P_HOSTNAME is required (e.g. node1.stoachain.com)}"

DB_DIR="${DB_DIR:-/data}"

# Auto-select cert paths if the files exist in the data dir.
if [[ -z "${P2P_CERT_CHAIN_FILE:-}" ]] && [[ -r "${DB_DIR}/tls-cert.pem" ]]; then
  P2P_CERT_CHAIN_FILE="${DB_DIR}/tls-cert.pem"
fi
if [[ -z "${P2P_CERT_KEY_FILE:-}" ]] && [[ -r "${DB_DIR}/tls-key.pem" ]]; then
  P2P_CERT_KEY_FILE="${DB_DIR}/tls-key.pem"
fi

ARGS=(
  --chainweb-version    "${CHAINWEB_VERSION:-stoa}"
  --database-directory  "${DB_DIR}"
  --p2p-hostname        "${P2P_HOSTNAME}"
  --p2p-port            "${P2P_PORT:-1789}"
  --p2p-interface       "${P2P_INTERFACE:-0.0.0.0}"
  --service-port        "${SERVICE_PORT:-1848}"
  --service-interface   "${SERVICE_INTERFACE:-127.0.0.1}"
  --log-level           "${LOG_LEVEL:-info}"
  --p2p-max-peer-count    "${P2P_MAX_PEER_COUNT:-100}"
  --p2p-max-session-count "${P2P_MAX_SESSION_COUNT:-30}"
  --p2p-session-timeout   "${P2P_SESSION_TIMEOUT:-600}"
  --block-gas-limit       "${BLOCK_GAS_LIMIT:-2000000}"
  --min-gas-price         "${MIN_GAS_PRICE:-0.00000001}"
  --pact-queue-size       "${PACT_QUEUE_SIZE:-4096}"
  --reorg-limit           "${REORG_LIMIT:-480}"
  --bootstrap-reachability "${BOOTSTRAP_REACHABILITY:-0.5}"
  --mempool-p2p-max-session-count "${MEMPOOL_P2P_MAX_SESSION_COUNT:-6}"
  --mempool-p2p-session-timeout   "${MEMPOOL_P2P_SESSION_TIMEOUT:-300}"
  --mempool-p2p-poll-interval     "${MEMPOOL_P2P_POLL_INTERVAL:-30}"
)

# Switch-pair flags. Default "true" for the ones that should be on in any
# reasonable prod config.
if [[ "${ENABLE_MEMPOOL_P2P:-true}" == "true" ]]; then
  ARGS+=(--enable-mempool-p2p)
else
  ARGS+=(--disable-mempool-p2p)
fi
if [[ "${FULL_HISTORIC_PACT_STATE:-true}" == "true" ]]; then
  ARGS+=(--full-historic-pact-state)
else
  ARGS+=(--no-full-historic-pact-state)
fi
if [[ "${ALLOW_READS_IN_LOCAL:-true}" == "true" ]]; then
  ARGS+=(--allowReadsInLocal)
else
  ARGS+=(--no-allowReadsInLocal)
fi
if [[ "${DISABLE_RESET_CHAIN_DATABASES:-true}" == "true" ]]; then
  ARGS+=(--disable-reset-chain-databases)
else
  ARGS+=(--enable-reset-chain-databases)
fi
if [[ "${ENABLE_PRIVATE:-false}" == "true" ]]; then
  ARGS+=(--enable-private)
else
  ARGS+=(--disable-private)
fi

# Optional — only emit if explicitly set (leaving these at chainweb defaults
# is fine; we don't force them into the CLI so the emitted argv stays short).
[[ -n "${PRE_INSERT_CHECK_TIMEOUT:-}" ]] && ARGS+=(--pre-insert-check-timeout "${PRE_INSERT_CHECK_TIMEOUT}")
[[ -n "${CUT_FETCH_TIMEOUT:-}" ]]         && ARGS+=(--cut-fetch-timeout "${CUT_FETCH_TIMEOUT}")
[[ -n "${CLUSTER_ID:-}" ]]                && ARGS+=(--cluster-id "${CLUSTER_ID}")
[[ -n "${BACKUP_DIR:-}" ]]                && ARGS+=(--backup-directory "${BACKUP_DIR}")

# TLS persistent identity (only when files exist).
if [[ -n "${P2P_CERT_CHAIN_FILE:-}" && -n "${P2P_CERT_KEY_FILE:-}" ]]; then
  ARGS+=(
    --p2p-certificate-chain-file="${P2P_CERT_CHAIN_FILE}"
    --p2p-certificate-key-file="${P2P_CERT_KEY_FILE}"
  )
else
  echo "[entrypoint] WARNING: no TLS cert+key — chainweb-node will generate an" \
       "ephemeral cert on every boot (peer-id flaps). Mount or pre-place" \
       "tls-cert.pem + tls-key.pem in ${DB_DIR}/ for a stable identity." >&2
fi

# KNOWN_PEER_INFO accepts space-separated list.
if [[ -n "${KNOWN_PEER_INFO:-}" ]]; then
  # shellcheck disable=SC2206
  for peer in ${KNOWN_PEER_INFO}; do
    ARGS+=(--known-peer-info="${peer}")
  done
fi

if [[ "${IGNORE_BOOTSTRAP_NODES:-false}" == "true" ]]; then
  ARGS+=(--enable-ignore-bootstrap-nodes)
fi

# Mining coordination (external stratum — the normal validator/mining setup).
if [[ "${ENABLE_MINING_COORDINATION:-false}" == "true" ]]; then
  : "${MINING_PUBKEY:?MINING_PUBKEY is required when ENABLE_MINING_COORDINATION=true}"
  ARGS+=(--enable-mining-coordination)
  # shellcheck disable=SC2206
  for pk in ${MINING_PUBKEY}; do
    ARGS+=(--mining-public-key="${pk}")
  done
  ARGS+=(--mining-request-limit "${MINING_REQUEST_LIMIT:-1200}")
  ARGS+=(--mining-update-stream-limit "${MINING_UPDATE_STREAM_LIMIT:-2000}")
  ARGS+=(--mining-update-stream-timeout "${MINING_UPDATE_STREAM_TIMEOUT:-240}")
  [[ -n "${MINING_PAYLOAD_REFRESH_DELAY:-}" ]] && ARGS+=(--mining-payload-refresh-delay "${MINING_PAYLOAD_REFRESH_DELAY}")
fi

# In-process node mining (rare; dev/testing only).
if [[ "${ENABLE_NODE_MINING:-false}" == "true" ]]; then
  : "${NODE_MINING_PUBKEY:?NODE_MINING_PUBKEY is required when ENABLE_NODE_MINING=true}"
  ARGS+=(--enable-node-mining --node-mining-public-key="${NODE_MINING_PUBKEY}")
else
  ARGS+=(--disable-node-mining)
fi

# Backup API.
if [[ "${ENABLE_BACKUP_API:-false}" == "true" ]]; then
  ARGS+=(--enable-backup-api)
fi

# Log gas trace (expensive; enable briefly only).
if [[ "${LOG_GAS:-false}" == "true" ]]; then
  ARGS+=(--log-gas)
else
  ARGS+=(--no-log-gas)
fi

# Escape hatch for anything not modelled above.
if [[ -n "${EXTRA_FLAGS:-}" ]]; then
  # shellcheck disable=SC2206
  ARGS+=(${EXTRA_FLAGS})
fi

# Forward positional args from `docker run <image> <args...>` verbatim.
ARGS+=("$@")

# GHC runtime flags go last (everything after +RTS is consumed by the runtime).
if [[ "${RTS_ENABLED:-true}" == "true" ]]; then
  # shellcheck disable=SC2206
  RTS_ARR=(+RTS ${RTS_FLAGS:-"-T -N"})
else
  RTS_ARR=()
fi

echo ">>> chainweb-node ${ARGS[*]} ${RTS_ARR[*]}"
exec /chainweb/chainweb-node "${ARGS[@]}" "${RTS_ARR[@]}"
