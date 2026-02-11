#!/bin/bash
exec /usr/local/bin/chainweb-node \
  --chainweb-version stoa \
  --enable-mining-coordination \
  --enable-node-mining \
  --node-mining-public-key=625ad78ab8c1df826d69e1f0e6457334b8e085b7d256d10be41726ced17fdf74 \
  --node-mining-account=foundation \
  --p2p-hostname=node1.stoachain.com \
  --p2p-interface=0.0.0.0 \
  --p2p-port=1789 \
  --service-port=1848 \
  --service-interface=0.0.0.0 \
  --database-directory=/var/lib/stoa/db \
  --log-level info \
  +RTS -T -N
