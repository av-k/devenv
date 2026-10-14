#!/bin/sh
# Restricts outbound traffic to hosts listed in the allowlist.
#
# Best effort, not a guarantee. Domains are resolved once at container start
# and pinned as IP addresses. Large CDNs rotate addresses, so a long session
# may start seeing denials for hosts that were reachable earlier; restarting
# the container re-resolves them. Read docs/SECURITY-CONTEXT.md for what this
# does and does not protect against.
set -eu

ALLOWLIST="${DEVENV_ALLOWLIST:-/etc/devenv/allowlist.txt}"
SETNAME="devenv-allow"

# What arrived at the mount point decides the message. A directory here means
# the launcher was handed a directory as the mount source, and saying so beats
# reporting an empty allowlist further down, which reads like a DNS problem.
if [ -d "$ALLOWLIST" ]; then
    echo "devenv: $ALLOWLIST is a directory, not a file." >&2
    echo "devenv: the allowlist is bind-mounted as a file, so the mount source" >&2
    echo "devenv: on the host was a directory. Nothing was read." >&2
    exit 1
elif [ ! -e "$ALLOWLIST" ]; then
    echo "devenv: no allowlist at $ALLOWLIST" >&2
    exit 1
elif [ ! -f "$ALLOWLIST" ]; then
    echo "devenv: $ALLOWLIST is not a regular file." >&2
    exit 1
elif [ ! -r "$ALLOWLIST" ]; then
    echo "devenv: $ALLOWLIST is not readable." >&2
    exit 1
fi

iptables -F OUTPUT
ipset destroy "$SETNAME" 2>/dev/null || true
ipset create "$SETNAME" hash:net

resolved=0
skipped=""

while IFS= read -r line || [ -n "$line" ]; do
    host=$(printf '%s' "$line" | sed 's/#.*//' | tr -d '[:space:]')
    [ -z "$host" ] && continue

    # A literal address or CIDR goes in as-is.
    case "$host" in
        *[!0-9./]*) ;;
        *) ipset add "$SETNAME" "$host" 2>/dev/null && resolved=$((resolved + 1))
           continue ;;
    esac

    found=0
    for ip in $(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}' | sort -u); do
        ipset add "$SETNAME" "$ip" 2>/dev/null || true
        found=1
    done

    if [ "$found" -eq 1 ]; then
        resolved=$((resolved + 1))
    else
        skipped="$skipped $host"
    fi
done < "$ALLOWLIST"

if [ "$resolved" -eq 0 ]; then
    echo "devenv: allowlist resolved to nothing; refusing to apply an empty filter." >&2
    exit 1
fi

# Loopback, DNS, and replies to connections this container opened.
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

iptables -A OUTPUT -m set --match-set "$SETNAME" dst -j ACCEPT
iptables -A OUTPUT -m limit --limit 10/min -j LOG --log-prefix "devenv-deny: "
iptables -A OUTPUT -j REJECT --reject-with icmp-port-unreachable

echo "devenv: egress filter active ($resolved entries allowed)"
[ -n "$skipped" ] && echo "devenv: could not resolve:$skipped" >&2

# ---------------------------------------------------------------------------
# IPv6
#
# The allowlist above is resolved to A records only, so any IPv6 route out of
# this container is an unfiltered one. Close the outbound direction wholesale
# instead of maintaining a second, parallel allowlist: every host in the list
# is reachable over IPv4, and a second path out is only a second thing to get
# wrong.
#
# Only OUTPUT is touched, matching the IPv4 rules above. INPUT and FORWARD are
# left alone so a dev server inside the container stays reachable over IPv6.
# ---------------------------------------------------------------------------

# Is there a way out over IPv6 at all? Used only to decide how loudly to
# complain when the filter cannot be applied.
ipv6_has_route() {
    [ -n "$(ip -6 route show default 2>/dev/null)" ] && return 0
    [ -n "$(ip -6 addr show scope global 2>/dev/null)" ] && return 0
    return 1
}

if [ ! -e /proc/net/if_inet6 ]; then
    echo "devenv: no IPv6 stack in this kernel; nothing to filter"
elif ip6tables -F OUTPUT 2>/dev/null; then
    ip6tables -A OUTPUT -o lo -j ACCEPT
    ip6tables -A OUTPUT -m limit --limit 10/min -j LOG --log-prefix "devenv-deny6: "
    # REJECT rather than DROP: a client that tries IPv6 first gets an
    # immediate error and falls back to IPv4, instead of sitting out a
    # connect timeout on every request.
    ip6tables -A OUTPUT -j REJECT --reject-with icmp6-adm-prohibited
    echo "devenv: IPv6 egress closed (loopback only)"
elif ipv6_has_route; then
    echo "devenv: IPv6 is enabled and this container has a route out, but" >&2
    echo "devenv: ip6tables cannot be programmed. Refusing to start with an" >&2
    echo "devenv: unfiltered IPv6 path. Rerun with --open to start anyway." >&2
    exit 1
else
    echo "devenv: ip6tables unavailable; IPv6 left unfiltered." >&2
    echo "devenv: no global IPv6 address and no default route, so there is no" >&2
    echo "devenv: path out - but that is the host's network configuration," >&2
    echo "devenv: not a property of this image." >&2
fi

exit 0
