# uplink-flip

A small bash tool for Linux machines managed by NetworkManager. When your
ethernet or wifi uplink is down, it makes the cellular modem (a NetworkManager
`gsm` connection) carry the default route, keeps the other connections up for
their local subnets, and flips everything back when you ask.

It needs only bash, `nmcli`, `ip` and (for `status`) `curl`. It never uses
`sudo`: your user must be allowed to modify its own connections, which is the
normal case on a desktop.

By hand this is the same as:

```sh
nmcli connection modify "Wired connection 1" ipv4.never-default yes ipv6.never-default yes \
    ipv4.route-metric 2000 ipv6.route-metric 2000
# and back:
nmcli connection modify "Wired connection 1" ipv4.never-default no ipv6.never-default no \
    ipv4.route-metric -1 ipv6.route-metric -1
```

uplink-flip does that for every active ethernet and wifi connection, remembers
what each one had before, and restores exactly that.

## Install

```sh
install -m 0755 uplink-flip ~/.local/bin/uplink-flip
```

Anywhere on your `PATH` works. Run `uplink-flip --help` for the summary.

## Usage

```sh
uplink-flip status            # look first: routes, winner, settings, connectivity check
uplink-flip --dry-run cell    # print the nmcli commands, change nothing
uplink-flip cell              # cellular carries the default route
uplink-flip normal            # restore the saved values
```

| Mode | What it does |
|---|---|
| `cell` | Needs an active gsm connection that has its own default route with a gateway. Saves each ethernet/wifi connection's current `never-default` and `route-metric` (IPv4 and IPv6), then sets `never-default yes` and a high route metric (default 2000) on them and applies it. Checks the result and rolls back if it is wrong. |
| `normal` | Writes the saved values back exactly, applies them, and removes the state file. |
| `status` | Shows default routes with metrics, which connection carries them, each connection's settings, the saved-state summary, and then, under its own heading, one bounded connectivity check. |
| `--dry-run` | With `cell` or `normal`: prints every `nmcli` command that would change something (prefixed with `+`) and changes nothing. Read-only calls still run. |

Running a mode twice is a no-op the second time. A second `cell` never
overwrites the saved originals with already-changed values.

### Exit codes

| Code | Meaning |
|---|---|
| 0 | Success, including "nothing to do". |
| 1 | Runtime error. Any partial change was rolled back. |
| 2 | Usage or configuration error. |
| 3 | Refused: a precondition is not met (for example no active gsm connection with its own gateway). Nothing was changed. |
| 4 | Rollback or restore failed. Exact manual recovery commands were printed. |
| 5 | `status` only: the connectivity check failed. |

## How it relates to NetworkManager metrics

Every connection's default route has a metric, and the kernel uses the lowest.
NetworkManager picks them by device type unless `ipv4.route-metric` /
`ipv6.route-metric` says otherwise (`-1` means automatic): about 100 for
ethernet, 600 for wifi and 1100 for gsm. So ethernet normally wins and the
modem is only a backup that never carries traffic.

