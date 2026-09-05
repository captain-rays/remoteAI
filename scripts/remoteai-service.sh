#!/usr/bin/env bash
# Install, remove and inspect the RemoteAI background services.
#
# Two LaunchAgents, both running as the logged-in user:
#
#   live.jaco.remoteai.agent   the Rust agent, listening on 127.0.0.1:8787
#   live.jaco.remoteai.tunnel  the named Cloudflare tunnel that fronts it
#
# They are LaunchAgents rather than LaunchDaemons because the agent reads this
# user's Codex and Claude sessions and must run as them. Both restart on exit
# and start at login.
#
#   scripts/remoteai-service.sh install     build, install and start
#   scripts/remoteai-service.sh uninstall   stop and remove
#   scripts/remoteai-service.sh status      what launchd thinks
#   scripts/remoteai-service.sh logs        follow both logs
#   scripts/remoteai-service.sh restart     reload after a rebuild
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
config_file="${REMOTEAI_ENV_FILE:-$HOME/.config/remoteai/agent.env}"
install_root="$HOME/Library/Application Support/RemoteAI"
binary_path="$install_root/bin/remote-ai-agent"
log_dir="$HOME/Library/Logs/RemoteAI"
launch_agents="$HOME/Library/LaunchAgents"
agent_label="live.jaco.remoteai.agent"
tunnel_label="live.jaco.remoteai.tunnel"

die() { printf '%s\n' "$*" >&2; exit 1; }

# launchctl needs the user's GUI domain to start something at login.
domain="gui/$(id -u)"

read_config() {
    [ -f "$config_file" ] || die "no config at $config_file
Copy deploy/remoteai.env.example there and edit it first."
    # Read as a shell fragment so $HOME expands, but only KEY=VALUE lines.
    set -a
    # shellcheck disable=SC1090
    . "$config_file"
    set +a
    [ -n "${REMOTEAI_PUBLIC_ORIGIN:-}" ] \
        || die "REMOTEAI_PUBLIC_ORIGIN is required in $config_file"
    case "$REMOTEAI_PUBLIC_ORIGIN" in
        https://*) ;;
        *) die "REMOTEAI_PUBLIC_ORIGIN must be https: the phone refuses a plaintext origin" ;;
    esac
    tunnel_name="${REMOTEAI_TUNNEL_NAME:-remoteai}"
}

xml_escape() {
    sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# The agent's environment, as plist <key>/<string> pairs.
agent_environment() {
    local name value
    for name in REMOTEAI_PUBLIC_ORIGIN REMOTEAI_PAIRING_FILE REMOTEAI_CLAUDE_MODEL \
                REMOTEAI_CODEX_MODEL REMOTEAI_CLAUDE_PERMISSION_MODE; do
        value="${!name:-}"
        [ -n "$value" ] || continue
        printf '        <key>%s</key>\n        <string>%s</string>\n' \
            "$name" "$(printf '%s' "$value" | xml_escape)"
    done
    # Both CLIs are found on PATH, which launchd does not inherit from a shell.
    printf '        <key>PATH</key>\n        <string>%s</string>\n' \
        "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
}

render() {
    local template="$1" output="$2"
    local environment
    environment="$(agent_environment)"
    # Substitute with awk so multi-line values survive.
    AGENT_BINARY="$binary_path" \
    AGENT_ENVIRONMENT="$environment" \
    LOG_DIR="$log_dir" \
    HOME_DIR="$HOME" \
    CLOUDFLARED="$cloudflared" \
    AGENT_URL="http://127.0.0.1:8787" \
    TUNNEL_NAME="$tunnel_name" \
    awk '
        {
            gsub(/@AGENT_BINARY@/, ENVIRON["AGENT_BINARY"])
            gsub(/@LOG_DIR@/, ENVIRON["LOG_DIR"])
            gsub(/@HOME@/, ENVIRON["HOME_DIR"])
            gsub(/@CLOUDFLARED@/, ENVIRON["CLOUDFLARED"])
            gsub(/@AGENT_URL@/, ENVIRON["AGENT_URL"])
            gsub(/@TUNNEL_NAME@/, ENVIRON["TUNNEL_NAME"])
            if ($0 ~ /@AGENT_ENVIRONMENT@/) { printf "%s", ENVIRON["AGENT_ENVIRONMENT"]; next }
            print
        }
    ' "$template" > "$output"
    plutil -lint "$output" >/dev/null || die "rendered $output is not a valid plist"
}

bootout() {
    launchctl bootout "$domain/$1" 2>/dev/null || true
}

do_install() {
    read_config
    cloudflared="$(command -v cloudflared || true)"
    [ -n "$cloudflared" ] || die "cloudflared is not installed (brew install cloudflared)"
    [ -f "$HOME/.cloudflared/cert.pem" ] \
        || die "cloudflared is not logged in — run: cloudflared tunnel login"
    "$cloudflared" tunnel info "$tunnel_name" >/dev/null 2>&1 \
        || die "no named tunnel '$tunnel_name'. Create one first:
    cloudflared tunnel create $tunnel_name
    cloudflared tunnel route dns $tunnel_name <hostname>"

    echo "==> building the agent (release)"
    ( cd "$repo_root" && cargo build --release -p remote-ai-agent --bin remote-ai-agent )

    mkdir -p "$install_root/bin" "$log_dir" "$launch_agents"
    chmod 700 "$install_root"
    # Copy rather than symlink the build tree: rebuilding a worktree, or
    # deleting it, must not take the installed service down with it.
    install -m 755 "$repo_root/target/release/remote-ai-agent" "$binary_path"

    render "$repo_root/deploy/launchd/$agent_label.plist.template" \
        "$launch_agents/$agent_label.plist"
    render "$repo_root/deploy/launchd/$tunnel_label.plist.template" \
        "$launch_agents/$tunnel_label.plist"

    for label in "$tunnel_label" "$agent_label"; do
        bootout "$label"
        launchctl bootstrap "$domain" "$launch_agents/$label.plist"
        launchctl enable "$domain/$label"
    done

    echo "==> installed"
    echo "    agent   $binary_path"
    echo "    origin  $REMOTEAI_PUBLIC_ORIGIN"
    echo "    tunnel  $tunnel_name"
    echo "    logs    $log_dir"
}

do_uninstall() {
    for label in "$agent_label" "$tunnel_label"; do
        bootout "$label"
        rm -f "$launch_agents/$label.plist"
    done
    echo "==> removed both services (the agent binary and its state are kept)"
}

do_status() {
    for label in "$agent_label" "$tunnel_label"; do
        if launchctl print "$domain/$label" >/dev/null 2>&1; then
            printf '%-32s %s\n' "$label" \
                "$(launchctl print "$domain/$label" | awk '/state = /{print $3; exit}')"
        else
            printf '%-32s not installed\n' "$label"
        fi
    done
    printf '%-32s ' "agent health"
    curl -fsS --max-time 5 http://127.0.0.1:8787/v1/health 2>/dev/null || echo "unreachable"
    echo
}

case "${1:-}" in
    install) do_install ;;
    uninstall) do_uninstall ;;
    restart)
        read_config
        cloudflared="$(command -v cloudflared || true)"
        for label in "$tunnel_label" "$agent_label"; do
            launchctl kickstart -k "$domain/$label" 2>/dev/null \
                || echo "$label is not installed" >&2
        done
        ;;
    status) do_status ;;
    logs) tail -f "$log_dir/agent.log" "$log_dir/tunnel.log" ;;
    *)
        sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
        exit 2
        ;;
esac
