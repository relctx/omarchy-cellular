# omarchy-cellular

A cellular plugin for [Omarchy](https://omarchy.org/). It adds a bar widget with a
control panel, and a CLI. NetworkManager, ModemManager and busctl do the work of managing
the modem.

<p>
  <img src="preview.png" alt="The Cellular panel as it sits day to day" width="46%">
  <img src="preview-expanded.png" alt="The Cellular panel with every section opened" width="46%">
</p>

## Install

```sh
omarchy plugin add https://github.com/relctx/omarchy-cellular.git
omarchy plugin enable relctx.cellular --section right
```

`~/.config/omarchy/cellular.conf` is created on first use.

To put the CLI on `PATH`:

```sh
ln -sf ~/.config/omarchy/plugins/relctx.cellular/bin/omarchy-cellular ~/.local/bin/
```

## Requirements

Omarchy 4.0 (quattro) or newer. The widget targets the Quickshell-based omarchy-shell.

eSIM profile management needs lpac built with the `mbim` driver — the `lpac-git`
package is, the stock `lpac` package is not:

```sh
yay -S lpac-git
omarchy pkg add zbar        # QR scan; codes can still be typed without it
omarchy pkg add libqmi      # optional: qmicli, for `cells` diagnostics
```

`lpac` talks to the eUICC over the modem's MBIM port, which ModemManager keeps open,
so eSIM operations do not interrupt the connection. `omarchy-cellular doctor` reports
what is installed.

## Hardware

Developed against a Lenovo ThinkPad X1 Carbon Gen 12 with a Quectel RM520N-GL (5G,
MHI/PCIe). USB modems should work, but have not been tested.

Two code paths depend on the bus. MBIM port discovery reads `/sys/class/wwan`, where the
kernel labels each port by function, and falls back to ModemManager's port list on USB
modems older than the wwan subsystem. Control-port recovery after suspend re-authorizes
the USB device to force a re-probe, and returns early on PCIe, where there is no
`cdc-wdm` node.

## Panel

The bar icon opens the control panel. Right-click toggles cellular, middle-click
refreshes.

The panel is event-driven: ModemManager and NetworkManager signals update it as they
happen, and a SIM switch narrates its stages instead of holding one spinner.

- **Connect switch**, operator, technology, status.
- **Connection stats**: signal metrics colored at their 3GPP thresholds, ping, packet
  loss, throughput, totals, IP. Click a value to copy it. A signal sparkline plots the
  last five minutes.
- **Active identity**: which card, which APN, at a glance.
- **Data usage**: per-card meter with the calendar's position ticked on the bar, the
  counting start stamped, and cutoff as a switch.
- **Radio mode**: auto, 5G, 4G, 3G.
- **Management chips**: Device details, SIM cards, APN and carrier, cell diagnostics —
  one box open at a time.
- **SIM cards**: every identity the modem can be — the physical card and each eSIM
  profile — as tiles; one click switches, whatever that takes underneath. eSIM
  management lists profiles by ICCID with rename, delete and install.
- **Cell diagnostics**: read on demand — every carrier in use (primary and secondaries
  with their widths, carrier aggregation totalled) and every cell the radio hears.

eSIM operations run over MBIM with the connection up. One authorization covers a whole
management session.

## Commands

```
omarchy-cellular status              modem, operator, signal, IP
omarchy-cellular connect|disconnect  bring cellular up or down
omarchy-cellular toggle
omarchy-cellular restart             reconnect
omarchy-cellular mode [auto|5g|4g|3g]
omarchy-cellular sims                every card this modem can be
omarchy-cellular use <iccid>         become one: slot switch, profile enable, or both
omarchy-cellular sim [<n>|physical|esim]
omarchy-cellular profile list        profiles on the eSIM
omarchy-cellular profile enable|delete|nickname <iccid> [name]
omarchy-cellular profile download <activation-code>
omarchy-cellular profile scan        install from a QR code on screen
omarchy-cellular carrier ...         carrier and APN selection
omarchy-cellular limit ...           data cap with auto-cutoff
omarchy-cellular apn <name>          set the APN
omarchy-cellular apn list            APNs on the carrier's bearers
omarchy-cellular pin ...             SIM lock: status, unlock, puk, on|off, change
omarchy-cellular signal              every metric the modem reports, RSRQ included
omarchy-cellular cells               carriers in use and every cell heard
omarchy-cellular autoconnect on|off
omarchy-cellular prefer [cellular|wifi]  which link carries traffic when both are up
omarchy-cellular metered [yes|no]      whether this connection costs money
omarchy-cellular identify            re-read ICCID and EID
omarchy-cellular apply               re-read cellular.conf and reconnect
omarchy-cellular config              edit ~/.config/omarchy/cellular.conf
omarchy-cellular log
omarchy-cellular doctor              check the setup
```


## Carrier and APN

APNs come from `mobile-broadband-provider-info`, the database NetworkManager's own mobile
broadband wizard uses, covering 154 countries. MMS and WAP APNs are filtered out.

```sh
omarchy-cellular carrier auto                  # read MCC/MNC from the SIM and apply its APN
omarchy-cellular carrier list                  # countries
omarchy-cellular carrier list pl               # carriers in Poland
omarchy-cellular carrier list pl Orange        # that carrier's data APNs
omarchy-cellular carrier set pl Orange         # apply APN, username and password
omarchy-cellular apply
```

Username and password are applied for carriers that need them.

## Per-card configuration

APN, credentials, PIN, operator and the data plan belong to a card, not the machine.
They live in `~/.config/omarchy/cellular.d/<iccid>.conf`, seeded from detect the first
time a card is seen and applied automatically when the active card changes.
`cellular.conf` keeps machine-wide settings.

## Data limit

A monthly, daily or fixed-length cap with an automatic cutoff. Prepaid bundles sold as
"N days from activation" use `days`, which rolls a window of that length forward from the
start date.

```sh
omarchy-cellular limit 5G                  # cap the period at 5 GB
omarchy-cellular limit day 12              # monthly package renews on the 12th
omarchy-cellular limit days 30             # 30-day bundle, counted from today
omarchy-cellular limit days 30 2026-08-15  # 30-day bundle bought on a past date
omarchy-cellular limit period monthly|daily|days
omarchy-cellular limit                     # usage, period, next reset
omarchy-cellular limit reset               # zero the counter; on days, restart the period
omarchy-cellular limit off                 # disable the cutoff, keep tracking usage
```

Each card runs its own meter against its own plan, accumulated from the interface byte
counters into `~/.local/state/omarchy-cellular/usage.<iccid>`; a delta whose interval
straddled a card switch credits the card that was active. Counters survive reboots,
suspend and interface re-creation. At the limit, cellular disconnects with a
notification; reconnecting by hand — or `limit cutoff off` — suppresses the cutoff
until the period renews.

The meter samples on panel updates, which the event feed drives; a cutoff can overshoot
by whatever transfers between samples.

## Route metrics

Both default routes stay in the table, and the lower metric wins:

```
default via 192.168.1.1  dev wlan0    metric 600   <- traffic goes here
default via 10.0.0.1     dev wwan0    metric 700
```

Failover is immediate, because the modem holds its connection instead of dialling on
demand. `ROUTE_METRIC` sets the cellular metric, and 700 is the default.

`omarchy-cellular prefer cellular` puts mobile first. The metric is computed from the routes
present at the time, so it does not assume anyone else's defaults. VPNs route by policy
rule, which the kernel evaluates ahead of the main table, and are unaffected.

## Metered

The connection is marked metered. Desktop applications read this to defer downloads and
background updates. Command-line tools ignore it.

```sh
omarchy-cellular metered no      # a large plan, or just after topping up
omarchy-cellular metered yes
omarchy-cellular metered         # what is configured, and what NetworkManager has
```

## Permissions

Nothing is granted at install time, and normal operation does not prompt. Four
operations use `pkexec` when reached:

1. Switching SIM slots. See Notes.
2. eSIM profile operations. One authorization covers a whole management session; the
   connection stays up and nothing is stopped.
3. Cell diagnostics: one authorization reads carriers, aggregation and neighbors.
4. Recovering a control port lost across suspend, when the port is gone.

## Installed files

| Path | Contents |
| --- | --- |
| `~/.config/omarchy/plugins/relctx.cellular/` | bar widget, panel and CLI |
| `~/.config/omarchy/cellular.conf` | machine-wide settings |
| `~/.config/omarchy/cellular.d/` | per-card APN, PIN, data plan |
| `~/.config/omarchy/shell.json` | widget entry in `bar.layout` |
| `~/.local/state/omarchy-cellular/` | per-card usage meters, caches |
| `~/.local/bin/omarchy-cellular` | optional symlink |

The connection is a NetworkManager `gsm` profile named `Omarchy Cellular`, overridable with
`OMARCHY_CELLULAR_CONN`.

## Uninstall

```sh
omarchy plugin remove relctx.cellular
nmcli connection delete "Omarchy Cellular"
rm -f ~/.local/bin/omarchy-cellular
rm -f ~/.config/omarchy/cellular.conf     # machine-wide settings
rm -rf ~/.config/omarchy/cellular.d       # per-card settings, including any SIM PIN
rm -rf ~/.local/state/omarchy-cellular    # usage meters
```

ModemManager and NetworkManager are left unmodified.

## Notes

- Switching SIM slots requires root whatever polkit says. `SetPrimarySimSlot` is not on
  ModemManager's D-Bus whitelist, so the bus rejects the call before polkit sees it.
  `DBus.Error.AccessDenied` comes from the bus, and a polkit refusal names `PolicyKit`.
- An empty eSIM leaves the modem unregistered, which looks the same as poor coverage.
  `doctor` reports a config and hardware slot mismatch for this case.
- `modem.generic.bearers.value[N]` is the data bearer. `3gpp.eps.initial-bearer` comes
  first in `mmcli -K` output and has no interface.
- Use `omarchy-cellular connect` instead of `nmcli connection up`. rfkill, a low power state,
  a wedged radio and a control port lost across suspend all let the modem register without
  raising a bearer, and the pre-flight clears them.
- For diagnosis, run `omarchy-cellular doctor`, then `omarchy-cellular log`.

## Credits

Forked from [Erruviel/omarchy-wwan](https://github.com/Erruviel/omarchy-wwan).

## License

MIT. Copyright (c) 2026 erruviel and relctx.
