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

eSIM profile management needs `lpac`, and scanning a QR code needs `zbar`:

```sh
yay -S lpac
omarchy pkg add zbar
```

`lpac` is a Local Profile Assistant. It talks to the eUICC over the modem's AT port and
implements the list, switch, rename, delete and install operations. `zbar` decodes a QR
code captured from the screen. Without `zbar`, activation codes can still be typed in.
`omarchy-cellular doctor` reports which are installed.

## Hardware

Developed against a Lenovo ThinkPad X1 Carbon Gen 12 with a Quectel RM520N-GL (5G,
MHI/PCIe). USB modems should work, but have not been tested.

Two code paths depend on the bus. AT port discovery reads `/sys/class/wwan`, where the
kernel labels each port by function, and falls back to ModemManager's port list on USB
modems older than the wwan subsystem. Control-port recovery after suspend re-authorizes
the USB device to force a re-probe, and returns early on PCIe, where there is no
`cdc-wdm` node.

## Panel

The bar icon opens the control panel. Right-click toggles cellular, middle-click
refreshes.

- **Connect switch**, with operator, access technology and status.
- **Connection stats**: signal, RSSI, RSRP, RSRQ, SNR, ping and packet loss measured over
  the modem link, throughput, session totals and IP. Click a value to copy it.
- **Prioritize mobile**, **Metered** and **Autoconnect** switches.
- **Data usage**: progress bar, next reset date, and a *Change* button holding the limit,
  the period and a reset.
- **Radio mode**: auto, 5G, 4G or 3G.
- **APN**: detect from SIM, select country, carrier and APN, or type one.
- **Device**: modem, firmware, IMEI, ICCID and EID, masked until revealed.
- **SIM card**: physical or eSIM slot, and eSIM profile management. Click a profile to
  switch to it, use the chips to rename or delete it, and *Add profile* to install one from
  an activation code or a QR code on screen.

Reading the eUICC stops the modem, so profile operations ask for authorization and the
connection drops and comes back.

## Commands

```
omarchy-cellular status              modem, operator, signal, IP
omarchy-cellular connect|disconnect  bring cellular up or down
omarchy-cellular toggle
omarchy-cellular restart             reconnect
omarchy-cellular mode [auto|5g|4g|3g]
omarchy-cellular sim [1|2]           physical card (1) or eSIM (2); bare: show config
omarchy-cellular profile list        profiles on the eSIM
omarchy-cellular profile enable|delete|nickname <iccid> [name]
omarchy-cellular profile download <activation-code>
omarchy-cellular profile scan        install from a QR code on screen
omarchy-cellular carrier ...         carrier and APN selection
omarchy-cellular limit ...           data cap with auto-cutoff
omarchy-cellular apn <name>          set the APN
omarchy-cellular apn list            APNs the carrier provisioned into the modem
omarchy-cellular autoconnect on|off
omarchy-cellular prefer [cellular|wifi]  which link carries traffic when both are up
omarchy-cellular metered [yes|no]      whether this connection costs money
omarchy-cellular identify            re-read ICCID and EID
omarchy-cellular at '<command>'      raw AT command
omarchy-cellular apply               re-read cellular.conf and reconnect
omarchy-cellular config              edit ~/.config/omarchy/cellular.conf
omarchy-cellular log
omarchy-cellular doctor              check the setup
```

`disconnect` uses rfkill, and systemd-rfkill persists that across reboots, so cellular
stays off until the next `connect`.

## Carrier and APN

APNs come from `mobile-broadband-provider-info`, the database NetworkManager's own mobile
broadband wizard uses, covering 154 countries. MMS and WAP APNs are filtered out.

```sh
omarchy-cellular carrier auto                  # read MCC/MNC from the SIM and apply its APN
omarchy-cellular carrier list                  # countries
omarchy-cellular carrier list pl               # carriers in Poland
omarchy-cellular carrier list pl Orange        # that carrier's data APNs
omarchy-cellular carrier set pl Orange         # apply APN, username and password
omarchy-cellular carrier choose                # the same, as menu pickers
omarchy-cellular apply
```

Username and password are applied for carriers that need them.

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

Usage accumulates from the interface byte counters into
`~/.local/state/omarchy-cellular/usage`, and survives reboots, suspend and interface
re-creation. At the limit, cellular disconnects and a notification is sent.
Reconnecting by hand suppresses the cutoff until the period renews.

The meter updates on the bar's status poll, roughly every 10 seconds, so a cutoff can
overshoot by whatever transfers in that time.

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

Nothing is granted at install time, and normal operation does not prompt. Three operations
use `pkexec` when reached:

1. Switching SIM slots. See Notes.
2. Reading or changing eSIM profiles. lpac needs the AT port, so ModemManager is stopped
   for the call.
3. Recovering a control port lost across suspend, when the port is gone.

## Installed files

| Path | Contents |
| --- | --- |
| `~/.config/omarchy/plugins/relctx.cellular/` | bar widget, panel and CLI |
| `~/.config/omarchy/cellular.conf` | APN, SIM slot, PIN, route metric |
| `~/.config/omarchy/shell.json` | widget entry in `bar.layout` |
| `~/.local/state/omarchy-cellular/usage` | data-limit meter state |
| `~/.local/bin/omarchy-cellular` | optional symlink |

The connection is a NetworkManager `gsm` profile named `Omarchy Cellular`, overridable with
`OMARCHY_CELLULAR_CONN`.

## Uninstall

```sh
omarchy plugin remove relctx.cellular
nmcli connection delete "Omarchy Cellular"
rm -f ~/.local/bin/omarchy-cellular
rm -f ~/.config/omarchy/cellular.conf     # settings, including any SIM PIN
rm -rf ~/.local/state/omarchy-cellular    # usage meter
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
