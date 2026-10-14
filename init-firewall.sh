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

# ---------------------------------------------------------------------------
# Host ports (devenv --host-port)
#
# Each port is opened to the host's gateway address alone, one rule per port.
# Listing the gateway in the allowlist instead would put it in the ipset, and
# the set matches addresses, not ports: every service on the host - sshd, a
# database, a docker API on tcp - would be open to the session.
#
# The ports are checked again here although the launcher has checked them. This
# script runs as root, before privileges are dropped, and its input is an
# environment variable that anything starting the container can set - a
# hand-written docker run, another launcher. A value is checked by the code
# that hands it to iptables.
#
# The address comes from /etc/hosts and nowhere else - not from DNS. The entry
# there is what docker writes for --add-host=host.docker.internal:host-gateway,
# the launcher's own flag, and it is the only answer that means "this host's
# bridge". DNS answers for any name it is asked about: docker's resolver
# forwards unknown names to the host's, and on Docker Desktop or WSL that
# resolver knows host.docker.internal by itself - seen answering 127.0.0.1 for
# a container started without --add-host. Whatever address DNS gives, the
# ports would be opened to it, including one outside this machine.
#
# The address must also be private (RFC 1918). host-gateway is the address of
# docker's bridge, which is always in one of those ranges; loopback, 0.0.0.0 or
# a public address means the entry did not come from --add-host, or was
# changed, and opening ports to it would open them somewhere nobody chose.
#
# All of it is checked and resolved before the first rule is touched, so a bad
# value stops the container instead of leaving a half-built filter behind.
# ---------------------------------------------------------------------------
HOST_NAME="host.docker.internal"
host_ports=""
host_addr=""

bad_host_ports() {
    echo "devenv: DEVENV_HOST_PORTS='$DEVENV_HOST_PORTS': $1" >&2
    echo "devenv: expected ports from 1 to 65535, separated by spaces." >&2
    exit 1
}

# True for a dotted-quad IPv4 address in 10/8, 172.16/12 or 192.168/16. Strict
# about the form as well: a leading zero makes an octet octal to inet_aton, so
# 172.017.0.1 is not the address it looks like and is refused outright.
is_private_ipv4() {
    case "$1" in
        *[!0-9.]*|.*|*.|*..*) return 1 ;;
    esac
    # Digits and dots only, so splitting on '.' does nothing but split.
    old_ifs=$IFS
    IFS=.
    set -- $1
    IFS=$old_ifs
    [ $# -eq 4 ] || return 1
    for octet in "$@"; do
        case "$octet" in
            0?*) return 1 ;;
        esac
        [ ${#octet} -le 3 ] && [ "$octet" -le 255 ] || return 1
    done
    case "$1" in
        10)  return 0 ;;
        172) [ "$2" -ge 16 ] && [ "$2" -le 31 ] ;;
        192) [ "$2" -eq 168 ] ;;
        *)   return 1 ;;
    esac
}

# Every address /etc/hosts gives the name, one per line. IPv6 entries are left
# out: the filter is IPv4, and IPv6 egress is closed wholesale further down.
hosts_entries() {
    awk -v name="$1" '
        { sub(/#.*/, "") }
        $1 ~ /:/ { next }
        { for (i = 2; i <= NF; i++) if (tolower($i) == name) { print $1; next } }
    ' /etc/hosts 2>/dev/null | sort -u
}

if [ -n "${DEVENV_HOST_PORTS:-}" ]; then
    # Digits and spaces only, so the unquoted expansion below can split into
    # words and do nothing else - no globbing, no options.
    case "$DEVENV_HOST_PORTS" in
        *[!0-9\ ]*) bad_host_ports "holds something other than digits and spaces." ;;
    esac
    for port in $DEVENV_HOST_PORTS; do
        case "$port" in
            0*) bad_host_ports "'$port' has a leading zero or is zero." ;;
        esac
        if [ ${#port} -gt 5 ] || [ "$port" -gt 65535 ]; then
            bad_host_ports "'$port' is above 65535."
        fi
        case " $host_ports " in
            *" $port "*) ;;
            *) host_ports="${host_ports:+$host_ports }$port" ;;
        esac
    done
    [ -n "$host_ports" ] || bad_host_ports "no ports in it."

    host_addr=$(hosts_entries "$HOST_NAME")
    case "$host_addr" in
        '')
            echo "devenv: DEVENV_HOST_PORTS is set, but /etc/hosts has no IPv4 entry" >&2
            echo "devenv: for $HOST_NAME. The launcher adds one with" >&2
            echo "devenv: --add-host=$HOST_NAME:host-gateway, so this container was" >&2
            echo "devenv: started some other way. No host ports are opened." >&2
            exit 1 ;;
        *"
"*)
            echo "devenv: /etc/hosts gives $HOST_NAME more than one address:" >&2
            echo "devenv: $(printf '%s' "$host_addr" | tr '\n' ' '). One of them is not from --add-host, and" >&2
            echo "devenv: there is no telling which. No host ports are opened." >&2
            exit 1 ;;
    esac
    if ! is_private_ipv4 "$host_addr"; then
        echo "devenv: /etc/hosts gives $HOST_NAME as '$host_addr', which is not a" >&2
        echo "devenv: private (RFC 1918) IPv4 address. host-gateway is always one, so" >&2
        echo "devenv: the entry did not come from --add-host or was changed." >&2
        echo "devenv: No host ports are opened." >&2
        exit 1
    fi
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
for port in $host_ports; do
    iptables -A OUTPUT -d "$host_addr" -p tcp --dport "$port" -j ACCEPT
done
iptables -A OUTPUT -m limit --limit 10/min -j LOG --log-prefix "devenv-deny: "
iptables -A OUTPUT -j REJECT --reject-with icmp-port-unreachable

echo "devenv: egress filter active ($resolved entries allowed)"
[ -n "$skipped" ] && echo "devenv: could not resolve:$skipped" >&2
if [ -n "$host_ports" ]; then
    echo "devenv: host access: $host_addr$(for port in $host_ports; do printf ' tcp/%s' "$port"; done)"
fi

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
