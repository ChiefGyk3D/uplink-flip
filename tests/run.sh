#!/usr/bin/env bash
# Plain-bash tests for uplink-flip. A recording fake nmcli, ip and curl sit
# first on PATH; nothing here touches a real NetworkManager.
# Usage: tests/run.sh [name-filter]
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${UPLINK_FLIP_SCRIPT:-$HERE/../uplink-flip}"
FILTER="${1:-}"
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

PASS=0
FAIL=0
CUR=""

# Fixture identities (documentation addresses only).
E=11111111-1111-1111-1111-111111111111 # ethernet
W=22222222-2222-2222-2222-222222222222 # wifi
G=33333333-3333-3333-3333-333333333333 # gsm
E_NAME="Wired connection 1"

fail() {
    FAIL=$((FAIL + 1))
    printf 'FAIL %s: %s\n' "$CUR" "$*"
}
pass() { PASS=$((PASS + 1)); }

assert_eq() { # label expected actual
    if [[ "$2" == "$3" ]]; then pass; else fail "$1: expected [$2] got [$3]"; fi
}
assert_contains() { # label haystack needle
    if [[ "$2" == *"$3"* ]]; then pass; else fail "$1: [$3] not found in [$2]"; fi
}
assert_not_contains() {
    if [[ "$2" != *"$3"* ]]; then pass; else fail "$1: [$3] unexpectedly found"; fi
}
assert_file_missing() { if [[ ! -e "$2" ]]; then pass; else fail "$1: $2 exists"; fi; }

new_env() {
    T="$ROOT/$CUR"
    rm -rf "$T"
    mkdir -p "$T/fake/conn" "$T/home" "$T/ran"
    export FAKE_DIR="$T/fake" HOME="$T/home"
    export XDG_STATE_HOME="$T/state" XDG_CONFIG_HOME="$T/config"
    export PATH="$HERE/fakes:$ORIG_PATH"
    unset UPLINK_FLIP_ETHERNET UPLINK_FLIP_WIFI UPLINK_FLIP_GSM UPLINK_FLIP_CONFIG \
        UPLINK_FLIP_CHECK_URL UPLINK_FLIP_CHECK_TIMEOUT UPLINK_FLIP_DEMOTE_METRIC \
        FAKE_FAIL_MATCH FAKE_FAIL_ONCE FAKE_SLEEP_MATCH FAKE_CURL_RC
    STATE="$XDG_STATE_HOME/uplink-flip/state"
    printf '%s:802-3-ethernet:eth0:%s\n%s:802-11-wireless:wlan0:Home Wifi\n%s:gsm:wwan0:my-cell\n' \
        "$E" "$E_NAME" "$W" "$G" >"$FAKE_DIR/active"
    # Originals: ethernet is stock; wifi carries a custom metric.
    printf 'no\n-1\nno\n-1\n' >"$FAKE_DIR/conn/$E"
    printf 'no\n700\nno\n700\n' >"$FAKE_DIR/conn/$W"
    printf 'no\n-1\nno\n-1\n' >"$FAKE_DIR/conn/$G"
    cat >"$FAKE_DIR/routes4" <<'R'
default via 192.0.2.1 dev eth0 proto dhcp metric 100
default via 192.0.2.2 dev wlan0 proto dhcp metric 700
default via 198.51.100.1 dev wwan0 proto static metric 1100
R
    : >"$FAKE_DIR/routes6"
    # Route table after each "device reapply" / "connection up" (1st, 2nd, ...).
    echo 'default via 198.51.100.1 dev wwan0 proto static metric 1100' >"$FAKE_DIR/routes4.1"
    cp "$FAKE_DIR/routes4.1" "$FAKE_DIR/routes4.2"
}

# Run the script: sets OUT ERR RC. The nmcli log is reset first.
run() {
    : >"$FAKE_DIR/nmcli.log"
    OUT="$("$SCRIPT" "$@" 2>"$T/err")"
    RC=$?
    ERR="$(cat "$T/err")"
}

conn() { paste -sd' ' "$FAKE_DIR/conn/$1"; }
calls() { cat "$FAKE_DIR/nmcli.log"; }
modifying_calls() { grep -E '^nmcli \[(connection\] \[(modify|up)|device\] \[reapply)\]' "$FAKE_DIR/nmcli.log" || true; }
mode_of() { stat -c '%a' "$1"; }
orig_routes() { cp "$FAKE_DIR/routes4" "$FAKE_DIR/routes4.$1"; }

