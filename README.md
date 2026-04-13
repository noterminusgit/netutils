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

## Endpoint Finder

Discovers all endpoints (non-switch devices) on Cisco edge switches. Uses CDP to identify and exclude inter-switch uplinks/downlinks, then collects MAC address, LLDP name, switch hostname, switch IP, port, VLAN, and in/out traffic for each remaining endpoint. Also outputs a separate CSV of CDP neighbors with their IPs.

```bash
cd endpoint_finder
elixir endpoint_finder.exs
```

See [`endpoint_finder/README.md`](endpoint_finder/README.md) for detailed documentation.

### License

See LICENSE file for details.
