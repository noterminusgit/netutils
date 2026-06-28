# AP Mismatch Finder

A script to discover Cisco Access Points connected to Cisco switches and report only the APs whose configured interface **description** does not match the AP's **hostname** (as resolved via CDP).

## Description

`ap_mismatch_finder.exs` is a variant of the [Cisco AP Finder](../cisco_ap_finder/README.md). It connects to a list of Cisco switches via SSH, runs `show power inline` to identify powered devices on local ports, uses the MAC address table to retrieve VLAN and MAC address information, and filters devices by Cisco OUI. For each Cisco AP it resolves the hostname via CDP (`show cdp neighbors detail`) and reads the port's configured description from `show interfaces description`.

It then **diffs the description against the hostname** and outputs **only the rows where the two values do not match**. This is useful for auditing that switch port descriptions stay in sync with the AP names actually plugged into them.

## What counts as a mismatch

The description and hostname are compared after trimming surrounding whitespace and lowercasing, so `AP-Floor1` and `ap-floor1 ` are treated as a match. Any other difference is reported as a mismatch, including cases where:

- The description and hostname are genuinely different names.
- The description is missing (shown as `N/A`).
- The hostname could not be resolved via CDP (shown as `Unknown`).

## Features

- Interactive username/password authentication (secure password input)
- Parallel processing of switches for fast scanning
- Reads switch list from `devices.txt` (the default when no filename is entered)
- Identifies powered devices on local ports (x/0/x interfaces), excluding uplinks (x/1/x)
- Filters devices by Cisco OUI (MAC address prefix) with 500+ known prefixes
- Resolves hostname via CDP and reads the configured interface description
- **Outputs only APs where the description and hostname differ**
- Places `Description` and `Hostname` side by side in the CSV for easy comparison
- Outputs timestamped results to `output/<timestamp>-ap_mismatches.csv`
- Detailed logging to `logs/[timestamp]/` directory (one log per switch)
- Fault-tolerant: continues processing if individual switches fail or timeout

## Prerequisites

- Elixir installed on your system
- SSH access to Cisco switches
- A text file containing switch IP addresses or hostnames (one per line)
- CDP enabled (required for hostname resolution; without it the hostname is `Unknown`, which counts as a mismatch)

## Setup

1. Navigate to the script directory:
   ```bash
   cd ap_mismatch_finder
   ```

2. Create a text file containing switch IP addresses or hostnames (one per line). For example, `devices.txt`:
   ```
   192.168.1.10
   192.168.1.11
   192.168.1.12
   ```

   Lines starting with `#` are treated as comments and will be ignored. A sample `devices.txt` file is included.

3. Ensure you have SSH credentials with appropriate privileges to run:
   - `show power inline`
   - `show mac address-table interface`
   - `show interfaces description`
   - `show cdp neighbors detail`

## Usage

```bash
cd ap_mismatch_finder
./ap_mismatch_finder.exs
```

Or:
```bash
cd ap_mismatch_finder
elixir ap_mismatch_finder.exs
```

The script will:
1. Prompt for your username
2. Prompt for your password (input hidden on Unix/Linux/macOS; visible on Windows)
3. Prompt for the devices file name (press Enter to accept the default `devices.txt`)
4. Connect to switches from the file in parallel
5. Discover Cisco APs on each switch
6. Compare each AP's description against its hostname
7. Write only the mismatched APs to `output/<timestamp>-ap_mismatches.csv`

## Example Output

**Terminal Output:**
```
=== AP Mismatch Finder ===

Logging to: logs/2026-01-12T15-30-45-123456Z

Enter username: admin
Enter password: [hidden]
Enter devices file (one IP per line) [devices.txt]: devices.txt

Found 3 switch(es) to scan...
Switches: 192.168.1.10, 192.168.1.11, 192.168.1.12

Connecting to switch: 192.168.1.10...
Connecting to switch: 192.168.1.11...
Connecting to switch: 192.168.1.12...
  Found 2 Cisco AP(s) on 192.168.1.10
  Found 1 Cisco AP(s) on 192.168.1.11
  Found 0 Cisco AP(s) on 192.168.1.12

================================================================================
RESULTS: 2 of 3 Cisco AP(s) have a description/hostname mismatch
================================================================================

Results written to: output/2026-01-12T15-30-45Z-ap_mismatches.csv

Summary by switch:
  192.168.1.10: 1 mismatch(es)
  192.168.1.11: 1 mismatch(es)
```

*Note: With parallel processing, connection messages may appear in different orders.*

**CSV File Output (output/2026-01-12T15-30-45Z-ap_mismatches.csv):**
```csv
Switch,Interface,Description,Hostname,VLAN,Model,MAC Address
192.168.1.10,Gi1/0/5,AP-Floor1-West,AP-Floor1-East,40,AIR-AP2802I-B-K9,a1:b2:c3:d4:e5:f7
192.168.1.11,Gi1/0/3,N/A,AP-Floor2-Center,31,Ieee PD,a1:b2:c3:d4:e5:f8
```

APs whose description already matches the hostname are omitted from the CSV.

## How It Works

1. **Initialization**: Starts SSH application for connection handling
2. **Authentication**: Prompts for credentials (password input is hidden on Unix/Linux/macOS)
3. **Parallel Processing**: Connects to switches simultaneously via SSH
4. **Per Switch Processing**:
   - Runs `show power inline` to find powered devices
   - Filters for local ports (x/0/x) excluding uplinks (x/1/x) with power draw > 0
   - Extracts device model from power inline output
   - Runs `show interfaces description` once to build a port-to-description map
   - For each matching interface, runs `show mac address-table interface <interface>`
   - Validates MAC address against Cisco OUI prefixes (500+ known prefixes)
   - If a Cisco device is detected, resolves the hostname from `show cdp neighbors <interface> detail` and attaches the interface description
5. **Diff**: Compares each AP's description against its hostname (trim + lowercase) and keeps only the ones that differ
6. **CSV Output**: Writes the mismatched APs to `output/<timestamp>-ap_mismatches.csv`

## Logging

The script automatically creates detailed logs in the `logs/` directory. Each run creates a timestamped subdirectory (e.g., `logs/2026-01-12T15-30-45-123456Z/`) containing one log file per switch.

Log files contain:
- All commands executed on the switch
- Raw output from each command
- Parsing results and filtering decisions
- Reasons why devices were included or excluded
- Any errors encountered

```bash
ls -la logs/                    # List all runs
cat logs/[timestamp]/*.log      # View all logs from a run
```

## Troubleshooting

**First step: Check the logs!** The script creates detailed logs in `logs/[timestamp]/` that show exactly what commands were run, the resolved hostname, and the description for each port.

- **Connection failures**: Verify SSH access and credentials. Check logs for connection error details.
- **No mismatches found**: All discovered APs have matching descriptions and hostnames — this is the expected healthy state.
- **Unexpected mismatches with `Unknown` hostname**: CDP may not be enabled. Enable with `cdp run` and `cdp enable` on interfaces.
- **Unexpected mismatches with `N/A` description**: No `description` is configured on the interface, or `show interfaces description` could not be parsed. Check the logs for the raw command output.
- **Timeout errors**: Each switch has a 120-second timeout. Slow switches may timeout but others will continue processing.

## License

See LICENSE file for details.
