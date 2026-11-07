#!/usr/bin/env bash
# Puts build/openwavu-server on the VPS as a systemd service and restarts it. Needs sshpass; the root password is
# read from ~/secret.
set -euo pipefail
cd "$(dirname "$0")"
VPS=root@45.76.20.120
remote() { sshpass -f ~/secret ssh "$VPS" "$@"; }

sshpass -f ~/secret scp build/openwavu-server "$VPS:/usr/local/bin/openwavu-server.new"
remote 'cat > /etc/systemd/system/openwavu-server.service' <<'EOF'
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
EOF
remote 'mv /usr/local/bin/openwavu-server.new /usr/local/bin/openwavu-server &&
	systemctl daemon-reload && systemctl enable --now openwavu-server && systemctl restart openwavu-server &&
	sleep 1 && systemctl is-active openwavu-server && journalctl -u openwavu-server -n 3 --no-pager'
