# Cisco AP Finder

A script to discover Cisco Access Points connected to Cisco switches via Power over Ethernet (PoE).

## Description

`cisco_ap_finder.exs` connects to a list of Cisco switches via SSH, runs the `show power inline` command to identify powered devices on local ports, and then uses the MAC address table to retrieve VLAN and MAC address information. It matches devices based on Cisco OUI (MAC address prefix) to ensure only Cisco equipment is included. CDP (Cisco Discovery Protocol) is used for hostname resolution.

## Features

- Interactive username/password authentication (secure password input)
- Parallel processing of up to 10 switches simultaneously for fast scanning
- Reads switch list from `switches.txt`
- Identifies powered devices on local ports (x/0/x interfaces)
- Excludes uplink ports (x/1/x interfaces)
- Extracts device model from power inline output
- Retrieves MAC address and VLAN from MAC address table
- Filters devices by Cisco OUI (MAC address prefix) with 500+ known prefixes
- Retrieves hostname via CDP (optional - will show "Unknown" if CDP unavailable)
- Outputs results to `aps.csv` in CSV format for easy analysis
- Detailed logging to `logs/[timestamp]/` directory (one log per switch)
- Fault-tolerant: continues processing if individual switches fail or timeout

## Prerequisites

- Elixir installed on your system
- SSH access to Cisco switches
- A text file containing switch IP addresses or hostnames (one per line)
- CDP enabled (optional - only required for hostname resolution; devices will still be detected without CDP)

## Setup

1. Navigate to the script directory:
   ```bash
   cd cisco_ap_finder
   ```

2. Create a text file containing switch IP addresses or hostnames (one per line). For example, `switches.txt`:
   ```
   192.168.1.10
   192.168.1.11
   192.168.1.12
   ```

   Lines starting with `#` are treated as comments and will be ignored. A sample `switches.txt` file is included.

3. Ensure you have SSH credentials with appropriate privileges to run:
   - `show power inline`
   - `show mac address-table interface`
   - `show cdp neighbors detail` (for hostname resolution)

## Usage

```bash
cd cisco_ap_finder
./cisco_ap_finder.exs
```

Or:
```bash
cd cisco_ap_finder
elixir cisco_ap_finder.exs
```

The script will:
1. Prompt for your username
2. Prompt for your password (input hidden on Unix/Linux/macOS; visible on Windows)
3. Prompt for the switches file name (e.g., `switches.txt`)
4. Connect to switches from the file (up to 10 in parallel)
5. Discover Cisco devices on each switch
6. Write results to `aps.csv`

## Example Output

**Terminal Output:**
```
=== Cisco AP Finder ===

Logging to: logs/2026-01-12T15-30-45-123456Z

Enter username: admin
Enter password: [hidden]
Enter switches file (one IP per line): switches.txt

Found 3 switch(es) to scan...
Switches: 192.168.1.10, 192.168.1.11, 192.168.1.12

Connecting to switch: 192.168.1.10...
Connecting to switch: 192.168.1.11...
Connecting to switch: 192.168.1.12...
  Found 2 Cisco AP(s) on 192.168.1.10
  Found 1 Cisco AP(s) on 192.168.1.11
  Found 0 Cisco AP(s) on 192.168.1.12

================================================================================
RESULTS: Found 3 Cisco AP(s) total
================================================================================

Results written to: aps.csv

Summary by switch:
  192.168.1.10: 2 AP(s)
  192.168.1.11: 1 AP(s)
```

*Note: With parallel processing, connection messages may appear in different orders.*

**CSV File Output (aps.csv):**
```csv
# Run: 2026-01-12T15:30:45Z
Switch,Interface,VLAN,Model,Hostname,MAC Address
192.168.1.10,Gi1/0/1,31,C9105AXW-B,AP-Floor1-East,a1:b2:c3:d4:e5:f6
192.168.1.10,Gi1/0/5,40,AIR-AP2802I-B-K9,AP-Floor1-West,a1:b2:c3:d4:e5:f7
192.168.1.11,Gi1/0/3,31,Ieee PD,AP-Floor2-Center,a1:b2:c3:d4:e5:f8
```

## How It Works

1. **Initialization**: Starts SSH application for connection handling
2. **Authentication**: Prompts for credentials (password input is hidden on Unix/Linux/macOS)
3. **Parallel Processing**: Connects to up to 10 switches simultaneously via SSH
4. **Per Switch Processing**:
   - Runs `show power inline` to find powered devices
   - Filters for local ports (x/0/x) excluding uplinks (x/1/x)
   - Filters for interfaces with power draw > 0
   - Extracts device model from power inline output (e.g., C9105AXW-B, Ieee PD)
   - For each matching interface, runs `show mac address-table interface <interface>`
   - Extracts VLAN and MAC address from MAC address table
   - Validates MAC address against Cisco OUI prefixes (500+ known prefixes)
   - If Cisco device detected, retrieves hostname from `show cdp neighbors <interface> detail`
5. **Results Compilation**: Aggregates results from all switches
6. **CSV Output**: Writes all discovered Cisco devices to `aps.csv`

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

**First step: Check the logs!** The script creates detailed logs in `logs/[timestamp]/` that show exactly what commands were run and why devices were included or excluded.

- **Connection failures**: Verify SSH access and credentials. Check logs for connection error details.
- **No devices found**: Check logs for `show power inline` output. Verify devices are powered on (power > 0) and interfaces match x/0/x pattern (not x/1/x uplinks).
- **Hostname shows "Unknown"**: CDP may not be enabled. Enable with `cdp run` and `cdp enable` on interfaces.
- **Missing VLAN or MAC data**: Check logs for `show mac address-table interface` output.
- **Timeout errors**: Each switch has a 120-second timeout. Slow switches may timeout but others will continue processing.

## License

See LICENSE file for details.