LIST='nmcli [-t] [--escape] [no] [-f] [UUID,TYPE,DEVICE,NAME] [connection] [show] [--active]'
rd() { printf 'nmcli [-g] [ipv4.never-default,ipv4.route-metric,ipv6.never-default,ipv6.route-metric] [connection] [show] [uuid] [%s]\n' "$1"; }
mod() { # uuid v4nd v4m v6nd v6m
    printf 'nmcli [connection] [modify] [uuid] [%s] [ipv4.never-default] [%s] [ipv6.never-default] [%s] [ipv4.route-metric] [%s] [ipv6.route-metric] [%s]\n' "$1" "$2" "$4" "$3" "$5"
}
reapply() { printf 'nmcli [device] [reapply] [%s]\n' "$1"; }
up() { printf 'nmcli [connection] [up] [uuid] [%s]\n' "$1"; }

# ----------------------------------------------------------------- tests

t_cell_exact_calls_and_state() {
    run cell
    assert_eq "exit" 0 "$RC"
    expected="$(
        echo "$LIST"
        rd "$E"
        rd "$W"
        rd "$E"
        rd "$W"
        mod "$E" yes 2000 yes 2000
        reapply eth0
        mod "$W" yes 2000 yes 2000
        reapply wlan0
    )"
    assert_eq "exact nmcli argument lists" "$expected" "$(calls)"
    assert_eq "ethernet values" "yes 2000 yes 2000" "$(conn "$E")"
    assert_eq "wifi values" "yes 2000 yes 2000" "$(conn "$W")"
    assert_eq "gsm untouched" "no -1 no -1" "$(conn "$G")"
    expected_state="# uplink-flip state v1
conn $E no -1 no -1 eth0
conn $W no 700 no 700 wlan0"
    assert_eq "state content (originals)" "$expected_state" "$(cat "$STATE")"
}

t_state_file_modes() {
    umask 022
    run cell
    assert_eq "state dir mode" 700 "$(mode_of "$XDG_STATE_HOME/uplink-flip")"
    assert_eq "state file mode" 600 "$(mode_of "$STATE")"
    assert_eq "no temp files left" "lock
state" "$(ls "$XDG_STATE_HOME/uplink-flip")"
}

t_cell_twice_is_noop() {
    run cell
    cp "$STATE" "$T/state.first"
    run cell
    assert_eq "exit" 0 "$RC"
    assert_eq "second run changes nothing" "" "$(modifying_calls)"
    assert_contains "says nothing to do" "$OUT" "Nothing to do"
    if cmp -s "$STATE" "$T/state.first"; then pass; else fail "state changed on second cell"; fi
    assert_contains "originals kept" "$(cat "$STATE")" "conn $W no 700 no 700 wlan0"
}

t_second_cell_keeps_originals_when_live_values_reset() {
    run cell
    cp "$STATE" "$T/state.first"
    # Simulate the profile being reset behind our back (still recorded).
    printf 'no\n-1\nno\n-1\n' >"$FAKE_DIR/conn/$E"
    run cell
    assert_eq "exit" 0 "$RC"
    assert_eq "ethernet re-applied" "yes 2000 yes 2000" "$(conn "$E")"
    if cmp -s "$STATE" "$T/state.first"; then pass; else fail "originals were overwritten"; fi
    assert_not_contains "wifi not touched again" "$(modifying_calls)" "$W"
}

t_normal_restores_exactly() {
    run cell
    run normal
    assert_eq "exit" 0 "$RC"
    assert_eq "ethernet restored" "no -1 no -1" "$(conn "$E")"
    assert_eq "wifi restored exactly" "no 700 no 700" "$(conn "$W")"
    assert_file_missing "state removed" "$STATE"
    expected="$(
        echo "$LIST"
        mod "$E" no -1 no -1
        reapply eth0
        mod "$W" no 700 no 700
        reapply wlan0
    )"
    assert_eq "exact nmcli argument lists" "$expected" "$(calls | grep -v -F -e '[-g] [connection.uuid]')"
}

t_normal_twice_is_noop() {
    run cell
    run normal
    run normal
    assert_eq "exit" 0 "$RC"
    assert_eq "no changes" "" "$(modifying_calls)"
    assert_contains "message" "$OUT" "Nothing to restore"
}

