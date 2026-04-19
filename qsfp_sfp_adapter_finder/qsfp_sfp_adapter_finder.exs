#!/usr/bin/env elixir

# QSFP-SFP Adapter Finder Script
# Connects to Cisco switches via SSH, parses "show inventory" to find
# QSFP-to-SFP adapters (e.g., CVR-QSFP-SFP10G), then checks the connection
# status and description of each port that has one installed.

defmodule QsfpSfpAdapterFinder do
  @moduledoc """
  Discover QSFP-SFP adapters installed in Cisco switches and report whether
  each adapter port is currently connected.
  """

  defmodule Adapter do
    defstruct [:switch_hostname, :switch_ip, :port, :adapter_pid,
               :adapter_descr, :connection_status, :interface_description]
  end

  def run do
    IO.puts("\n=== QSFP-SFP Adapter Finder ===\n")

    :ssh.start()

    # Capture run timestamp (ISO 8601 to seconds) for CSV / log filenames
    run_time = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    file_timestamp = String.replace(run_time, ~r/[:\.]/, "-")

    log_dir = Path.join(["logs", file_timestamp])
    File.mkdir_p!(log_dir)
    IO.puts("Logging to: #{log_dir}\n")

    username = get_input("Enter username: ")
    password = get_password("Enter password: ")

    devices_file = get_input("Enter devices file (one IP per line) [devices.txt]: ")
    devices_file = if devices_file == "", do: "devices.txt", else: devices_file

    devices = read_devices_file(devices_file)

    if Enum.empty?(devices) do
      IO.puts("Error: No devices found in #{devices_file}")
      System.halt(1)
    end

    IO.puts("\nFound #{length(devices)} device(s) to scan...")
    IO.puts("Devices: #{Enum.join(devices, ", ")}\n")

    {:ok, errors_agent} = Agent.start_link(fn -> [] end)

    adapters =
      devices
      |> Task.async_stream(
        fn device -> process_switch(device, username, password, log_dir, errors_agent) end,
        max_concurrency: 500,
        timeout: 120_000,
        on_timeout: :kill_task
      )
      |> Enum.flat_map(fn
        {:ok, result} -> result
        {:exit, reason} ->
          add_error(errors_agent, "Task timed out or crashed: #{inspect(reason)}")
          []
      end)

    errors = Agent.get(errors_agent, & &1) |> Enum.reverse()
    Agent.stop(errors_agent)
    write_error_log(errors, file_timestamp)

    display_results(adapters, file_timestamp)
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

  defp read_devices_file(filename) do
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

  defp process_switch(switch, username, password, log_dir, errors_agent) do
    log_file = Path.join(log_dir, "#{sanitize_filename(switch)}.log")

    log(log_file, "=== Starting scan of switch: #{switch} ===")
    IO.puts("Connecting to switch: #{switch}...")

    case connect_ssh(switch, username, password) do
      {:ok, conn} ->
        log(log_file, "Successfully connected to #{switch}")

        case :ssh_connection.session_channel(conn, :infinity) do
          {:ok, channel} ->
            log(log_file, "SSH channel opened")

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

            log(log_file, "Interactive shell started")

            case execute_command(conn, channel, "terminal length 0") do
              {:ok, _} -> log(log_file, "Terminal pagination disabled")
              {:error, reason} ->
                log_error(log_file, errors_agent,
                  "[#{switch}] Failed to disable pagination: #{inspect(reason)}")
            end

            adapters = discover_adapters(conn, channel, switch, log_file, errors_agent)
            :ssh_connection.close(conn, channel)
            log(log_file, "SSH channel closed")
            disconnect_ssh(conn)
            log(log_file, "Found #{length(adapters)} QSFP-SFP adapter(s) on #{switch}")
            log(log_file, "=== Scan complete ===")
            IO.puts("  Found #{length(adapters)} QSFP-SFP adapter(s) on #{switch}")
            adapters

          {:error, reason} ->
            log_error(log_file, errors_agent,
              "[#{switch}] Failed to open SSH channel: #{inspect(reason)}")
            disconnect_ssh(conn)
            []
        end

      {:error, reason} ->
        log_error(log_file, errors_agent,
          "[#{switch}] Failed to connect: #{inspect(reason)}")
        IO.puts("  Error connecting to #{switch}: #{inspect(reason)}")
        []
    end
  end

  defp discover_adapters(conn, channel, switch_ip, log_file, errors_agent) do
    switch_hostname = get_switch_hostname(conn, channel, switch_ip, log_file, errors_agent)
    log(log_file, "Switch hostname: #{switch_hostname}")

    inventory_entries = get_inventory(conn, channel, switch_ip, log_file, errors_agent)
    log(log_file, "Total inventory entries: #{length(inventory_entries)}")

    qsa_entries = Enum.filter(inventory_entries, &qsfp_sfp_adapter?/1)
    log(log_file, "QSFP-SFP adapter entries: #{length(qsa_entries)}")

    Enum.each(qsa_entries, fn e ->
      log(log_file, "  Adapter: name=#{e.name} pid=#{e.pid} descr=#{e.descr}")
    end)

    Enum.map(qsa_entries, fn entry ->
      port = port_from_inventory_name(entry.name)

      {status, description} =
        if port do
          get_interface_status(conn, channel, port, switch_ip, log_file, errors_agent)
        else
          log_error(log_file, errors_agent,
            "[#{switch_ip}] Could not extract port from inventory NAME #{inspect(entry.name)}")
          {"unknown", "N/A"}
        end

      %Adapter{
        switch_hostname: switch_hostname,
        switch_ip: switch_ip,
        port: port || entry.name,
        adapter_pid: entry.pid,
        adapter_descr: entry.descr,
        connection_status: status,
        interface_description: description
      }
    end)
  end

  # ---------------------------------------------------------------------------
  # Data collection helpers
  # ---------------------------------------------------------------------------

  defp get_switch_hostname(conn, channel, switch_ip, log_file, errors_agent) do
    log(log_file, "Executing: show run | include hostname")

    case execute_command(conn, channel, "show run | include hostname") do
      {:ok, output} ->
        log(log_file, "--- BEGIN show run | include hostname ---")
        log(log_file, output)
        log(log_file, "--- END show run | include hostname ---")
        parse_switch_hostname(output) || switch_ip

      {:error, reason} ->
        log_error(log_file, errors_agent,
          "[#{switch_ip}] Failed to get hostname: #{inspect(reason)}, using IP")
        switch_ip
    end
  end

  defp get_inventory(conn, channel, switch_ip, log_file, errors_agent) do
    log(log_file, "Executing: show inventory")

    case execute_command(conn, channel, "show inventory") do
      {:ok, output} ->
        log(log_file, "--- BEGIN show inventory ---")
        log(log_file, output)
        log(log_file, "--- END show inventory ---")
        parse_inventory(output)

      {:error, reason} ->
        log_error(log_file, errors_agent,
          "[#{switch_ip}] Failed to get inventory: #{inspect(reason)}")
        []
    end
  end

  defp get_interface_status(conn, channel, port, switch_ip, log_file, errors_agent) do
    log(log_file, "Executing: show interface #{port}")

    case execute_command(conn, channel, "show interface #{port}") do
      {:ok, output} ->
        log(log_file, "--- BEGIN show interface #{port} ---")
        log(log_file, output)
        log(log_file, "--- END show interface #{port} ---")

        status = parse_interface_status(output)
        description = parse_interface_description(output)
        log(log_file, "Interface #{port}: status=#{status}, description=#{description}")
        {status, description}

      {:error, reason} ->
        log_error(log_file, errors_agent,
          "[#{switch_ip}] Failed to get interface #{port}: #{inspect(reason)}")
        {"unknown", "N/A"}
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

  # Parse "show inventory" output. Each entry is a 2-line stanza:
  #   NAME: "FourHundredGigE1/0/20-qsa", DESCR: "10GE LR"
  #   PID: CVR-QSFP-SFP10G     , VID: V02  , SN: STX1111117F
  defp parse_inventory(output) do
    lines =
      output
      |> String.split("\n")
      |> Enum.map(&String.trim/1)

    parse_inventory_lines(lines, [])
  end

  defp parse_inventory_lines([], acc), do: Enum.reverse(acc)

  defp parse_inventory_lines([line | rest], acc) do
    case Regex.run(~r/^NAME:\s*"([^"]*)"\s*,\s*DESCR:\s*"([^"]*)"/, line) do
      [_, name, descr] ->
        case find_pid_line(rest) do
          {:ok, pid_line, remaining} ->
            entry = %{
              name: String.trim(name),
              descr: String.trim(descr),
              pid: extract_field(pid_line, "PID:"),
              vid: extract_field(pid_line, "VID:"),
              sn: extract_field(pid_line, "SN:")
            }
            parse_inventory_lines(remaining, [entry | acc])

          :not_found ->
            parse_inventory_lines(rest, acc)
        end

      _ ->
        parse_inventory_lines(rest, acc)
    end
  end

  # Skip blank lines until we find the PID line that follows a NAME line.
  defp find_pid_line([]), do: :not_found
  defp find_pid_line([line | rest]) do
    cond do
      line == "" -> find_pid_line(rest)
      String.starts_with?(line, "PID:") -> {:ok, line, rest}
      # Defensive: another NAME line means the previous entry had no PID
      String.starts_with?(line, "NAME:") -> :not_found
      true -> find_pid_line(rest)
    end
  end

  # Extract a comma-delimited field like "PID: CVR-QSFP-SFP10G" from a line that
  # contains multiple "KEY: value" pairs separated by commas.
  defp extract_field(line, field) do
    line
    |> String.split(",")
    |> Enum.find_value("", fn part ->
      trimmed = String.trim(part)
      if String.starts_with?(trimmed, field) do
        trimmed |> String.split(field, parts: 2) |> List.last() |> String.trim()
      end
    end)
  end

  # A QSFP-SFP adapter is identified by a PID matching CVR-QSFP-SFP* (Cisco's
  # CVR = "Converter" naming) or a NAME ending with the "-qsa" suffix that IOS
  # appends to the parent QSFP port when an adapter is plugged in.
  defp qsfp_sfp_adapter?(entry) do
    pid = String.upcase(entry.pid || "")
    name = String.downcase(entry.name || "")

    String.starts_with?(pid, "CVR-QSFP-SFP") or String.ends_with?(name, "-qsa")
  end

  # Pull the parent port out of an inventory NAME like
  # "FourHundredGigE1/0/20-qsa" -> "FourHundredGigE1/0/20"
  defp port_from_inventory_name(name) do
    case Regex.run(
           ~r/^([A-Za-z]+\d+(?:\/\d+){1,3})/,
           String.trim(name)
         ) do
      [_, port] -> port
      _ -> nil
    end
  end

  # Parse the first line of "show interface" to determine connection status.
  # Examples:
  #   "FourHundredGigE1/0/20 is up, line protocol is up (connected)"
  #   "FourHundredGigE1/0/20 is down, line protocol is down (notconnect)"
  #   "FourHundredGigE1/0/20 is administratively down, line protocol is down"
  defp parse_interface_status(output) do
    line =
      output
      |> String.split("\n")
      |> Enum.find("", fn l ->
        Regex.match?(~r/\bis\b.*line protocol is/i, l)
      end)

    cond do
      line == "" -> "unknown"
      Regex.match?(~r/administratively down/i, line) -> "admin down"
      Regex.match?(~r/is up,\s*line protocol is up/i, line) -> "connected"
      Regex.match?(~r/is down,\s*line protocol is down/i, line) -> "notconnect"
      Regex.match?(~r/is up,\s*line protocol is down/i, line) -> "down"
      Regex.match?(~r/is down,\s*line protocol is up/i, line) -> "monitoring"
      true -> String.trim(line)
    end
  end

  defp parse_interface_description(output) do
    output
    |> String.split("\n")
    |> Enum.find_value("N/A", fn line ->
      case Regex.run(~r/^\s*Description:\s+(.+)/i, line) do
        [_, desc] -> String.trim(desc)
        _ -> nil
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
  # Logging
  # ---------------------------------------------------------------------------

  defp log(log_file, message) do
    timestamp = DateTime.utc_now() |> DateTime.to_string()
    File.write!(log_file, "[#{timestamp}] #{message}\n", [:append])
  end

  defp log_error(log_file, errors_agent, message) do
    log(log_file, "ERROR: #{message}")
    add_error(errors_agent, message)
  end

  defp add_error(errors_agent, message) do
    timestamp = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    Agent.update(errors_agent, fn errors -> ["[#{timestamp}] #{message}" | errors] end)
  end

  defp write_error_log([], _file_timestamp), do: :ok
  defp write_error_log(errors, file_timestamp) do
    File.mkdir_p!("output")
    filename = Path.join("output", "#{file_timestamp}-errors.log")
    content = Enum.join(errors, "\n") <> "\n"

    case File.write(filename, content) do
      :ok -> IO.puts("Errors written to: #{filename}")
      {:error, reason} -> IO.puts("Error writing to #{filename}: #{reason}")
    end
  end

  defp sanitize_filename(name) do
    String.replace(name, ~r/[^a-zA-Z0-9\-_\.]/, "_")
  end

  # ---------------------------------------------------------------------------
  # Results and CSV output
  # ---------------------------------------------------------------------------

  defp display_results(adapters, file_timestamp) do
    File.mkdir_p!("output")
    csv_file = Path.join("output", "#{file_timestamp}-qsfp_sfp_adapters.csv")

    IO.puts("\n" <> String.duplicate("=", 80))
    IO.puts("RESULTS: Found #{length(adapters)} QSFP-SFP adapter(s) total")
    IO.puts(String.duplicate("=", 80) <> "\n")

    if Enum.empty?(adapters) do
      IO.puts("No QSFP-SFP adapters found.")
    else
      write_adapters_csv(csv_file, adapters)
      IO.puts("Adapters written to: #{csv_file}\n")

      IO.puts("Adapters by switch:")
      adapters
      |> Enum.group_by(& &1.switch_ip)
      |> Enum.each(fn {switch, list} ->
        IO.puts("  #{switch}: #{length(list)} adapter(s)")
      end)
    end
  end

  defp write_adapters_csv(filename, adapters) do
    csv_lines = [
      "Switch Hostname,Switch IP,Port,Adapter PID,Adapter Description,Connection Status,Interface Description"
      |
      Enum.map(adapters, fn a ->
        [
          a.switch_hostname,
          a.switch_ip,
          a.port,
          a.adapter_pid,
          a.adapter_descr,
          a.connection_status,
          a.interface_description
        ]
        |> Enum.map(&escape_csv_field/1)
        |> Enum.join(",")
      end)
    ]

    write_csv(filename, csv_lines)
  end

  defp write_csv(filename, csv_lines) do
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
QsfpSfpAdapterFinder.run()
