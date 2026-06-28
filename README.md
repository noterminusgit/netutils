# netutils
Network utilities for managing Cisco infrastructure

## Cisco AP Finder

Discovers Cisco Access Points connected to switches via Power over Ethernet (PoE). Uses `show power inline` to find powered devices, validates against 500+ Cisco OUI prefixes, and resolves hostnames via CDP. Outputs to `aps.csv`.

```bash
cd cisco_ap_finder
elixir cisco_ap_finder.exs
```

See [`cisco_ap_finder/README.md`](cisco_ap_finder/README.md) for detailed documentation.

---

## AP Mismatch Finder

Discovers Cisco Access Points the same way as the Cisco AP Finder, then diffs each AP's interface description against its CDP hostname and outputs only the ports where the two values don't match. Useful for auditing that port descriptions stay in sync with the APs plugged into them. Outputs to `output/<timestamp>-ap_mismatches.csv`.

```bash
cd ap_mismatch_finder
elixir ap_mismatch_finder.exs
```

See [`ap_mismatch_finder/README.md`](ap_mismatch_finder/README.md) for detailed documentation.

---

## Endpoint Finder

Discovers all endpoints (non-switch devices) on Cisco edge switches. Uses CDP to identify and exclude inter-switch uplinks/downlinks, then collects MAC address, LLDP name, switch hostname, switch IP, port, VLAN, and in/out traffic for each remaining endpoint. Also outputs a separate CSV of CDP neighbors with their IPs.

```bash
cd endpoint_finder
elixir endpoint_finder.exs
```

See [`endpoint_finder/README.md`](endpoint_finder/README.md) for detailed documentation.

---

## QSFP-SFP Adapter Finder

Finds QSFP-to-SFP adapters (e.g., `CVR-QSFP-SFP10G`) installed in Cisco switches by parsing `show inventory`, then reports each adapter's port, connection status, and interface description to a timestamped CSV.

```bash
cd qsfp_sfp_adapter_finder
elixir qsfp_sfp_adapter_finder.exs
```

See [`qsfp_sfp_adapter_finder/README.md`](qsfp_sfp_adapter_finder/README.md) for detailed documentation.

---

## Down Port Finder

Finds Cisco switch ports assigned to VLANs 161-164 that are not connected or disabled. Parses `show interfaces status` for each port's access VLAN and link state and `show interfaces description` for the full description, then reports matching ports (status `notconnect`, `disabled`, or `err-disabled`) to `down_ports.csv`.

```bash
cd down_port_finder
elixir down_port_finder.exs
```

See [`down_port_finder/README.md`](down_port_finder/README.md) for detailed documentation.

### License

See LICENSE file for details.