t_dry_run_cell() {
    run --dry-run cell
    assert_eq "exit" 0 "$RC"
    assert_eq "no modifying nmcli calls" "" "$(modifying_calls)"
    assert_contains "prints modify" "$OUT" "+ nmcli connection modify uuid $E ipv4.never-default yes ipv6.never-default yes ipv4.route-metric 2000 ipv6.route-metric 2000"
    assert_contains "prints reapply" "$OUT" "+ nmcli device reapply wlan0"
    assert_file_missing "no state file" "$STATE"
    assert_file_missing "no state dir" "$XDG_STATE_HOME/uplink-flip"
    assert_eq "values unchanged" "no 700 no 700" "$(conn "$W")"
}

t_dry_run_normal() {
    run cell
    cp "$STATE" "$T/state.first"
    run --dry-run normal
    assert_eq "exit" 0 "$RC"
    assert_eq "no modifying nmcli calls" "" "$(modifying_calls)"
    assert_contains "prints restore" "$OUT" "+ nmcli connection modify uuid $W ipv4.never-default no ipv6.never-default no ipv4.route-metric 700 ipv6.route-metric 700"
    if cmp -s "$STATE" "$T/state.first"; then pass; else fail "dry-run normal changed the state"; fi
    assert_eq "values still cell" "yes 2000 yes 2000" "$(conn "$W")"
}

t_rollback_on_failure_midway() {
    # The wifi profile change fails after ethernet was already demoted. After
    # the rollback the original route table is back.
    export FAKE_FAIL_MATCH="uuid $W" FAKE_FAIL_ONCE=1
    orig_routes 2
    orig_routes 3
    run cell
    assert_eq "exit" 1 "$RC"
    assert_eq "ethernet back" "no -1 no -1" "$(conn "$E")"
    assert_eq "wifi back" "no 700 no 700" "$(conn "$W")"
    assert_file_missing "state dropped after clean rollback" "$STATE"
    if [[ -s "$FAKE_DIR/routes4" ]]; then pass; else fail "no default route left"; fi
    assert_contains "route restored" "$(cat "$FAKE_DIR/routes4")" "dev eth0"
    assert_contains "says rolling back" "$ERR" "rolling back"
    assert_contains "rollback modify for ethernet" "$(calls)" "$(mod "$E" no -1 no -1)"
}

t_rollback_failure_prints_recovery() {
    export FAKE_FAIL_MATCH="uuid $W"
    run cell
    assert_eq "exit" 4 "$RC"
    assert_contains "recovery command" "$ERR" "nmcli connection modify uuid $W ipv4.never-default no ipv6.never-default no ipv4.route-metric 700 ipv6.route-metric 700"
    assert_contains "state kept" "$ERR" "state file"
    if [[ -f "$STATE" ]]; then pass; else fail "state must survive a failed rollback"; fi
}

t_no_default_route_after_change_rolls_back() {
    : >"$FAKE_DIR/routes4.1"
    : >"$FAKE_DIR/routes4.2"
    orig_routes 3
    orig_routes 4
    run cell
    assert_eq "exit" 1 "$RC"
    assert_contains "reason" "$ERR" "no default route left"
    assert_eq "ethernet back" "no -1 no -1" "$(conn "$E")"
    if [[ -s "$FAKE_DIR/routes4" ]]; then pass; else fail "no default route left"; fi
}

t_fallback_reactivates_when_reapply_does_not_move_route() {
    # Reapply succeeds but the route table does not change; the documented
    # reactivation of that one connection (ethernet) fixes it.
    orig_routes 1
    orig_routes 2
    echo 'default via 198.51.100.1 dev wwan0 proto static metric 1100' >"$FAKE_DIR/routes4.3"
    run cell
    assert_eq "exit" 0 "$RC"
    assert_contains "warns" "$ERR" "reactivating that connection"
    assert_contains "reactivated ethernet" "$(modifying_calls)" "$(up "$E")"
    assert_not_contains "wifi not reactivated" "$(modifying_calls)" "$(up "$W")"
    assert_eq "ethernet kept cell values" "yes 2000 yes 2000" "$(conn "$E")"
}

t_fallback_failure_rolls_back() {
    orig_routes 1
    orig_routes 2
    orig_routes 3
    orig_routes 4
    orig_routes 5
    run cell
    assert_eq "exit" 1 "$RC"
    assert_contains "reason" "$ERR" "still goes through eth0"
    assert_eq "ethernet back" "no -1 no -1" "$(conn "$E")"
    assert_eq "wifi back" "no 700 no 700" "$(conn "$W")"
    assert_file_missing "state dropped" "$STATE"
    if [[ -s "$FAKE_DIR/routes4" ]]; then pass; else fail "no default route left"; fi
}