`ipv4.never-default yes` (and the IPv6 twin) tells NetworkManager never to give
that connection the default route at all, while it keeps its address and its
local subnet route. uplink-flip sets both `never-default yes` and a high metric
(2000, above the modem's 1100) on the other connections, so the modem wins even
if the never-default part has not taken effect yet.

Only connections that are active when you run `cell` are touched. A connection
that comes up later keeps its own settings until you run `cell` again (which
adds it to the saved state without disturbing the originals already saved).

## How changes are applied (and one thing that is not verified)

`nmcli connection modify uuid ... ` edits the saved profile. To make an active
connection pick that up, uplink-flip runs `nmcli device reapply DEVICE`, which
the nmcli manual describes as attempting to "update device with changes to the
currently active connection made since it was last applied". It does not
disconnect the device.

**Tested once on a real machine.** On a laptop with wifi and a USB modem
(NetworkManager 1.52.1, Debian-family Linux), `cell` demoted the wifi
connection (`never-default yes`, `route-metric 2000`, IPv4 and IPv6) and
`nmcli device reapply` on the wifi device was enough: the kernel's default
routes became only the modem's (IPv4 and IPv6), a real HTTPS request worked
over the modem, and `status` named the modem connection for both defaults.
`normal` restored the exact previous values (a before and after capture of
every connection's settings and every default route was identical), and a
second `normal` changed nothing. Two wifi profiles with the same name were
handled because connections are addressed by UUID.

Because the documentation does not promise that `device reapply` covers route
changes on every NetworkManager version, `cell` still does not trust it: after
applying, it reads the real default routes with `ip route show default`. If the
gsm device does not win, it falls back to the documented reactivation
(`nmcli connection up uuid ...`, which briefly drops and re-establishes that
one connection) for the connection still carrying the default route, then
checks again. If the gsm device still does not win, or no default route is
left, everything is rolled back.

**Not tested** on real hardware: the `connection up` reactivation fallback
(reapply worked, so it never ran), IPv6-only setups, setups with more than one
modem, and distributions other than Debian-family. If you try one of these,
please check `uplink-flip status` afterwards and report what you see.

## Safety notes

- Refuses to run unless a gsm connection is active with its own default route
  and gateway, so there is always a default route when it starts.
- The gsm connection is never modified, so its default route stays in place
  throughout.
- After the change it verifies that a default route still exists and that the
  gsm device carries the winning one. A failure, an error, Ctrl-C or SIGTERM
  mid-change triggers a rollback to the values read just before the change.
- If rollback itself fails it prints exact `nmcli connection modify uuid ...`
  commands to run by hand, keeps the state file, and exits 4.
- Originals are written to the state file before anything is changed, so even
  a killed process (SIGKILL, power loss) can be undone with `uplink-flip normal`.
- Connections are addressed by UUID, never by name, in every nmcli call. Names
  and device names read from `nmcli` are validated, values are quoted, nothing
  is `eval`ed and the config file is never sourced.

## Configuration

Everything is optional. Precedence: environment, then config file, then
auto-detection by connection type (ethernet, wifi, gsm).

| Environment variable | Config key | Meaning |
|---|---|---|
| `UPLINK_FLIP_ETHERNET` | `ETHERNET` | Name or UUID of the one ethernet connection to demote (default: all active ethernet). |
| `UPLINK_FLIP_WIFI` | `WIFI` | Same for wifi. |
| `UPLINK_FLIP_GSM` | `GSM` | Which connection is the cellular one (needed if more than one gsm connection is active). |
| `UPLINK_FLIP_CHECK_URL` | `CHECK_URL` | `status` connectivity target. Default is NetworkManager's own check host (see below). Empty skips the check (no request is made). |
| `UPLINK_FLIP_CHECK_TIMEOUT` | `CHECK_TIMEOUT` | Seconds for the whole request (default 5). |
| `UPLINK_FLIP_DEMOTE_METRIC` | `DEMOTE_METRIC` | Metric given to demoted connections (default 2000; keep it above the modem's). |
| `UPLINK_FLIP_CONFIG` | | Config file path. Default `$XDG_CONFIG_HOME/uplink-flip/config` (`~/.config/uplink-flip/config`). |

The config file is `KEY=VALUE` lines with `#` comments; unknown keys are an
error. Example:

```
# ~/.config/uplink-flip/config
GSM=my-cell
DEMOTE_METRIC=2000
```

State is stored in `$XDG_STATE_HOME/uplink-flip/state`
(`~/.local/state/uplink-flip/state`): directory mode 700, state file and lock file mode 600,
state written atomically.

## Troubleshooting

- **"no active gsm connection found"**: bring the modem connection up first
  (`nmcli connection up my-cell`), or set `GSM` if its type is not `gsm`.
- **"has no default route with its own gateway"**: some modems give a
  point-to-point route (`default dev wwan0`) with no `via`. This tool requires
  a gateway so it can be sure the modem can really carry traffic.
- **Default route did not move**: check `uplink-flip status`. A message
  about reactivating a connection means `device reapply` was not enough on your
  system and the documented reactivation was used.
- **Exit code 4**: copy the printed `nmcli connection modify uuid ...` commands,
  run them, then `nmcli device reapply DEVICE`. The state file is kept until a
  restore succeeds.
- **State file "corrupt"**: it is refused rather than guessed at. Inspect it
  (`# uplink-flip state v1` then `conn UUID v4nd v4metric v6nd v6metric dev`
  lines), fix or remove it by hand.

## Real hardware: modem device versus IP interface

For a modem, NetworkManager's device name (for example `cdc-wdm0`, the control
port) differs from the IP interface that carries the traffic (for example
`wwp0s20f0u4i4`), and `ip route` only ever shows the IP interface. uplink-flip
reads each connection's IP interface with `nmcli -g GENERAL.IP-IFACE device
show DEVICE` (falling back to the device name when it is empty) and uses that
for everything about routes: the gateway check, "which connection carries the
default route" and "does the modem win". It still passes the NM device name to
`nmcli device reapply`. For ethernet and wifi the two names are normally the
same.

## The connectivity check and your privacy

`status` makes one HTTP request, to the URL in `CHECK_URL`. **By default that
is NetworkManager's own connectivity-check host**
(`http://nmcheck.gnome.org/check_network_status.txt`), so running `status`
sends one request there from your machine. To use a target you trust more, set
`UPLINK_FLIP_CHECK_URL` (or `CHECK_URL` in the config file) to another
`http://` or `https://` URL. To make no request at all, set it to an empty
value (`UPLINK_FLIP_CHECK_URL=` or `CHECK_URL=`); `status` then prints that the
check was skipped.

## Not in scope

Automatic outage detection or failover, VPN handling, Windows or macOS.

## Tests

```sh
./tests/run.sh          # all tests, plain bash, fake nmcli/ip/curl
./tests/run.sh dry_run  # only tests whose name contains "dry_run"
```

CI runs shellcheck, shfmt, workflow lint, the tests and security scans through
the reusable workflows in `ChiefGyk3D/git-your-ship-together`.

## License

Apache-2.0, see `LICENSE`.
