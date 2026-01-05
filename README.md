# netutils
Network utilities for managing Cisco infrastructure

## Cisco AP Finder

A script to discover Cisco Access Points connected to Cisco switches via Power over Ethernet (PoE).

### Description

`cisco_ap_finder.exs` connects to a list of Cisco switches via SSH, runs the `show power inline` command to identify powered devices on local ports, and then uses CDP (Cisco Discovery Protocol) to retrieve detailed information about Cisco devices. It matches devices based on Cisco OUI (MAC address prefix) to ensure only Cisco equipment is included.

### Features

- Interactive username/password authentication
- Reads switch list from `switches.txt`
- Identifies powered devices on local ports (x/0/x interfaces)
- Excludes uplink ports (x/1/x interfaces)
- Filters devices by Cisco OUI (MAC address prefix)
- Retrieves hostname and MAC address via CDP
- Outputs results to `aps.csv` in CSV format for easy analysis

### Prerequisites

- Elixir installed on your system
- SSH access to Cisco switches
- CDP enabled on switches and APs
- Switches listed in `switches.txt`

### Setup

1. Create a `switches.txt` file with one switch IP address or hostname per line:
   ```
   192.168.1.10
   192.168.1.11
   192.168.1.12
   ```

   Lines starting with `#` are treated as comments.

2. Ensure you have SSH credentials with appropriate privileges to run:
   - `show power inline`
   - `show cdp neighbors detail`

### Usage

Run the script:
```bash
./cisco_ap_finder.exs
```

Or:
```bash
elixir cisco_ap_finder.exs
```

The script will:
1. Prompt for your username
2. Prompt for your password
3. Connect to each switch in `switches.txt`
4. Discover Cisco APs on each switch
5. Write results to `aps.csv`

### Example Output

**Terminal Output:**
```
=== Cisco AP Finder ===

Enter username: admin
Enter password:

Found 3 switch(es) to scan...
Switches: 192.168.1.10, 192.168.1.11, 192.168.1.12

Connecting to switch: 192.168.1.10...
  Found 2 Cisco AP(s) on 192.168.1.10
Connecting to switch: 192.168.1.11...
  Found 1 Cisco AP(s) on 192.168.1.11

================================================================================
RESULTS: Found 3 Cisco AP(s) total
================================================================================

Results written to: aps.csv

Summary by switch:
  192.168.1.10: 2 AP(s)
  192.168.1.11: 1 AP(s)
```

**CSV File Output (aps.csv):**
```csv
Switch,Interface,Hostname,MAC Address
192.168.1.10,Gi1/0/1,AP-Floor1-East,a1:b2:c3:d4:e5:f6
192.168.1.10,Gi1/0/5,AP-Floor1-West,a1:b2:c3:d4:e5:f7
192.168.1.11,Gi1/0/3,AP-Floor2-Center,a1:b2:c3:d4:e5:f8
```

### How It Works

1. **Authentication**: Prompts for credentials to use across all switches
2. **Switch Connection**: Connects to each switch via SSH
3. **Power Inline Check**: Runs `show power inline` to find powered devices
4. **Local Port Filter**: Identifies local ports (x/0/x pattern) and excludes uplinks (x/1/x pattern)
5. **Power Draw Filter**: Only includes interfaces with power draw > 0
6. **CDP Query**: For each matching interface, runs `show cdp neighbors <interface> detail`
7. **Data Extraction**: Parses CDP output to extract hostname and MAC address
8. **Cisco OUI Validation**: Verifies MAC address starts with a Cisco OUI prefix
9. **Results Output**: Writes all discovered Cisco devices to `aps.csv`

### Troubleshooting

- **Connection failures**: Verify SSH access and credentials
- **No APs found**: Ensure CDP is enabled (`cdp run` and `cdp enable` on interfaces)
- **Missing MAC addresses**: Check that CDP is advertising properly
- **Script hangs**: May indicate SSH timeout - check network connectivity

### License

See LICENSE file for details.
