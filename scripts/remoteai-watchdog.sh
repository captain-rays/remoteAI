#!/usr/bin/env bash
# Restart the tunnel when the phone can no longer reach this Mac.
#
# cloudflared can wedge: it picks up an edge address that stops working — a
# VPN that was intercepting traffic when it resolved one leaves it holding a
# 198.18.x.x address from the reserved benchmark range — and then retries that
# same address every minute for ever. The process stays alive throughout, so
# launchd's KeepAlive sees nothing wrong, while Cloudflare answers every
# request with 530 and the phone sees a Mac that is simply gone.
#
# Checking the process is therefore not enough. This checks what the phone
# checks: the public address.
set -euo pipefail

origin="${REMOTEAI_PUBLIC_ORIGIN:-}"
[ -n "$origin" ] || { echo "$(date '+%F %T') no REMOTEAI_PUBLIC_ORIGIN; nothing to watch"; exit 0; }

label="live.jaco.remoteai.tunnel"
domain="gui/$(id -u)"

healthy() {
    [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$origin/v1/health")" = "200" ]
}

# Two chances before restarting: a single failure is as likely to be a blip on
# the way out as a wedged tunnel, and restarting drops any live connection.
if healthy; then
    exit 0
fi
sleep 5
if healthy; then
    exit 0
fi

# The agent itself may be the one that is down, in which case restarting the
# tunnel would fix nothing and hide the real fault.
if ! curl -s -o /dev/null --max-time 5 http://127.0.0.1:8787/v1/health; then
    echo "$(date '+%F %T') the agent is not answering on loopback; leaving the tunnel alone"
    exit 0
fi

echo "$(date '+%F %T') $origin is unreachable while the agent is healthy; restarting the tunnel"
launchctl kickstart -k "$domain/$label" || echo "$(date '+%F %T') could not restart $label"

# Report whether it worked, so the log says what happened rather than only
# that something was attempted.
for _ in $(seq 1 10); do
    sleep 3
    if healthy; then
        echo "$(date '+%F %T') the tunnel is answering again"
        exit 0
    fi
done
echo "$(date '+%F %T') still unreachable after a restart; something else is wrong"
