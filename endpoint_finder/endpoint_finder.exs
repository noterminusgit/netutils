#!/usr/bin/env elixir

# Endpoint Finder Script
# Connects to Cisco switches via SSH and discovers all endpoints (non-switch devices)
# by using CDP to identify and exclude inter-switch links, then collecting MAC address,
# LLDP name, switch hostname, switch IP, port, VLAN, and in/out traffic for each endpoint.

defmodule EndpointFinder do
  @moduledoc """
  Script to connect to Cisco switches and find all endpoints connected to access ports.
  Uses CDP to identify and exclude uplink/downlink ports between switches.
  """

  defmodule Endpoint do
    defstruct [:mac_address, :lldp_name, :switch_hostname, :switch_ip, :port, :vlan,
               :input_traffic, :output_traffic]
  end

  defmodule CdpNeighbor do
    defstruct [:switch_hostname, :switch_ip, :device_id, :neighbor_ip, :local_port,
               :remote_port, :platform, :capabilities]
  end

  def run do
    IO.puts("\n=== Endpoint Finder ===\n")

    # Start SSH application
    :ssh.start()

    # Capture run timestamp (ISO 8601 to seconds) for CSV headers
    run_time = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    # Create logging directory with timestamp
    log_timestamp = String.replace(run_time, ~r/[:\.]/, "-")
    log_dir = Path.join(["logs", log_timestamp])
    File.mkdir_p!(log_dir)
    IO.puts("Logging to: #{log_dir}\n")

    # Get credentials
    username = get_input("Enter username: ")
    password = get_password("Enter password: ")

    # Get switches filename
    switches_file = get_input("Enter switches file (one IP per line): ")

    # Optional: reconcile with previous scan
    previous_csv = get_input("Reconcile with previous CSV (leave blank to skip): ")
    previous_macs = if previous_csv != "", do: read_previous_macs(previous_csv), else: nil

    # Read switches list
    switches = read_switches_file(switches_file)

    if Enum.empty?(switches) do
      IO.puts("Error: No switches found in #{switches_file}")
      System.halt(1)
    end

    IO.puts("\nFound #{length(switches)} switch(es) to scan...")
    IO.puts("Switches: #{Enum.join(switches, ", ")}\n")

    # Process each switch in parallel
    results =
      switches
      |> Task.async_stream(
        fn switch -> process_switch(switch, username, password, log_dir) end,
        max_concurrency: 10,
        timeout: 120_000,
        on_timeout: :kill_task
      )
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, _reason} -> {[], []}
      end)

    all_endpoints = Enum.flat_map(results, fn {endpoints, _cdp} -> endpoints end)
    all_cdp_neighbors = Enum.flat_map(results, fn {_endpoints, cdp} -> cdp end)

    # Display results and write CSVs
    display_results(all_endpoints, all_cdp_neighbors, previous_macs, run_time)
  end

  # ---------------------------------------------------------------------------
  # Input helpers
  # ---------------------------------------------------------------------------

  defp get_input(prompt) do
    IO.write(prompt)
    IO.read(:stdio, :line) |> String.trim()
  end

  defp get_password(prompt) do
    try do
      :io.get_password(to_charlist(prompt)) |> to_string() |> String.trim()
    rescue
      _ ->
        IO.write(prompt <> " (WARNING: input will be visible) ")
        IO.read(:stdio, :line) |> String.trim()
    end
  end

  defp read_switches_file(filename) do
    case File.read(filename) do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(fn line ->
          line == "" or String.starts_with?(line, "#")
        end)

      {:error, reason} ->
        IO.puts("Error reading #{filename}: #{reason}")
        []
    end
  end

  defp read_previous_macs(filename) do
    case File.read(filename) do
      {:ok, content} ->
        macs =
          content
          |> String.split("\n")
          |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
          |> Enum.drop(1)  # skip header
          |> Enum.map(fn line ->
            line |> String.split(",") |> List.first() |> String.trim() |> String.downcase()
          end)
          |> MapSet.new()

        IO.puts("Loaded #{MapSet.size(macs)} MAC(s) from previous scan: #{filename}")
        macs

      {:error, reason} ->
        IO.puts("WARNING: Could not read #{filename}: #{reason} — skipping reconciliation")
        nil
    end
  end

  # ---------------------------------------------------------------------------
  # Per-switch orchestration
  # ---------------------------------------------------------------------------

  defp process_switch(switch, username, password, log_dir) do
    log_file = Path.join(log_dir, "#{sanitize_filename(switch)}.log")

    log(log_file, "=== Starting scan of switch: #{switch} ===")
    IO.puts("Connecting to switch: #{switch}...")

    case connect_ssh(switch, username, password) do
      {:ok, conn} ->
        log(log_file, "Successfully connected to #{switch}")

        case :ssh_connection.session_channel(conn, :infinity) do
          {:ok, channel} ->
            log(log_file, "SSH channel opened")

            # Request a PTY for interactive shell
            :ssh_connection.ptty_alloc(conn, channel, [
              {:term, 'vt100'},
              {:width, 80},
              {:height, 24},
              {:pixel_width, 640},
              {:pixel_height, 480},
              {:pty_opts, []}
            ])

            # Start shell
            :ssh_connection.shell(conn, channel)

            # Wait for initial prompt
            Process.sleep(500)
            _ = collect_output(conn, channel, "")

            log(log_file, "Interactive shell started")

            # Disable pagination
            log(log_file, "Disabling terminal pagination")
            case execute_command(conn, channel, "terminal length 0") do
              {:ok, _output} ->
                log(log_file, "Terminal pagination disabled")
              {:error, reason} ->
                log(log_file, "WARNING: Failed to disable pagination: #{inspect(reason)}")
            end

            {endpoints, cdp_neighbors} = discover_endpoints(conn, channel, switch, log_file)
            :ssh_connection.close(conn, channel)
            log(log_file, "SSH channel closed")
            disconnect_ssh(conn)
            log(log_file, "Found #{length(endpoints)} endpoint(s) and #{length(cdp_neighbors)} CDP neighbor(s) on #{switch}")
            log(log_file, "=== Scan complete ===")
            IO.puts("  Found #{length(endpoints)} endpoint(s) on #{switch}")
            {endpoints, cdp_neighbors}

          {:error, reason} ->
            log(log_file, "ERROR: Failed to open SSH channel: #{inspect(reason)}")
            disconnect_ssh(conn)
            {[], []}
        end

      {:error, reason} ->
        log(log_file, "ERROR: Failed to connect to #{switch}: #{inspect(reason)}")
        IO.puts("  Error connecting to #{switch}: #{inspect(reason)}")
        {[], []}
    end
  end

  defp discover_endpoints(conn, channel, switch_ip, log_file) do
    # Step 1: Get switch hostname
    switch_hostname = get_switch_hostname(conn, channel, switch_ip, log_file)
    log(log_file, "Switch hostname: #{switch_hostname}")

    # Step 2: Get CDP neighbors detail (uplink/downlink ports to exclude + neighbor info for CSV)
    {cdp_uplink_ports, cdp_neighbor_entries} = get_cdp_neighbors(conn, channel, log_file)
    log(log_file, "CDP uplink ports to exclude: #{inspect(MapSet.to_list(cdp_uplink_ports))}")

    # Build CDP neighbor structs with switch context
    cdp_neighbors = Enum.map(cdp_neighbor_entries, fn entry ->
      %CdpNeighbor{
        switch_hostname: switch_hostname,
        switch_ip: switch_ip,
        device_id: entry.device_id,
        neighbor_ip: entry.neighbor_ip,
        local_port: entry.local_port,
        remote_port: entry.remote_port,
        platform: entry.platform,
        capabilities: entry.capabilities
      }
    end)

    # Step 3: Get all MAC address table entries
    mac_entries = get_mac_entries(conn, channel, log_file)
    log(log_file, "Total MAC entries found: #{length(mac_entries)}")

    if Enum.empty?(mac_entries) do
      log(log_file, "No MAC entries found - skipping switch")
      {[], cdp_neighbors}
    else
      # Step 4: Get LLDP neighbor names
      lldp_map = get_lldp_map(conn, channel, log_file)
      log(log_file, "LLDP entries found: #{map_size(lldp_map)}")

      # Step 5: Filter out uplink ports, CPU, Port-channel, VLAN interfaces, and multicast MACs
      endpoint_macs = Enum.reject(mac_entries, fn entry ->
        MapSet.member?(cdp_uplink_ports, entry.port) or
        entry.port == "cpu" or
        String.starts_with?(entry.port, "po") or
        String.starts_with?(entry.port, "vl") or
        is_multicast_mac?(entry.mac)
      end)

      log(log_file, "Endpoint MAC entries after filtering: #{length(endpoint_macs)}")

      Enum.each(endpoint_macs, fn entry ->
        log(log_file, "  Endpoint: MAC=#{entry.mac} VLAN=#{entry.vlan} Port=#{entry.port}")
      end)

      # Step 6: Group by port, get interface stats once per port
      by_port = Enum.group_by(endpoint_macs, & &1.port)
      log(log_file, "Unique endpoint ports: #{map_size(by_port)}")

      endpoints = Enum.flat_map(by_port, fn {port, entries} ->
        {input_traffic, output_traffic} = get_interface_stats(conn, channel, port, log_file)
        lldp_name = Map.get(lldp_map, port, "N/A")

        Enum.map(entries, fn entry ->
          %Endpoint{
            mac_address: entry.mac,
            lldp_name: lldp_name,
            switch_hostname: switch_hostname,
            switch_ip: switch_ip,
            port: entry.port,
            vlan: entry.vlan,
            input_traffic: input_traffic,
            output_traffic: output_traffic
          }
        end)
      end)

      {endpoints, cdp_neighbors}
    end
  end

  # ---------------------------------------------------------------------------
  # Data collection helpers
  # ---------------------------------------------------------------------------

  defp get_switch_hostname(conn, channel, switch_ip, log_file) do
    log(log_file, "Executing: show run | include hostname")

    case execute_command(conn, channel, "show run | include hostname") do
      {:ok, output} ->
        log(log_file, "--- BEGIN show run | include hostname ---")
        log(log_file, output)
        log(log_file, "--- END show run | include hostname ---")

        parse_switch_hostname(output) || switch_ip

      {:error, reason} ->
        log(log_file, "WARNING: Failed to get hostname: #{inspect(reason)}, using IP")
        switch_ip
    end
  end

  defp get_cdp_neighbors(conn, channel, log_file) do
    log(log_file, "Executing: show cdp neighbors detail")

    case execute_command(conn, channel, "show cdp neighbors detail") do
      {:ok, output} ->
        log(log_file, "--- BEGIN show cdp neighbors detail ---")
        log(log_file, output)
        log(log_file, "--- END show cdp neighbors detail ---")

        entries = parse_cdp_neighbors_detail(output)
        log(log_file, "Parsed #{length(entries)} CDP neighbor(s)")

        uplink_ports = entries
          |> Enum.map(& &1.local_port)
          |> MapSet.new()

        log(log_file, "CDP uplink ports: #{inspect(MapSet.to_list(uplink_ports))}")
        {uplink_ports, entries}

      {:error, reason} ->
        log(log_file, "WARNING: Failed to get CDP neighbors: #{inspect(reason)}")
        log(log_file, "WARNING: Cannot exclude uplink ports - all ports will be included")
        {MapSet.new(), []}
    end
  end

  defp get_mac_entries(conn, channel, log_file) do
    log(log_file, "Executing: show mac address-table")

    case execute_command(conn, channel, "show mac address-table") do
      {:ok, output} ->
        log(log_file, "--- BEGIN show mac address-table ---")
        log(log_file, output)
        log(log_file, "--- END show mac address-table ---")

        entries = parse_mac_address_table_all(output)
        log(log_file, "Parsed #{length(entries)} MAC table entries")
        entries

      {:error, reason} ->
        log(log_file, "ERROR: Failed to get MAC address table: #{inspect(reason)}")
        []
    end
  end

  defp get_lldp_map(conn, channel, log_file) do
    log(log_file, "Executing: show lldp neighbors")

    case execute_command(conn, channel, "show lldp neighbors") do
      {:ok, output} ->
        log(log_file, "--- BEGIN show lldp neighbors ---")
        log(log_file, output)
        log(log_file, "--- END show lldp neighbors ---")

        lldp = parse_lldp_neighbors(output)
        log(log_file, "Parsed #{map_size(lldp)} LLDP neighbor(s)")
        lldp

      {:error, reason} ->
        log(log_file, "WARNING: Failed to get LLDP neighbors: #{inspect(reason)}, all LLDP names will be N/A")
        %{}
    end
  end

  defp get_interface_stats(conn, channel, port, log_file) do
    # Convert normalized short form back to a form the switch accepts
    show_port = denormalize_port(port)
    log(log_file, "Executing: show interface #{show_port}")

    case execute_command(conn, channel, "show interface #{show_port}") do
      {:ok, output} ->
        log(log_file, "--- BEGIN show interface #{show_port} ---")
        log(log_file, output)
        log(log_file, "--- END show interface #{show_port} ---")

        {input_bytes, output_bytes} = parse_interface_stats(output)
        log(log_file, "Interface stats for #{port}: input=#{input_bytes}, output=#{output_bytes}")
        {input_bytes, output_bytes}

      {:error, reason} ->
        log(log_file, "WARNING: Failed to get interface stats for #{port}: #{inspect(reason)}")
        {"N/A", "N/A"}
    end
  end

  # ---------------------------------------------------------------------------
  # Interface name normalization
  # ---------------------------------------------------------------------------

  @port_prefix_map [
    {~r/^(?:gigabitethernet|gig|gi)/i, "gi"},
    {~r/^(?:tengigabitethernet|tengige|tengig|ten|te)/i, "te"},
    {~r/^(?:twentyfivegige?|twentyfivegig|twe|tw)/i, "tw"},
    {~r/^(?:fortygigabitethernet|fortygig|fo)/i, "fo"},
    {~r/^(?:hundredgige?|hundredgig|hu)/i, "hu"},
    {~r/^(?:fastethernet|fas|fa)/i, "fa"},
    {~r/^(?:ethernet|eth|et)/i, "et"},
    {~r/^(?:port-channel|po)/i, "po"},
    {~r/^(?:appgigabitethernet|app|ap)/i, "ap"},
    {~r/^(?:vlan|vl)/i, "vl"}
  ]

  defp normalize_port(raw) do
    cleaned = raw |> String.trim() |> String.replace(~r/\s+/, "")
    lowered = String.downcase(cleaned)

    Enum.reduce_while(@port_prefix_map, lowered, fn {regex, prefix}, acc ->
      if Regex.match?(regex, acc) do
        {:halt, Regex.replace(regex, acc, prefix)}
      else
        {:cont, acc}
      end
    end)
  end

  # Convert normalized port name back to short Cisco form for show commands
  # e.g., "gi1/0/25" -> "Gi1/0/25", "te1/1/1" -> "Te1/1/1"
  @denorm_map [
    {"gi", "Gi"}, {"te", "Te"}, {"tw", "Tw"}, {"fo", "Fo"}, {"hu", "Hu"},
    {"fa", "Fa"}, {"et", "Et"}, {"po", "Po"}, {"ap", "Ap"}, {"vl", "Vl"}
  ]

  defp denormalize_port(normalized) do
    Enum.reduce_while(@denorm_map, normalized, fn {prefix, replacement}, acc ->
      if String.starts_with?(acc, prefix) do
        {:halt, replacement <> String.slice(acc, String.length(prefix)..-1//1)}
      else
        {:cont, acc}
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Parsers
  # ---------------------------------------------------------------------------

  defp parse_switch_hostname(output) do
    output
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      trimmed = String.trim(line)
      if String.starts_with?(trimmed, "hostname ") do
        trimmed
        |> String.split(~r/\s+/, parts: 2)
        |> Enum.at(1)
        |> case do
          nil -> nil
          name -> String.trim(name)
        end
      end
    end)
  end

  # Port-matching regex used by CDP and LLDP parsers
  @port_pattern ~r/(GigabitEthernet|TenGigabitEthernet|TwentyFiveGigE|FortyGigabitEthernet|HundredGigE|FastEthernet|AppGigabitEthernet|Gig|Ten|Twe|Tw|Fo|Hu|Fas|Fa|Gi|Te|Et|Ap)\s*\d+\/\d+(?:\/\d+)?/i

  # Parses "show cdp neighbors detail" output into a list of neighbor maps.
  # Each neighbor entry is separated by "-------------------------"
  defp parse_cdp_neighbors_detail(output) do
    output
    |> String.split(~r/-{10,}/)
    |> Enum.map(&parse_single_cdp_entry/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_single_cdp_entry(block) do
    lines = String.split(block, "\n")

    device_id = extract_cdp_field(lines, "Device ID:")
    neighbor_ip = extract_cdp_ip(lines)
    platform = extract_cdp_field(lines, "Platform:")
    capabilities = extract_cdp_capabilities(lines)
    {local_port, remote_port} = extract_cdp_ports(lines)

    if device_id && local_port do
      %{
        device_id: device_id,
        neighbor_ip: neighbor_ip || "N/A",
        local_port: normalize_port(local_port),
        remote_port: remote_port || "N/A",
        platform: platform || "N/A",
        capabilities: capabilities || "N/A"
      }
    end
  end

  defp extract_cdp_field(lines, field_name) do
    lines
    |> Enum.find(fn line -> String.contains?(line, field_name) end)
    |> case do
      nil -> nil
      line ->
        line
        |> String.split(field_name)
        |> List.last()
        |> String.trim()
        |> case do
          "" -> nil
          value -> value
        end
    end
  end

  defp extract_cdp_ip(lines) do
    # Look for "IP address:" or "IPv4 Address:" lines after "Entry address(es):"
    lines
    |> Enum.find_value(fn line ->
      cond do
        String.contains?(line, "IP address:") ->
          line |> String.split("IP address:") |> List.last() |> String.trim()
        String.contains?(line, "IPv4 Address:") ->
          line |> String.split("IPv4 Address:") |> List.last() |> String.trim()
        true ->
          nil
      end
    end)
  end

  defp extract_cdp_capabilities(lines) do
    lines
    |> Enum.find(fn line -> String.contains?(line, "Capabilities:") end)
    |> case do
      nil -> nil
      line ->
        line
        |> String.split("Capabilities:")
        |> List.last()
        |> String.trim()
    end
  end

  defp extract_cdp_ports(lines) do
    # Line format: "Interface: GigabitEthernet1/0/25,  Port ID (outgoing port): GigabitEthernet1/0/1"
    intf_line = Enum.find(lines, fn line ->
      String.contains?(line, "Interface:") and String.contains?(line, "Port ID")
    end)

    case intf_line do
      nil -> {nil, nil}
      line ->
        parts = String.split(line, ",")
        local = case List.first(parts) do
          nil -> nil
          p -> p |> String.split("Interface:") |> List.last() |> String.trim()
        end
        remote = case Enum.find(parts, &String.contains?(&1, "Port ID")) do
          nil -> nil
          p -> p |> String.split(~r/Port ID.*?:/) |> List.last() |> String.trim()
        end
        {local, remote}
    end
  end

  defp parse_mac_address_table_all(output) do
    output
    |> String.split("\n")
    |> Enum.filter(fn line ->
      trimmed = String.trim(line)
      parts = String.split(trimmed, ~r/\s+/)

      length(parts) >= 4 and
      trimmed != "" and
      not String.contains?(trimmed, "Vlan") and
      not String.contains?(trimmed, "---") and
      not String.contains?(trimmed, "Total") and
      not String.contains?(trimmed, "Mac Address Table") and
      mac_line?(parts)
    end)
    |> Enum.map(fn line ->
      parts = String.split(String.trim(line), ~r/\s+/)
      vlan_str = Enum.at(parts, 0)
      mac = Enum.at(parts, 1)
      port_raw = Enum.at(parts, 3)

      {vlan, _} = Integer.parse(vlan_str)
      %{vlan: vlan, mac: mac, port: normalize_port(port_raw)}
    end)
  end

  defp mac_line?(parts) do
    vlan_str = Enum.at(parts, 0)
    mac_str = Enum.at(parts, 1)

    case Integer.parse(vlan_str) do
      {_vlan, ""} ->
        Regex.match?(~r/^[0-9a-fA-F]{4}\.[0-9a-fA-F]{4}\.[0-9a-fA-F]{4}$/, mac_str)
      _ ->
        false
    end
  end

  defp parse_lldp_neighbors(output) do
    lines = String.split(output, "\n")

    # Find the header line to determine where data starts
    data_lines =
      lines
      |> Enum.reject(fn line ->
        trimmed = String.trim(line)
        trimmed == "" or
        String.contains?(trimmed, "Capability codes") or
        String.contains?(trimmed, "Capability Codes") or
        String.starts_with?(trimmed, "(") or
        String.contains?(trimmed, "Device ID") or
        String.contains?(trimmed, "---") or
        String.contains?(trimmed, "Total entries") or
        String.contains?(trimmed, "show lldp")
      end)

    Enum.reduce(data_lines, %{}, fn line, acc ->
      trimmed = String.trim(line)
      parts = String.split(trimmed, ~r/\s+/)

      # LLDP neighbor lines: DeviceID  LocalIntf  Hold-time  Capability  PortID
      case Regex.scan(@port_pattern, line) do
        [[local_intf | _] | _] ->
          # Device ID is the first field before the port pattern
          device_id = Enum.at(parts, 0, "")
          if device_id != "" do
            Map.put(acc, normalize_port(local_intf), device_id)
          else
            acc
          end
        _ ->
          acc
      end
    end)
  end

  defp parse_interface_stats(output) do
    lines = String.split(output, "\n")

    # Parse "5 minute input rate X bits/sec" and convert to bytes/sec
    input_rate = parse_rate(lines, "input")
    output_rate = parse_rate(lines, "output")

    {input_rate, output_rate}
  end

  defp parse_rate(lines, direction) do
    Enum.find_value(lines, "N/A", fn line ->
      case Regex.run(~r/(\d+)\s+bits\/sec.*#{direction}|#{direction}\s+rate\s+(\d+)\s+bits\/sec/, line) do
        nil ->
          # Try the standard Cisco format: "5 minute input rate 1000 bits/sec, 2 packets/sec"
          case Regex.run(~r/#{direction}\s+rate\s+(\d+)\s+bits/, line) do
            [_, bits_str] -> bits_to_bytes_sec(bits_str)
            _ -> nil
          end
        [_, "", bits_str] -> bits_to_bytes_sec(bits_str)
        [_, bits_str | _] -> bits_to_bytes_sec(bits_str)
      end
    end)
  end

  defp bits_to_bytes_sec(bits_str) do
    case Integer.parse(bits_str) do
      {bits, _} -> to_string(div(bits, 8))
      :error -> "N/A"
    end
  end

  defp is_multicast_mac?(mac) do
    normalized = String.downcase(mac)
    String.starts_with?(normalized, "0100.") or
    String.starts_with?(normalized, "ffff.") or
    String.starts_with?(normalized, "0180.c200") or
    String.starts_with?(normalized, "0100.0ccc")
  end

  # ---------------------------------------------------------------------------
  # SSH connection
  # ---------------------------------------------------------------------------

  # Desired algorithms in preference order (modern first, legacy last).
  # Covers Cisco IOS-XE 17.9.x defaults plus legacy for older switches.
  # At runtime, each list is filtered to only algorithms the local OTP supports.
  @desired_algorithms [
    {:kex, [
      :'curve25519-sha256@libssh.org',
      :'ecdh-sha2-nistp256',
      :'ecdh-sha2-nistp384',
      :'ecdh-sha2-nistp521',
      :'diffie-hellman-group14-sha256',
      :'diffie-hellman-group16-sha512',
      :'diffie-hellman-group18-sha512',
      :'diffie-hellman-group14-sha1',
      :'diffie-hellman-group-exchange-sha256',
      :'diffie-hellman-group-exchange-sha1',
      :'diffie-hellman-group1-sha1'
    ]},
    {:cipher, [
      :'chacha20-poly1305@openssh.com',
      :'aes128-gcm@openssh.com',
      :'aes256-gcm@openssh.com',
      :'aes128-ctr',
      :'aes192-ctr',
      :'aes256-ctr',
      :'aes128-cbc',
      :'aes192-cbc',
      :'aes256-cbc',
      :'3des-cbc'
    ]},
    {:mac, [
      :'hmac-sha2-256-etm@openssh.com',
      :'hmac-sha2-512-etm@openssh.com',
      :'hmac-sha2-256',
      :'hmac-sha2-512',
      :'hmac-sha1',
      :'hmac-sha1-96',
      :'hmac-md5',
      :'hmac-md5-96'
    ]},
    {:public_key, [
      :'rsa-sha2-512',
      :'rsa-sha2-256',
      :'ecdsa-sha2-nistp256',
      :'ecdsa-sha2-nistp384',
      :'ecdsa-sha2-nistp521',
      :'ssh-ed25519',
      :'ssh-rsa',
      :'ssh-dss'
    ]}
  ]

  # Filter desired algorithms to only those the local OTP actually supports.
  # This avoids :eoptions errors when OTP drops legacy algorithms.
  defp supported_algorithms do
    supported = :ssh.default_algorithms()

    Enum.map(@desired_algorithms, fn {type, desired} ->
      supported_for_type =
        case Keyword.get(supported, type) do
          # Some types return [{:client2server, list}, {:server2client, list}]
          [{:client2server, c2s} | _] -> MapSet.new(c2s)
          list when is_list(list) -> MapSet.new(list)
          _ -> MapSet.new()
        end

      filtered = Enum.filter(desired, &MapSet.member?(supported_for_type, &1))
      {type, filtered}
    end)
  end

  defp connect_ssh(host, username, password) do
    host_charlist = to_charlist(host)
    username_charlist = to_charlist(username)
    password_charlist = to_charlist(password)

    opts = [
      {:user, username_charlist},
      {:password, password_charlist},
      {:silently_accept_hosts, true},
      {:user_interaction, false},
      {:connect_timeout, 10000},
      {:preferred_algorithms, supported_algorithms()}
    ]

    case :ssh.connect(host_charlist, 22, opts) do
      {:ok, conn} -> {:ok, conn}
      {:error, reason} -> {:error, reason}
    end
  end

  defp disconnect_ssh(conn) do
    :ssh.close(conn)
  end

  # ---------------------------------------------------------------------------
  # Command execution
  # ---------------------------------------------------------------------------

  defp execute_command(conn, channel, command) do
    :ssh_connection.send(conn, channel, to_charlist(command <> "\n"), 0)
    output = collect_output(conn, channel, "")
    Process.sleep(100)
    {:ok, output}
  end

  defp collect_output(conn, channel, acc) do
    receive do
      {:ssh_cm, ^conn, {:data, ^channel, 0, data}} ->
        new_acc = acc <> to_string(data)

        if String.ends_with?(String.trim(new_acc), "#") or
           String.ends_with?(String.trim(new_acc), ">") do
          Process.sleep(50)
          new_acc
        else
          collect_output(conn, channel, new_acc)
        end

      {:ssh_cm, ^conn, {:eof, ^channel}} ->
        acc

      {:ssh_cm, ^conn, {:exit_status, ^channel, _status}} ->
        collect_output(conn, channel, acc)

      {:ssh_cm, ^conn, {:closed, ^channel}} ->
        acc
    after
      10000 ->
        acc
    end
  end

  # ---------------------------------------------------------------------------
  # Logging
  # ---------------------------------------------------------------------------

  defp log(log_file, message) do
    timestamp = DateTime.utc_now() |> DateTime.to_string()
    File.write!(log_file, "[#{timestamp}] #{message}\n", [:append])
  end

  defp sanitize_filename(name) do
    String.replace(name, ~r/[^a-zA-Z0-9\-_\.]/, "_")
  end

  # ---------------------------------------------------------------------------
  # Results and CSV output
  # ---------------------------------------------------------------------------

  defp display_results(endpoints, cdp_neighbors, previous_macs, run_time) do
    endpoints_file = "endpoints.csv"
    cdp_file = "cdp_neighbors.csv"
    reconciled_file = "endpoints_still_connected.csv"

    IO.puts("\n" <> String.duplicate("=", 80))
    IO.puts("RESULTS: Found #{length(endpoints)} endpoint(s) and #{length(cdp_neighbors)} CDP neighbor(s) total")
    IO.puts(String.duplicate("=", 80) <> "\n")

    if Enum.empty?(endpoints) do
      IO.puts("No endpoints found.")
    else
      write_endpoints_csv(endpoints_file, endpoints, run_time)
      IO.puts("Endpoints written to: #{endpoints_file}")
      IO.puts("\nEndpoints by switch:")

      endpoints_by_switch = Enum.group_by(endpoints, & &1.switch_ip)
      Enum.each(endpoints_by_switch, fn {switch, switch_endpoints} ->
        IO.puts("  #{switch}: #{length(switch_endpoints)} endpoint(s)")
      end)

      # Reconcile with previous scan if provided
      if previous_macs do
        still_connected = Enum.filter(endpoints, fn ep ->
          String.downcase(ep.mac_address) in previous_macs
        end)

        disconnected_count = MapSet.size(previous_macs) - length(still_connected)

        write_endpoints_csv(reconciled_file, still_connected, run_time)
        IO.puts("\n--- Reconciliation ---")
        IO.puts("Still connected: #{length(still_connected)} endpoint(s)")
        IO.puts("New (not in previous):  #{length(endpoints) - length(still_connected)} endpoint(s)")
        IO.puts("Disconnected (in previous, not now): #{max(disconnected_count, 0)} endpoint(s)")
        IO.puts("Reconciled output written to: #{reconciled_file}")
      end
    end

    if Enum.empty?(cdp_neighbors) do
      IO.puts("\nNo CDP neighbors found.")
    else
      write_cdp_csv(cdp_file, cdp_neighbors, run_time)
      IO.puts("\nCDP neighbors written to: #{cdp_file}")
      IO.puts("\nCDP neighbors by switch:")

      cdp_by_switch = Enum.group_by(cdp_neighbors, & &1.switch_ip)
      Enum.each(cdp_by_switch, fn {switch, neighbors} ->
        IO.puts("  #{switch}: #{length(neighbors)} neighbor(s)")
      end)
    end
  end

  defp write_endpoints_csv(filename, endpoints, run_time) do
    csv_lines = [
      "MAC Address,LLDP Name,Switch Hostname,Switch IP,Port,VLAN,Input (bytes/sec),Output (bytes/sec)"
      |
      Enum.map(endpoints, fn ep ->
        [
          ep.mac_address,
          ep.lldp_name,
          ep.switch_hostname,
          ep.switch_ip,
          denormalize_port(ep.port),
          to_string(ep.vlan),
          to_string(ep.input_traffic),
          to_string(ep.output_traffic)
        ]
        |> Enum.map(&escape_csv_field/1)
        |> Enum.join(",")
      end)
    ]

    write_csv(filename, csv_lines, run_time)
  end

  defp write_cdp_csv(filename, cdp_neighbors, run_time) do
    csv_lines = [
      "Switch Hostname,Switch IP,Neighbor Device ID,Neighbor IP,Local Port,Remote Port,Platform,Capabilities"
      |
      Enum.map(cdp_neighbors, fn n ->
        [
          n.switch_hostname,
          n.switch_ip,
          n.device_id,
          n.neighbor_ip,
          denormalize_port(n.local_port),
          n.remote_port,
          n.platform,
          n.capabilities
        ]
        |> Enum.map(&escape_csv_field/1)
        |> Enum.join(",")
      end)
    ]

    write_csv(filename, csv_lines, run_time)
  end

  defp write_csv(filename, csv_lines, run_time) do
    content = "# Run: #{run_time}\n" <> Enum.join(csv_lines, "\n") <> "\n"

    case File.write(filename, content) do
      :ok -> :ok
      {:error, reason} -> IO.puts("Error writing to #{filename}: #{reason}")
    end
  end

  defp escape_csv_field(field) do
    if String.contains?(field, [",", "\"", "\n"]) do
      "\"#{String.replace(field, "\"", "\"\"")}\""
    else
      field
    end
  end
end

# Run the script
EndpointFinder.run()
