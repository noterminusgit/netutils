#!/usr/bin/env elixir

# Down Port Finder Script
# Connects to Cisco switches via SSH and reports access ports that are assigned
# to VLANs 161-164 and are currently NOT connected or DISABLED. Uses
# "show interfaces status" to read each port's access VLAN and link status, and
# "show interfaces description" to attach the full interface description.
#
# Input  : switches.txt  (one IP/hostname per line; '#' lines are comments)
# Output : down_ports.csv
# Logging: logs/<ISO8601-seconds>-down_port_finder.log  (single run log)

defmodule DownPortFinder do
  @moduledoc """
  Find Cisco switch ports on VLANs 161-164 that are not connected or disabled.
  """

  # VLANs of interest (inclusive range).
  @target_vlans 161..164

  # "show interfaces status" link states that count as a down port.
  #   notconnect   - no link / nothing plugged in
  #   disabled     - administratively shut
  #   err-disabled - error-disabled by the switch
  @down_statuses ~w(notconnect disabled err-disabled)

  # All single-token states that may appear in the Status column. Used to locate
  # the Status field so the (space-containing) Name field can be isolated.
  @status_keywords ~w(connected notconnect disabled err-disabled monitoring
                      faulty inactive suspended dormant up down)

  defmodule DownPort do
    defstruct [:switch_hostname, :switch_ip, :port, :description, :status, :vlan]
  end

  def run do
    IO.puts("\n=== Down Port Finder (VLANs 161-164) ===\n")

    :ssh.start()

    # Capture run timestamp (ISO 8601 to seconds) for the log filename.
    run_time = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    # Single run log: logs/<ISO8601-seconds>-<script name>.log
    File.mkdir_p!("logs")
    log_file = Path.join("logs", "#{run_time}-down_port_finder.log")
    log(log_file, "=== Down Port Finder run started ===")
    IO.puts("Logging to: #{log_file}\n")

    username = get_input("Enter username: ")
    password = get_password("Enter password: ")

    switches_file = get_input("Enter switches file (one IP per line) [switches.txt]: ")
    switches_file = if switches_file == "", do: "switches.txt", else: switches_file

    switches = read_switches_file(switches_file)

    if Enum.empty?(switches) do
      IO.puts("Error: No switches found in #{switches_file}")
      System.halt(1)
    end

    IO.puts("\nFound #{length(switches)} switch(es) to scan...")
    IO.puts("Switches: #{Enum.join(switches, ", ")}\n")
    log(log_file, "Scanning #{length(switches)} switch(es): #{Enum.join(switches, ", ")}")

    down_ports =
      switches
      |> Task.async_stream(
        fn switch -> process_switch(switch, username, password, log_file) end,
        max_concurrency: 500,
        timeout: 120_000,
        on_timeout: :kill_task
      )
      |> Enum.flat_map(fn
        {:ok, result} ->
          result

        {:exit, reason} ->
          log(log_file, "ERROR: Task timed out or crashed: #{inspect(reason)}")
          []
      end)

    log(log_file, "=== Down Port Finder run complete: #{length(down_ports)} port(s) ===")
    display_results(down_ports)
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
        |> Enum.reject(fn line -> line == "" or String.starts_with?(line, "#") end)

      {:error, reason} ->
        IO.puts("Error reading #{filename}: #{reason}")
        []
    end
  end

  # ---------------------------------------------------------------------------
  # Per-switch orchestration
  # ---------------------------------------------------------------------------

  defp process_switch(switch, username, password, log_file) do
    log(log_file, "[#{switch}] === Starting scan ===")
    IO.puts("Connecting to switch: #{switch}...")

    case connect_ssh(switch, username, password) do
      {:ok, conn} ->
        log(log_file, "[#{switch}] Successfully connected")

        case :ssh_connection.session_channel(conn, :infinity) do
          {:ok, channel} ->
            log(log_file, "[#{switch}] SSH channel opened")

            :ssh_connection.ptty_alloc(conn, channel, [
              {:term, ~c"vt100"},
              {:width, 80},
              {:height, 24},
              {:pixel_width, 640},
              {:pixel_height, 480},
              {:pty_opts, []}
            ])

            :ssh_connection.shell(conn, channel)
            Process.sleep(500)
            _ = collect_output(conn, channel, "")

            log(log_file, "[#{switch}] Interactive shell started")

            case execute_command(conn, channel, "terminal length 0") do
              {:ok, _} ->
                log(log_file, "[#{switch}] Terminal pagination disabled")

              {:error, reason} ->
                log(log_file, "[#{switch}] ERROR: Failed to disable pagination: #{inspect(reason)}")
            end

            down_ports = discover_down_ports(conn, channel, switch, log_file)
            :ssh_connection.close(conn, channel)
            log(log_file, "[#{switch}] SSH channel closed")
            disconnect_ssh(conn)
            log(log_file, "[#{switch}] Found #{length(down_ports)} down port(s) on VLANs 161-164")
            log(log_file, "[#{switch}] === Scan complete ===")
            IO.puts("  Found #{length(down_ports)} down port(s) on #{switch}")
            down_ports

          {:error, reason} ->
            log(log_file, "[#{switch}] ERROR: Failed to open SSH channel: #{inspect(reason)}")
            disconnect_ssh(conn)
            []
        end

      {:error, reason} ->
        log(log_file, "[#{switch}] ERROR: Failed to connect: #{inspect(reason)}")
        IO.puts("  Error connecting to #{switch}: #{inspect(reason)}")
        []
    end
  end

  defp discover_down_ports(conn, channel, switch_ip, log_file) do
    switch_hostname = get_switch_hostname(conn, channel, switch_ip, log_file)
    log(log_file, "[#{switch_ip}] Switch hostname: #{switch_hostname}")

    # Map of normalized port -> full interface description (best-effort).
    descriptions = get_descriptions(conn, channel, switch_ip, log_file)

    status_entries = get_interface_status(conn, channel, switch_ip, log_file)
    log(log_file, "[#{switch_ip}] Parsed #{length(status_entries)} interface status row(s)")

    matches =
      Enum.filter(status_entries, fn entry ->
        entry.status in @down_statuses and vlan_in_target?(entry.vlan)
      end)

    log(log_file, "[#{switch_ip}] Matching down ports on VLANs 161-164: #{length(matches)}")

    Enum.map(matches, fn entry ->
      {vlan, _} = Integer.parse(entry.vlan)
      description = Map.get(descriptions, entry.port) || blank_to_na(entry.name)

      log(log_file,
        "[#{switch_ip}]   #{denormalize_port(entry.port)} VLAN=#{vlan} status=#{entry.status} desc=#{description}")

      %DownPort{
        switch_hostname: switch_hostname,
        switch_ip: switch_ip,
        port: entry.port,
        description: description,
        status: entry.status,
        vlan: vlan
      }
    end)
  end

  # ---------------------------------------------------------------------------
  # Data collection helpers
  # ---------------------------------------------------------------------------

  defp get_switch_hostname(conn, channel, switch_ip, log_file) do
    log(log_file, "[#{switch_ip}] Executing: show run | include hostname")

    case execute_command(conn, channel, "show run | include hostname") do
      {:ok, output} ->
        log(log_file, "[#{switch_ip}] --- BEGIN show run | include hostname ---")
        log(log_file, output)
        log(log_file, "[#{switch_ip}] --- END show run | include hostname ---")
        parse_switch_hostname(output) || switch_ip

      {:error, reason} ->
        log(log_file, "[#{switch_ip}] ERROR: Failed to get hostname: #{inspect(reason)}, using IP")
        switch_ip
    end
  end

  defp get_interface_status(conn, channel, switch_ip, log_file) do
    log(log_file, "[#{switch_ip}] Executing: show interfaces status")

    case execute_command(conn, channel, "show interfaces status") do
      {:ok, output} ->
        log(log_file, "[#{switch_ip}] --- BEGIN show interfaces status ---")
        log(log_file, output)
        log(log_file, "[#{switch_ip}] --- END show interfaces status ---")
        parse_interface_status(output)

      {:error, reason} ->
        log(log_file, "[#{switch_ip}] ERROR: Failed to get interface status: #{inspect(reason)}")
        []
    end
  end

  defp get_descriptions(conn, channel, switch_ip, log_file) do
    log(log_file, "[#{switch_ip}] Executing: show interfaces description")

    case execute_command(conn, channel, "show interfaces description") do
      {:ok, output} ->
        log(log_file, "[#{switch_ip}] --- BEGIN show interfaces description ---")
        log(log_file, output)
        log(log_file, "[#{switch_ip}] --- END show interfaces description ---")
        parse_interface_descriptions(output)

      {:error, reason} ->
        log(log_file, "[#{switch_ip}] ERROR: Failed to get interface descriptions: #{inspect(reason)}")
        %{}
    end
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
        trimmed |> String.split(~r/\s+/, parts: 2) |> Enum.at(1) |> String.trim()
      end
    end)
  end

  # Parse "show interfaces status". Columns are fixed-width but the Name field
  # may contain spaces, so we locate the Status token (a known keyword) and read
  # the VLAN from the token immediately after it.
  #
  #   Port      Name               Status       Vlan       Duplex  Speed Type
  #   Gi1/0/1   Office PC          notconnect   161           auto   auto 10/100/1000BaseTX
  #   Gi1/0/2                      disabled     162           auto   auto 10/100/1000BaseTX
  defp parse_interface_status(output) do
    output
    |> String.split("\n")
    |> Enum.map(&parse_status_line/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_status_line(line) do
    trimmed = String.trim(line)

    if trimmed == "" do
      nil
    else
      parts = String.split(trimmed, ~r/\s+/)
      port_raw = List.first(parts)

      status_idx = find_status_index(parts)

      if port_line?(port_raw) and status_idx != nil do
        status = Enum.at(parts, status_idx)
        vlan_str = Enum.at(parts, status_idx + 1)
        name = parts |> Enum.slice(1, status_idx - 1) |> Enum.join(" ")

        if vlan_str do
          %{
            port: normalize_port(port_raw),
            name: name,
            status: status,
            vlan: vlan_str
          }
        end
      end
    end
  end

  # Index (within `parts`) of the first token that is a known Status keyword.
  # Skips index 0 (the port) so a port literally named like a status can't match.
  defp find_status_index(parts) do
    parts
    |> Enum.with_index()
    |> Enum.find_value(fn {token, idx} ->
      if idx >= 1 and token in @status_keywords, do: idx, else: nil
    end)
  end

  # A data row starts with an interface name such as Gi1/0/1, Te1/1/1, Po1.
  # The header ("Port") and separators ("----") have no leading-letters+digit.
  defp port_line?(nil), do: false
  defp port_line?(token), do: Regex.match?(~r/^[A-Za-z]{2,}\d/, token)

  # Parse "show interfaces description" into %{normalized_port => description}.
  #
  #   Interface              Status         Protocol Description
  #   Gi1/0/1                down           down     Office PC
  #   Gi1/0/2                admin down     down
  defp parse_interface_descriptions(output) do
    output
    |> String.split("\n")
    |> Enum.reduce(%{}, fn line, acc ->
      case parse_description_line(line) do
        {port, description} -> Map.put(acc, port, description)
        nil -> acc
      end
    end)
  end

  defp parse_description_line(line) do
    trimmed = String.trim(line)
    parts = String.split(trimmed, ~r/\s+/)
    port_raw = List.first(parts)

    if port_line?(port_raw) do
      # Layout: Interface  Status  Protocol  Description...
      # Status is a single token ("up"/"down"/"deleted") except for the two-token
      # "admin down". Protocol is always a single token, so the description starts
      # right after it. Computing the protocol index positionally (rather than by
      # matching "up"/"down") avoids mistaking the second word of "admin down" for
      # the protocol column.
      proto_idx = if Enum.at(parts, 1) == "admin", do: 3, else: 2
      description = parts |> Enum.drop(proto_idx + 1) |> Enum.join(" ") |> blank_to_na()
      {normalize_port(port_raw), description}
    end
  end

  defp blank_to_na(nil), do: "N/A"
  defp blank_to_na(""), do: "N/A"
  defp blank_to_na(value), do: value

  defp vlan_in_target?(vlan_str) do
    case Integer.parse(vlan_str) do
      {vlan, ""} -> vlan in @target_vlans
      _ -> false
    end
  end

  # ---------------------------------------------------------------------------
  # Interface name normalization (mirrors endpoint_finder)
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
  # SSH connection (mirrors endpoint_finder for broad Cisco IOS-XE support)
  # ---------------------------------------------------------------------------

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

  defp algorithm_options do
    defaults = :ssh.default_algorithms()

    append_list =
      Enum.map(@desired_algorithms, fn {type, desired} ->
        default_for_type =
          case Keyword.get(defaults, type) do
            [{:client2server, c2s} | _] -> MapSet.new(c2s)
            list when is_list(list) -> MapSet.new(list)
            _ -> MapSet.new()
          end

        missing = Enum.reject(desired, &MapSet.member?(default_for_type, &1))
        {type, missing}
      end)
      |> Enum.reject(fn {_type, list} -> list == [] end)

    preferred =
      Enum.map(@desired_algorithms, fn {type, desired} ->
        default_for_type =
          case Keyword.get(defaults, type) do
            [{:client2server, c2s} | _] -> MapSet.new(c2s)
            list when is_list(list) -> MapSet.new(list)
            _ -> MapSet.new()
          end

        in_defaults = Enum.filter(desired, &MapSet.member?(default_for_type, &1))
        {type, in_defaults}
      end)

    opts = [{:preferred_algorithms, preferred}]

    if append_list != [] do
      [{:modify_algorithms, [{:append, append_list}]} | opts]
    else
      opts
    end
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
      {:quiet_mode, true},
      {:connect_timeout, 10000}
    ] ++ algorithm_options()

    case :ssh.connect(host_charlist, 22, opts) do
      {:ok, conn} -> {:ok, conn}
      {:error, reason} -> {:error, reason}
    end
  end

  defp disconnect_ssh(conn), do: :ssh.close(conn)

  # ---------------------------------------------------------------------------
  # Command execution
  # ---------------------------------------------------------------------------

  defp execute_command(conn, channel, command) do
    case :ssh_connection.send(conn, channel, to_charlist(command <> "\n"), 0) do
      :ok ->
        output = collect_output(conn, channel, "")
        Process.sleep(100)
        {:ok, output}

      {:error, reason} ->
        {:error, reason}
    end
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
      10000 -> acc
    end
  end

  # ---------------------------------------------------------------------------
  # Logging (single run log; concurrent single-line appends are safe)
  # ---------------------------------------------------------------------------

  defp log(log_file, message) do
    timestamp = DateTime.utc_now() |> DateTime.to_string()
    File.write!(log_file, "[#{timestamp}] #{message}\n", [:append])
  end

  # ---------------------------------------------------------------------------
  # Results and CSV output
  # ---------------------------------------------------------------------------

  defp display_results(down_ports) do
    csv_file = "down_ports.csv"

    IO.puts("\n" <> String.duplicate("=", 80))
    IO.puts("RESULTS: Found #{length(down_ports)} down port(s) on VLANs 161-164 total")
    IO.puts(String.duplicate("=", 80) <> "\n")

    write_down_ports_csv(csv_file, down_ports)
    IO.puts("Down ports written to: #{csv_file}\n")

    if Enum.empty?(down_ports) do
      IO.puts("No down ports found on VLANs 161-164.")
    else
      IO.puts("Down ports by switch:")

      down_ports
      |> Enum.group_by(& &1.switch_ip)
      |> Enum.each(fn {switch, list} ->
        IO.puts("  #{switch}: #{length(list)} port(s)")
      end)
    end
  end

  defp write_down_ports_csv(filename, down_ports) do
    csv_lines = [
      "Switch Hostname,Switch IP,Port,Description,Status,VLAN"
      |
      Enum.map(down_ports, fn p ->
        [
          p.switch_hostname,
          p.switch_ip,
          denormalize_port(p.port),
          p.description,
          p.status,
          to_string(p.vlan)
        ]
        |> Enum.map(&escape_csv_field/1)
        |> Enum.join(",")
      end)
    ]

    content = Enum.join(csv_lines, "\n") <> "\n"

    case File.write(filename, content) do
      :ok -> :ok
      {:error, reason} -> IO.puts("Error writing to #{filename}: #{reason}")
    end
  end

  defp escape_csv_field(field) do
    field = to_string(field)

    if String.contains?(field, [",", "\"", "\n"]) do
      "\"#{String.replace(field, "\"", "\"\"")}\""
    else
      field
    end
  end
end

# Run the script
DownPortFinder.run()
