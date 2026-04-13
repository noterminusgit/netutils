# Endpoint Finder

Discovers all endpoints (non-switch devices) connected to Cisco switches by excluding inter-switch links identified via CDP.

## Description

`endpoint_finder.exs` connects to a list of Cisco switches via SSH and discovers all endpoint devices connected to access ports. It uses CDP (Cisco Discovery Protocol) to identify uplink and downlink ports between switches and excludes them, leaving only ports with end-user devices such as PCs, printers, phones, and IoT devices.

For each endpoint, the script collects:
- **MAC Address** from the MAC address table
- **LLDP Name** from LLDP neighbor data (if the endpoint supports LLDP)
- **Switch Hostname** of the switch the endpoint is connected to
- **Switch IP** address used for the SSH connection
- **Port** the endpoint is connected to
- **VLAN** the endpoint is on
- **Description** from the interface configuration (if set)
- **Input/Output** rate (bytes/sec) from the 5-minute interface rate counters

## Features

- Interactive username/password authentication (secure password input)
- Parallel processing of up to 10 switches simultaneously
- Reads switch list from a configurable text file
- Uses CDP to identify and exclude inter-switch uplink/downlink ports
- Collects LLDP system names for endpoints that support LLDP
- Retrieves 5-minute interface rates (input/output bytes/sec)
- Normalizes interface names across different Cisco CLI output formats
- Filters out multicast MACs, CPU entries, Port-channels, and VLAN interfaces
- Outputs timestamped CSV files: `<timestamp>-endpoints.csv` and `<timestamp>-cdp_neighbors.csv`
- Optional reconciliation with a previous scan to show only still-connected devices
- Detailed logging to `logs/[timestamp]/` directory (one log per switch)
- Fault-tolerant: continues processing if individual switches fail or timeout

## Prerequisites

- Elixir installed on your system
- SSH access to Cisco switches
- A text file containing switch IP addresses or hostnames (one per line)
- CDP enabled on switches (required for uplink detection)
- LLDP enabled (optional - only needed for endpoint name resolution)

## Setup

1. Navigate to the script directory:
   ```bash
   cd endpoint_finder
   ```

2. Create or edit `switches.txt` with your switch IP addresses or hostnames (one per line):
   ```
   # Edge switches
   192.168.1.10
   192.168.1.11
   192.168.1.12
   ```

   Lines starting with `#` are comments and will be ignored.

3. Ensure you have SSH credentials with privileges to run:
   - `show run | include hostname`
   - `show cdp neighbors detail`
   - `show mac address-table`
   - `show lldp neighbors`
   - `show interface <port>`

## Usage

```bash
cd endpoint_finder
elixir endpoint_finder.exs
```

Or:
```bash
cd endpoint_finder
chmod +x endpoint_finder.exs
./endpoint_finder.exs
```

The script will:
1. Prompt for your username
2. Prompt for your password (input hidden on Unix/Linux/macOS)
3. Prompt for the switches file name (e.g., `switches.txt`)
4. Prompt for a previous CSV to reconcile against (optional - press Enter to skip)
5. Connect to switches (up to 10 in parallel)
6. Discover endpoints and CDP neighbors on each switch
7. Write results to `<timestamp>-endpoints.csv` and `<timestamp>-cdp_neighbors.csv`
8. If reconciling, write `<timestamp>-endpoints_still_connected.csv` with only the devices found in both scans

## Example Output

**Terminal Output:**
```
=== Endpoint Finder ===

Logging to: logs/2026-01-15T10-30-45-123456Z

Enter username: admin
Enter password: [hidden]
Enter switches file (one IP per line): switches.txt
Reconcile with previous CSV (leave blank to skip): 2026-01-14T08-00-00Z-endpoints.csv
Loaded 35 MAC(s) from previous scan: 2026-01-14T08-00-00Z-endpoints.csv

Found 3 switch(es) to scan...
Switches: 192.168.1.10, 192.168.1.11, 192.168.1.12

Connecting to switch: 192.168.1.10...
Connecting to switch: 192.168.1.11...
Connecting to switch: 192.168.1.12...
  Found 15 endpoint(s) on 192.168.1.10
  Found 8 endpoint(s) on 192.168.1.11
  Found 12 endpoint(s) on 192.168.1.12

================================================================================
RESULTS: Found 35 endpoint(s) and 6 CDP neighbor(s) total
================================================================================

Endpoints written to: 2026-01-15T10-30-45Z-endpoints.csv

Endpoints by switch:
  192.168.1.10: 15 endpoint(s)
  192.168.1.11: 8 endpoint(s)
  192.168.1.12: 12 endpoint(s)

--- Reconciliation ---
Still connected: 30 endpoint(s)
New (not in previous):  5 endpoint(s)
Disconnected (in previous, not now): 5 endpoint(s)
Reconciled output written to: 2026-01-15T10-30-45Z-endpoints_still_connected.csv

CDP neighbors written to: 2026-01-15T10-30-45Z-cdp_neighbors.csv

CDP neighbors by switch:
  192.168.1.10: 2 neighbor(s)
  192.168.1.11: 2 neighbor(s)
  192.168.1.12: 2 neighbor(s)
```

