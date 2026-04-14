# QSFP-SFP Adapter Finder

Finds QSFP-to-SFP adapters (e.g., `CVR-QSFP-SFP10G`) installed in Cisco switches and reports the connection status of each adapter port.

## Description

`qsfp_sfp_adapter_finder.exs` connects to a list of Cisco switches via SSH, runs `show inventory`, and identifies any QSFP-to-SFP converter modules installed. For each adapter, the script then queries the corresponding port (`show interface`) to record whether the port is currently connected and to capture any configured interface description.

For each QSFP-SFP adapter, the script collects:

- **Switch Hostname** of the switch the adapter is installed in
- **Switch IP** address used for the SSH connection
- **Port** the adapter is plugged into (e.g., `FourHundredGigE1/0/20`)
- **Adapter PID** (e.g., `CVR-QSFP-SFP10G`)
- **Adapter Description** from the `DESCR` field in the inventory entry (e.g., `10GE LR`)
- **Connection Status** (`connected`, `notconnect`, `admin down`, `down`, etc.)
- **Interface Description** from the interface configuration, if any

## Detection Logic

A QSFP-SFP adapter is detected from `show inventory` output when either:

- the `PID` starts with `CVR-QSFP-SFP` (Cisco's `CVR` = "Converter" naming), **or**
- the `NAME` ends with the `-qsa` suffix that IOS appends to a parent QSFP port when an adapter is plugged in.

Sample inventory stanza that the script matches:

```
NAME: "FourHundredGigE1/0/20-qsa", DESCR: "10GE LR"
PID: CVR-QSFP-SFP10G     , VID: V02  , SN: STX1111117F
```

The script extracts `FourHundredGigE1/0/20` from the `NAME` field as the parent port and runs `show interface FourHundredGigE1/0/20` against it to determine connection status.

## Features

- Interactive username/password authentication (secure password input on Unix/Linux/macOS)
- Reads device list from `devices.txt` by default (configurable at the prompt)
- Parallel processing of switches via `Task.async_stream`
- Comprehensive Cisco IOS-XE 17.x SSH algorithm support (modern + legacy)
- Outputs a single timestamped CSV: `output/<timestamp>-qsfp_sfp_adapters.csv`
- Detailed logging to `logs/<timestamp>/` (one log file per switch)
- Fault-tolerant: continues processing if individual switches fail or time out

## Prerequisites

- Elixir installed on your system
- SSH access to Cisco switches with credentials privileged to run:
  - `show run | include hostname`
  - `show inventory`
  - `show interface <port>`
- A `devices.txt` file containing switch IP addresses or hostnames (one per line)

## Setup

1. Navigate to the script directory:

   ```bash
   cd qsfp_sfp_adapter_finder
   ```

2. Create or edit `devices.txt` with your switch IP addresses or hostnames (one per line):

   ```
   # Edge / distribution switches
   192.168.1.10
   192.168.1.11
   192.168.1.12
   ```

   Lines starting with `#` are comments and will be ignored.

## Usage

```bash
cd qsfp_sfp_adapter_finder
elixir qsfp_sfp_adapter_finder.exs
```

Or:

```bash
cd qsfp_sfp_adapter_finder
chmod +x qsfp_sfp_adapter_finder.exs
./qsfp_sfp_adapter_finder.exs
```

The script will:

1. Prompt for your username
2. Prompt for your password (hidden on Unix/Linux/macOS)
3. Prompt for the devices file (defaults to `devices.txt` if you press Enter)
4. Connect to all listed switches in parallel
5. Run `show inventory` on each switch and find QSFP-SFP adapter entries
6. Run `show interface <port>` for each adapter port to capture status and description
7. Write results to `output/<timestamp>-qsfp_sfp_adapters.csv`

## Example Output

**Terminal Output:**

```
=== QSFP-SFP Adapter Finder ===

Logging to: logs/2026-04-14T10-30-45

Enter username: admin
Enter password: [hidden]
Enter devices file (one IP per line) [devices.txt]:

Found 3 device(s) to scan...
Devices: 192.168.1.10, 192.168.1.11, 192.168.1.12

Connecting to switch: 192.168.1.10...
Connecting to switch: 192.168.1.11...
Connecting to switch: 192.168.1.12...
  Found 2 QSFP-SFP adapter(s) on 192.168.1.10
  Found 0 QSFP-SFP adapter(s) on 192.168.1.11
  Found 1 QSFP-SFP adapter(s) on 192.168.1.12

================================================================================
RESULTS: Found 3 QSFP-SFP adapter(s) total
================================================================================

Adapters written to: output/2026-04-14T10-30-45-qsfp_sfp_adapters.csv

Adapters by switch:
  192.168.1.10: 2 adapter(s)
  192.168.1.12: 1 adapter(s)
```

**CSV Output (`output/2026-04-14T10-30-45-qsfp_sfp_adapters.csv`):**

```csv
Switch Hostname,Switch IP,Port,Adapter PID,Adapter Description,Connection Status,Interface Description
CORE-SW-01,192.168.1.10,FourHundredGigE1/0/20,CVR-QSFP-SFP10G,10GE LR,connected,UPLINK-DC2-10G
CORE-SW-01,192.168.1.10,FourHundredGigE1/0/24,CVR-QSFP-SFP10G,10GE SR,notconnect,N/A
DIST-SW-03,192.168.1.12,HundredGigE1/1/3,CVR-QSFP-SFP10G,10GE LR,connected,SERVER-RACK-7
```

## How It Works

1. **Initialization**: Starts the SSH application
2. **Authentication**: Prompts for credentials (password input is hidden on Unix/Linux/macOS)
3. **Parallel Processing**: Connects to all listed devices simultaneously via SSH
4. **Per Switch Processing**:
   - Gets the switch hostname from `show run | include hostname`
   - Runs `show inventory` and parses each `NAME:`/`PID:` two-line stanza
   - Filters entries where the PID starts with `CVR-QSFP-SFP` or the NAME ends with `-qsa`
   - Extracts the parent port name from the inventory NAME field
   - Runs `show interface <port>` to capture connection status and description
5. **CSV Output**: Aggregates all adapters from all switches and writes a single timestamped CSV

## Connection Status Values

| Status | Meaning |
|---|---|
| `connected` | Interface is up, line protocol is up |
| `notconnect` | Interface is down, line protocol is down (no signal / cable unplugged) |
| `admin down` | Interface is administratively shut |
| `down` | Interface is up but line protocol is down (Layer 1 OK, Layer 2 issue) |
| `monitoring` | Interface is down but line protocol is up (rare) |
| `unknown` | Could not parse a status line from `show interface` output |

## Logging

The script automatically creates detailed logs in the `logs/` directory. Each run creates a timestamped subdirectory containing one log file per switch.

Log files contain:

- All commands executed on the switch
- Raw output from each command
- Parsed inventory entries that matched the QSFP-SFP filter
- The port extracted from each inventory NAME
- The connection status and description parsed from `show interface`
- Any errors or warnings encountered

```bash
ls -la logs/                    # List all runs
cat logs/<timestamp>/*.log      # View all logs from a run
```

## Troubleshooting

**First step: Check the logs!** The script creates detailed logs that show exactly what happened on each switch.

- **Connection failures**:
  - Verify SSH access and credentials
  - Check logs for connection error details
- **No adapters found, but you know one is installed**:
  - Check the raw `show inventory` output in the log file
  - Verify the PID starts with `CVR-QSFP-SFP` or the NAME ends with `-qsa`
  - If your platform uses a different naming convention, extend the `qsfp_sfp_adapter?/1` filter in the script
- **Connection Status shows `unknown`**:
  - Check the raw `show interface <port>` output in the log file
  - The first status line of the interface output may be in an unexpected format
- **Port column shows the raw inventory NAME**:
  - The script could not extract a port from the NAME field
  - Check the log for an `ERROR: ... Could not extract port from inventory NAME` line
- **Timeout errors**: Each switch has a 120-second timeout

## License

See LICENSE file for details.
