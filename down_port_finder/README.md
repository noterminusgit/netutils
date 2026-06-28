# Down Port Finder

Finds Cisco switch ports that are assigned to **VLANs 161-164** and are currently
**not connected or disabled**. For every such port it reports the switch
hostname, switch IP, port, interface description, link status, and VLAN.

This is useful for reclaiming unused access ports in a specific VLAN range — for
example, auditing a block of voice/guest/IoT VLANs to find drops that are
provisioned but not in use.

## Features

- Scans many switches in parallel over SSH (Cisco IOS / IOS-XE)
- Reads each port's access VLAN and link state from `show interfaces status`
- Attaches the full interface description from `show interfaces description`
- Reports only ports whose VLAN is in **161-164** and whose status is one of:
  - `notconnect` — nothing connected / no link
  - `disabled` — administratively shut down
  - `err-disabled` — error-disabled by the switch
- Writes a single CSV (`down_ports.csv`) and a single per-run log file

## Prerequisites

- [Elixir](https://elixir-lang.org/install.html) (which includes Erlang/OTP and
  the `:ssh` application)
- SSH (port 22) reachability to each switch
- Read-level CLI credentials on the switches

## Setup

Populate `switches.txt` with one switch IP address or hostname per line. Lines
beginning with `#` are treated as comments:

```text
# List of switches to scan
192.168.1.10
192.168.1.11
core-sw-01.example.com
```

> **Note:** `*.txt` is git-ignored repo-wide so your working switch list never
> collides with the committed sample. To update the committed sample, use
> `git add -f down_port_finder/switches.txt`.

## Usage

```bash
cd down_port_finder
elixir down_port_finder.exs
```

You will be prompted for:

1. **Username** — switch login username
2. **Password** — switch login password (hidden where supported)
3. **Switches file** — path to the input file (press Enter for `switches.txt`)

## Example Output

`down_ports.csv`:

```csv
Switch Hostname,Switch IP,Port,Description,Status,VLAN
access-sw-01,192.168.1.10,Gi1/0/7,Spare drop rm 214,notconnect,161
access-sw-01,192.168.1.10,Gi1/0/9,N/A,disabled,162
access-sw-02,192.168.1.11,Gi1/0/22,Old printer,notconnect,164
```

Console summary:

```text
================================================================================
RESULTS: Found 3 down port(s) on VLANs 161-164 total
================================================================================

Down ports written to: down_ports.csv

Down ports by switch:
  192.168.1.10: 2 port(s)
  192.168.1.11: 1 port(s)
```

## How It Works

1. Connects to each switch concurrently (`Task.async_stream`) over SSH and opens
   an interactive shell, disabling pagination with `terminal length 0`.
2. Reads the hostname via `show run | include hostname`.
3. Runs `show interfaces status` and parses each row into port, name, status, and
   access VLAN. Because the Name column can contain spaces, the parser locates the
   known Status keyword and reads the VLAN from the token immediately after it.
4. Runs `show interfaces description` and builds a port → full-description map.
5. Keeps only ports whose status is `notconnect`, `disabled`, or `err-disabled`
   **and** whose VLAN is in the 161-164 range, then writes them to
   `down_ports.csv`.

## Output Files

| File | Description |
| --- | --- |
| `down_ports.csv` | Matching down ports on VLANs 161-164 |
| `logs/<ISO8601-seconds>-down_port_finder.log` | Single per-run log of all SSH activity and command output |

Both `*.csv` and `logs/` are git-ignored.

> **Note on conventions:** Most scripts in this repo read `devices.txt` and write
> timestamped CSVs under `output/`. This script intentionally uses the fixed names
> `switches.txt` and `down_ports.csv`, and a single timestamped log file in
> `logs/`, as required for its specific workflow.

## Logging

Each run writes one log file named with the run's ISO 8601 start time (to the
second) followed by the script name, e.g.:

```text
logs/2026-06-28T21:56:30Z-down_port_finder.log
```

The log captures connection events, every command issued, the raw command output,
and any errors encountered per switch.

## Troubleshooting

- **No ports found:** Confirm the switches actually have access ports in VLANs
  161-164 that are down. Check the log file to see the raw `show interfaces status`
  output that was parsed.
- **Connection failures:** Verify SSH reachability and credentials. The script
  re-enables legacy SSH algorithms (SHA-1 KEX, CBC ciphers, etc.) for older
  switches; see the log for the specific failure reason.
- **Missing descriptions:** A port with no configured description shows `N/A`.
  If `show interfaces description` fails, the truncated Name from the status table
  is used as a fallback.