*Note: With parallel processing, connection messages may appear in different orders.*

**Endpoints CSV (2026-01-15T10-30-45Z-endpoints.csv):**
```csv
MAC Address,LLDP Name,Switch Hostname,Switch IP,Port,VLAN,Description,Input (bytes/sec),Output (bytes/sec)
a1b2.c3d4.e5f6,printer-floor2,SWITCH-01,192.168.1.10,Gi1/0/1,10,PRINTER-2F,125,62
f6e5.d4c3.b2a1,N/A,SWITCH-01,192.168.1.10,Gi1/0/5,20,N/A,1250,625
1234.5678.9abc,phone-desk42,SWITCH-02,192.168.1.11,Gi1/0/8,30,DESK-42-PHONE,3750,1875
```

**CDP Neighbors CSV (2026-01-15T10-30-45Z-cdp_neighbors.csv):**
```csv
Switch Hostname,Switch IP,Neighbor Device ID,Neighbor IP,Local Port,Remote Port,Platform,Capabilities
SWITCH-01,192.168.1.10,SWITCH-02.domain.com,10.0.0.2,Gi1/0/25,Gi1/0/1,cisco WS-C3750-48P,Router Switch IGMP
SWITCH-01,192.168.1.10,CORE-SW.domain.com,10.0.0.1,Te1/1/1,Te1/0/1,cisco C9300-48P,Router Switch IGMP
SWITCH-02,192.168.1.11,SWITCH-01.domain.com,10.0.0.3,Gi1/0/25,Gi1/0/25,cisco C9200-48P,Router Switch IGMP
```

## How It Works

1. **Initialization**: Starts SSH application for connection handling
2. **Authentication**: Prompts for credentials (password input is hidden on Unix/Linux/macOS)
3. **Parallel Processing**: Connects to up to 10 switches simultaneously via SSH
4. **Per Switch Processing**:
   - Gets the switch hostname from `show run | include hostname`
   - Runs `show cdp neighbors detail` to find ports connected to other switches and collect neighbor IPs
   - Runs `show mac address-table` to get all MAC addresses, VLANs, and ports
   - Runs `show lldp neighbors` to get LLDP device names
   - Filters out: CDP uplink ports, CPU entries, Port-channels, VLAN interfaces, multicast MACs
   - For each unique endpoint port, runs `show interface <port>` to get traffic statistics
   - Builds endpoint records with all collected data
5. **Results Compilation**: Aggregates results from all switches
6. **CSV Output**: Writes endpoints to `<timestamp>-endpoints.csv` and CDP neighbors to `<timestamp>-cdp_neighbors.csv`
7. **Reconciliation** (optional): If a previous CSV was provided, filters current results to only endpoints whose MAC addresses appeared in the previous scan, and writes to `<timestamp>-endpoints_still_connected.csv`

## Reconciliation

To find which devices are still connected since a previous scan, provide the path to a previous endpoints CSV when prompted. The script will:

- Run a full scan as normal and write `<timestamp>-endpoints.csv`
- Compare MAC addresses between the previous and current scan
- Write `<timestamp>-endpoints_still_connected.csv` containing only endpoints present in both scans (with current data)
- Report counts of still-connected, new, and disconnected endpoints

This is useful for tracking device churn, verifying migrations, or confirming that specific devices remain online.

## Logging

The script automatically creates detailed logs in the `logs/` directory. Each run creates a timestamped subdirectory containing one log file per switch.

Log files contain:
- All commands executed on the switch
- Raw output from each command
- Parsing results and filtering decisions
- CDP uplink ports identified for exclusion
- Number of endpoints found per stage
- Any errors or warnings encountered

```bash
ls -la logs/                    # List all runs
cat logs/[timestamp]/*.log      # View all logs from a run
```

## Troubleshooting

**First step: Check the logs!** The script creates detailed logs that show exactly what happened on each switch.

- **Connection failures**:
  - Verify SSH access and credentials
  - Check logs for connection error details
- **No endpoints found**:
  - Check logs for `show mac address-table` output
  - Verify the MAC address table is populated
  - Check if all ports are being excluded as CDP neighbors
- **All ports excluded as uplinks**:
  - Check logs for `show cdp neighbors` output
  - Verify CDP is working correctly on the switch
- **LLDP Name shows "N/A"**:
  - LLDP may not be enabled or the endpoint may not support LLDP
  - Enable LLDP with `lldp run` on the switch
- **Traffic shows "N/A"**:
  - Check logs for `show interface` output
  - Verify the interface name is being parsed correctly
- **Timeout errors**: Each switch has a 120-second timeout. Switches with many endpoints may timeout
- **Interface name mismatches**: If CDP ports aren't being excluded correctly, check the logs for the normalized port names. The normalization handles common Cisco abbreviations but unusual formats may need attention

## License

See LICENSE file for details.