t_reapply_failure_falls_back_to_reactivation() {
    export FAKE_FAIL_MATCH="reapply wlan0"
    run cell
    assert_eq "exit" 0 "$RC"
    assert_contains "warns" "$ERR" "device reapply failed"
    assert_contains "reactivated wifi" "$(modifying_calls)" "$(up "$W")"
}

t_signal_midway_rolls_back() {
    export FAKE_SLEEP_MATCH="reapply wlan0"
    orig_routes 3
    orig_routes 4
    "$SCRIPT" cell >"$T/out" 2>"$T/err" &
    pid=$!
    for _ in $(seq 1 50); do
        [[ -e "$FAKE_DIR/sleeping" ]] && break
        sleep 0.1
    done
    kill -TERM "$pid"
    wait "$pid"
    RC=$?
    assert_eq "exit (128+TERM)" 143 "$RC"
    assert_eq "ethernet back" "no -1 no -1" "$(conn "$E")"
    assert_eq "wifi back" "no 700 no 700" "$(conn "$W")"
    assert_file_missing "state dropped" "$STATE"
}

t_refuse_without_gsm() {
    printf '%s:802-3-ethernet:eth0:%s\n' "$E" "$E_NAME" >"$FAKE_DIR/active"
    run cell
    assert_eq "exit" 3 "$RC"
    assert_contains "message" "$ERR" "no active gsm connection"
    assert_eq "no changes" "" "$(modifying_calls)"
    assert_file_missing "no state" "$STATE"
}

t_refuse_gsm_without_own_gateway() {
    cat >"$FAKE_DIR/routes4" <<'R'
default via 192.0.2.1 dev eth0 proto dhcp metric 100
198.51.100.0/24 dev wwan0 scope link
default dev wwan0 scope link metric 1100
R
    run cell
    assert_eq "exit" 3 "$RC"
    assert_contains "message" "$ERR" "no default route with its own gateway"
    assert_eq "no changes" "" "$(modifying_calls)"
}

t_names_with_spaces_and_metacharacters() {
    # shellcheck disable=SC2016 # literal text on purpose
    nasty='Wired $(touch PWNED); `id` "q" '"'"'s'"'"' * \ a:b'
    printf '%s:802-3-ethernet:eth0:%s\n%s:gsm:wwan0:my cell $(x)\n' "$E" "$nasty" "$G" >"$FAKE_DIR/active"
    (cd "$T/ran" && "$SCRIPT" cell >"$T/out" 2>"$T/err")
    RC=$?
    assert_eq "exit" 0 "$RC"
    assert_file_missing "no command executed" "$T/ran/PWNED"
    assert_contains "uuid used in call" "$(calls)" "$(mod "$E" yes 2000 yes 2000)"
    assert_contains "name shown verbatim" "$(cat "$T/out")" "Demoting '$nasty'"
    # Override by the same nasty name selects only that connection.
    run normal
    printf '%s:802-3-ethernet:eth0:%s\n%s:802-3-ethernet:eth1:other\n%s:gsm:wwan0:my-cell\n' "$E" "$nasty" "$W" "$G" >"$FAKE_DIR/active"
    UPLINK_FLIP_ETHERNET="$nasty" run cell
    assert_eq "override exit" 0 "$RC"
    assert_contains "named one changed" "$(modifying_calls)" "[$E]"
    assert_not_contains "other ethernet untouched" "$(modifying_calls)" "[$W]"
}

t_control_characters_in_name_are_skipped() {
    local esc
    printf -v esc '\033'
    printf '%s:802-3-ethernet:eth0:Wired%s[31m\n%s:gsm:wwan0:my-cell\n' "$E" "$esc" "$G" >"$FAKE_DIR/active"
    run cell
    assert_eq "exit" 0 "$RC"
    assert_contains "warning" "$ERR" "skipping a connection"
    assert_eq "nothing modified" "" "$(modifying_calls)"
}

t_config_file_and_env_precedence() {
    mkdir -p "$XDG_CONFIG_HOME/uplink-flip"
    printf '# comment\nDEMOTE_METRIC=3000\nCHECK_URL="http://192.0.2.9/ok"\n' >"$XDG_CONFIG_HOME/uplink-flip/config"
    run cell
    assert_eq "exit" 0 "$RC"
    assert_contains "config metric used" "$(modifying_calls)" "[ipv4.route-metric] [3000]"
    run normal
    UPLINK_FLIP_DEMOTE_METRIC=2500 run cell
    assert_contains "env beats config" "$(modifying_calls)" "[ipv4.route-metric] [2500]"
    run status
    assert_contains "config check url" "$(cat "$FAKE_DIR/curl.log")" "[http://192.0.2.9/ok]"
}

