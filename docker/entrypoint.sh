#!/usr/bin/env bash
# =============================================================================
# StoaChain container entrypoint
# =============================================================================
#
# Translates environment variables into chainweb-node CLI flags, so that an
# orchestrator (the Stoa Hub) can start the container without needing to know
# the chainweb-node --help surface.
#
# Design rules:
#   - Every variable has a sensible default EXCEPT those that identify this
#     specific node (P2P_HOSTNAME, and MINING_PUBKEY when mining is on).
#   - Booleans are "true"/"false" strings; anything other than "true" is false.
#   - EXTRA_FLAGS is a raw passthrough for anything not modelled here, so the
#     surface doesn't have to grow every time chainweb-node adds a flag.
#   - Any positional args passed after the image name on `docker run` are
#     forwarded verbatim, so you can still override ad-hoc from the CLI.
#   - `exec` on the final line so PID 1 becomes chainweb-node itself and
#     SIGTERM from `docker stop` reaches it directly (clean RocksDB shutdown).
#
# Supported environment variables:
#
#   CHAINWEB_VERSION        (default: stoa)
#   DB_DIR                  (default: /data)               — RocksDB directory
#   P2P_HOSTNAME            (REQUIRED)                     — public hostname/IP
#   P2P_INTERFACE           (default: 0.0.0.0)
#   P2P_PORT                (default: 1789)
#   SERVICE_INTERFACE       (default: 0.0.0.0)
#   SERVICE_PORT            (default: 1848)
#   LOG_LEVEL               (default: info)                — error|warn|info|debug
#   ENABLE_MINING           (default: false)               — "true" to enable mining
#   MINING_PUBKEY           (required iff ENABLE_MINING)   — hex pubkey
#   KNOWN_PEER_INFO         (optional)                     — extra bootstrap peer
#   IGNORE_BOOTSTRAP_NODES  (default: false)               — "true" to skip baked-in bootstraps
#   RTS_ENABLED             (default: true)                — "false" to omit GHC RTS flags
#   RTS_FLAGS               (default: "-T -N")             — GHC RTS options (space-separated)
#   EXTRA_FLAGS             (optional)                     — raw extra args to chainweb-node
# =============================================================================

set -euo pipefail

: "${P2P_HOSTNAME:?P2P_HOSTNAME is required (e.g. node1.stoachain.com)}"

ARGS=(
  --chainweb-version    "${CHAINWEB_VERSION:-stoa}"
  --database-directory  "${DB_DIR:-/data}"
  --p2p-hostname        "${P2P_HOSTNAME}"
  --p2p-interface       "${P2P_INTERFACE:-0.0.0.0}"
  --p2p-port            "${P2P_PORT:-1789}"
  --service-interface   "${SERVICE_INTERFACE:-0.0.0.0}"
  --service-port        "${SERVICE_PORT:-1848}"
  --log-level           "${LOG_LEVEL:-info}"
)

if [[ "${ENABLE_MINING:-false}" == "true" ]]; then
  : "${MINING_PUBKEY:?MINING_PUBKEY is required when ENABLE_MINING=true}"
  ARGS+=(
    --enable-mining-coordination
    --enable-node-mining
    --node-mining-public-key="${MINING_PUBKEY}"
  )
fi

if [[ -n "${KNOWN_PEER_INFO:-}" ]]; then
  ARGS+=(--known-peer-info="${KNOWN_PEER_INFO}")
fi

if [[ "${IGNORE_BOOTSTRAP_NODES:-false}" == "true" ]]; then
  ARGS+=(--enable-ignore-bootstrap-nodes)
fi

# EXTRA_FLAGS is intentionally unquoted so it splits on whitespace the way a
# shell would. shellcheck disable=SC2206 for that reason.
if [[ -n "${EXTRA_FLAGS:-}" ]]; then
  # shellcheck disable=SC2206
  ARGS+=(${EXTRA_FLAGS})
fi

# Forward any positional args from `docker run <image> <args...>` verbatim.
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
