#!/usr/bin/env bash
# Run as root on the server box, in a checkout of this repo: builds openwavu-server and (re)starts it under systemd.
set -euo pipefail
cd "$(dirname "$0")"
./build.sh server speed
install -m 755 build/openwavu-server /usr/local/bin/openwavu-server
cat > /etc/systemd/system/openwavu-server.service <<'UNIT'
[Unit]
Description=openwavu-server
After=network-online.target

[Service]
ExecStart=/usr/local/bin/openwavu-server
DynamicUser=yes
StateDirectory=openwavu openwavu/packs
Restart=always

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable openwavu-server
systemctl restart openwavu-server
sleep 1
systemctl is-active openwavu-server
journalctl -u openwavu-server -n 3 --no-pager