t_config_file_rejects_unknown_key() {
    mkdir -p "$XDG_CONFIG_HOME/uplink-flip"
    echo 'EVIL=$(touch x)' >"$XDG_CONFIG_HOME/uplink-flip/config"
    run status
    assert_eq "exit" 2 "$RC"
    assert_contains "message" "$ERR" "unknown key"
}

t_status() {
    run status
    assert_eq "exit" 0 "$RC"
    assert_contains "routes" "$OUT" "IPv4 default via 192.0.2.1 dev eth0 metric 100"
    assert_contains "winner" "$OUT" "IPv4: $E_NAME (device eth0)"
    assert_contains "settings" "$OUT" "Home Wifi [wifi] device wlan0: ipv4 never-default=no route-metric=700"
    assert_contains "gsm settings" "$OUT" "my-cell [gsm] device wwan0"
    assert_contains "cell off" "$OUT" "cell mode is off"
    assert_contains "check section" "$OUT" "== connectivity check (separate from the settings above) =="
    assert_contains "check ok" "$OUT" "ok: http://nmcheck.gnome.org/check_network_status.txt answered within 5s"
    assert_eq "curl args" "curl [-fsS] [-o] [/dev/null] [--max-time] [5] [--] [http://nmcheck.gnome.org/check_network_status.txt]" "$(cat "$FAKE_DIR/curl.log")"
    assert_eq "status changes nothing" "" "$(modifying_calls)"
    run cell
    run status
    assert_contains "winner after cell" "$OUT" "IPv4: my-cell (device wwan0)"
    assert_contains "cell on" "$OUT" "cell mode is on"
}

t_status_connectivity_failure() {
    export FAKE_CURL_RC=28
    run status
    assert_eq "exit" 5 "$RC"
    assert_contains "message" "$OUT" "FAILED"
    UPLINK_FLIP_CHECK_URL="" run status
    assert_eq "disabled check exit" 0 "$RC"
    assert_contains "disabled" "$OUT" "disabled"
}

t_usage() {
    run
    assert_eq "no mode" 2 "$RC"
    run bogus
    assert_eq "unknown argument" 2 "$RC"
    run cell normal
    assert_eq "two modes" 2 "$RC"
    run --help
    assert_eq "help exit" 0 "$RC"
    assert_contains "documents exit codes" "$OUT" "Exit codes:"
    assert_eq "help changes nothing" "" "$(modifying_calls)"
}

t_corrupt_state_refused() {
    mkdir -p "$XDG_STATE_HOME/uplink-flip"
    printf '# uplink-flip state v1\nconn not-a-uuid no -1 no -1 eth0\n' >"$XDG_STATE_HOME/uplink-flip/state"
    run normal
    assert_eq "exit" 1 "$RC"
    assert_contains "message" "$ERR" "corrupt"
    assert_eq "nothing modified" "" "$(modifying_calls)"
}

t_normal_partial_failure_keeps_state() {
    run cell
    export FAKE_FAIL_MATCH="uuid $W"
    run normal
    assert_eq "exit" 4 "$RC"
    assert_eq "ethernet restored" "no -1 no -1" "$(conn "$E")"
    assert_contains "recovery" "$ERR" "nmcli connection modify uuid $W"
    assert_eq "only the failed one stays" "# uplink-flip state v1
conn $W no 700 no 700 wlan0" "$(cat "$STATE")"
}

# ----------------------------------------------------------------- driver

ORIG_PATH="$PATH"
umask 022
for CUR in $(declare -F | awk '$3 ~ /^t_/ {print $3}'); do
    [[ -z "$FILTER" || "$CUR" == *"$FILTER"* ]] || continue
    new_env
    before=$FAIL
    ( # each test in a subshell so env and umask do not leak
        "$CUR"
        echo "$PASS $FAIL" >"$T/counts"
    )
    if read -r p f <"$T/counts" 2>/dev/null; then
        PASS=$p FAIL=$f
    else
        fail "test aborted"
    fi
    if ((FAIL == before)); then printf 'ok   %s\n' "$CUR"; fi
done

printf '\n%d assertions passed, %d failed\n' "$PASS" "$FAIL"
if ((PASS == 0)); then
    echo "no assertions ran"
    exit 1
fi
((FAIL == 0))
