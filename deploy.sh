#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Stoa Chain Node — Ubuntu 22 Server Setup
# Host: node1.stoachain.com (129.212.143.119)
# Run as: root (or sudo)
###############################################################################

export DEBIAN_FRONTEND=noninteractive

echo "=== [1/7] System dependencies ==="
apt update && apt upgrade -y -o Dpkg::Options::="--force-confold"
apt install -y -o Dpkg::Options::="--force-confold" \
  build-essential curl libffi-dev libgmp-dev libncurses-dev \
  libssl-dev libtinfo-dev zlib1g-dev pkg-config git \
  librocksdb-dev libsnappy-dev libbz2-dev liblz4-dev libzstd-dev

echo "=== [2/7] Create stoa user ==="
id stoa &>/dev/null || useradd -r -m -s /bin/bash stoa
mkdir -p /var/lib/stoa/db
chown stoa:stoa /var/lib/stoa/db

echo "=== [3/7] Install GHCup (GHC 9.6.7 + Cabal 3.10) ==="
su - stoa -c 'export BOOTSTRAP_HASKELL_NONINTERACTIVE=1 && \
  export BOOTSTRAP_HASKELL_GHC_VERSION=9.6.7 && \
  export BOOTSTRAP_HASKELL_CABAL_VERSION=3.10.3.0 && \
  curl --proto "=https" --tlsv1.2 -sSf https://get-haskell.org | sh'

echo "=== [4/7] Clone and build ==="
su - stoa -c '
  source ~/.ghcup/env
  ghc --version
  cabal --version
  git clone https://github.com/StoaChain/stoa-chain.git ~/stoa-chain
  cd ~/stoa-chain
  cabal update
  cabal build chainweb-node
'

echo "=== [5/7] Install binary ==="
NODEBIN=$(su - stoa -c 'source ~/.ghcup/env && cd ~/stoa-chain && cabal list-bin chainweb-node')
cp "$NODEBIN" /usr/local/bin/chainweb-node
chmod +x /usr/local/bin/chainweb-node

echo "=== [6/7] Firewall ==="
ufw allow OpenSSH
ufw allow 1789/tcp comment "Stoa P2P"
ufw allow 1848/tcp comment "Stoa Service API"
ufw --force enable

echo "=== [7/7] Systemd service ==="
cat > /etc/systemd/system/stoa-node.service << 'UNIT'
[Unit]
Description=Stoa Chain Node
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=stoa
Group=stoa
ExecStart=/usr/local/bin/chainweb-node \
  --chainweb-version stoa \
  --enable-mining-coordination \
  --enable-node-mining \
  --node-mining-public-key=2643aaa44db9b8d92c295a2b4ea9400f2946691130d62e4f461a85f266a58052 \
  --p2p-hostname=node1.stoachain.com \
  --p2p-interface=0.0.0.0 \
  --p2p-port=1789 \
  --service-port=1848 \
  --service-interface=0.0.0.0 \
  --database-directory=/var/lib/stoa/db \
  --log-level info \
  +RTS -T -N
Restart=on-failure
RestartSec=10
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable stoa-node
systemctl start stoa-node

echo ""
echo "=== DONE ==="
echo "Check status:  systemctl status stoa-node"
echo "Live logs:     journalctl -u stoa-node -f"
echo "Check blocks:  curl -s http://node1.stoachain.com:1848/chainweb/0.0/stoa/cut | python3 -m json.tool"
