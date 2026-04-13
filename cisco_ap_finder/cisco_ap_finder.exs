#!/usr/bin/env elixir

# Cisco AP Finder Script
# Connects to Cisco switches via SSH and identifies Cisco APs from "show power inline" output

defmodule CiscoAPFinder do
  @moduledoc """
  Script to connect to Cisco switches and find Cisco APs with their hostnames and MAC addresses.
  """

  defmodule AP do
    defstruct [:hostname, :mac_address, :interface, :switch, :vlan, :model]
  end

  def run do
    IO.puts("\n=== Cisco AP Finder ===\n")

    # Start SSH application
    :ssh.start()

    # Capture run timestamp (ISO 8601 to seconds) for CSV headers
    run_time = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    # Create logging directory with timestamp
    timestamp = String.replace(run_time, ~r/[:\.]/, "-")
    log_dir = Path.join(["logs", timestamp])
    File.mkdir_p!(log_dir)
    IO.puts("Logging to: #{log_dir}\n")

    # Get credentials
    username = get_input("Enter username: ")
    password = get_password("Enter password: ")

    # Get switches filename
    switches_file = get_input("Enter switches file (one IP per line): ")

    # Read switches list
    switches = read_switches_file(switches_file)

    if Enum.empty?(switches) do
      IO.puts("Error: No switches found in #{switches_file}")
      System.halt(1)
    end

    IO.puts("\nFound #{length(switches)} switch(es) to scan...")
    IO.puts("Switches: #{Enum.join(switches, ", ")}\n")

    # Connect to each switch and find APs in parallel
    all_aps =
      switches
      |> Task.async_stream(
        fn switch -> find_aps_on_switch(switch, username, password, log_dir) end,
        max_concurrency: 10,
        timeout: 120_000,
        on_timeout: :kill_task
      )
      |> Enum.flat_map(fn
        {:ok, aps} -> aps
        {:exit, _reason} -> []
      end)

    # Display results
    display_results(all_aps, run_time)
  end

  defp get_input(prompt) do
    IO.write(prompt)
    IO.read(:stdio, :line) |> String.trim()
  end

  defp get_password(prompt) do
    # Try secure password input first (works on Unix/Linux/macOS)
    try do
      :io.get_password(to_charlist(prompt)) |> to_string() |> String.trim()
    rescue
      # Fall back to regular input on Windows
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

  defp find_aps_on_switch(switch, username, password, log_dir) do
    # Create log file for this switch
    log_file = Path.join(log_dir, "#{sanitize_filename(switch)}.log")

    log(log_file, "=== Starting scan of switch: #{switch} ===")
    IO.puts("Connecting to switch: #{switch}...")

    case connect_ssh(switch, username, password) do
      {:ok, conn} ->
        log(log_file, "Successfully connected to #{switch}")

        # Open a single channel with PTY for all commands
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

            # Disable pagination to prevent --More-- prompts
            log(log_file, "Disabling terminal pagination")
            case execute_command(conn, channel, "terminal length 0") do
              {:ok, _output} ->
                log(log_file, "Terminal pagination disabled")
              {:error, reason} ->
                log(log_file, "WARNING: Failed to disable pagination: #{inspect(reason)}")
            end

            aps = get_cisco_aps(conn, channel, switch, log_file)
            :ssh_connection.close(conn, channel)
            log(log_file, "SSH channel closed")
            disconnect_ssh(conn)
            log(log_file, "Found #{length(aps)} Cisco AP(s) on #{switch}")
            log(log_file, "=== Scan complete ===")
            IO.puts("  Found #{length(aps)} Cisco AP(s) on #{switch}")
            aps

          {:error, reason} ->
            log(log_file, "ERROR: Failed to open SSH channel: #{inspect(reason)}")
            disconnect_ssh(conn)
            []
        end

      {:error, reason} ->
        log(log_file, "ERROR: Failed to connect to #{switch}: #{inspect(reason)}")
        IO.puts("  Error connecting to #{switch}: #{inspect(reason)}")
        []
    end
  end

  defp log(log_file, message) do
    timestamp = DateTime.utc_now() |> DateTime.to_string()
    File.write!(log_file, "[#{timestamp}] #{message}\n", [:append])
  end

  defp sanitize_filename(name) do
    String.replace(name, ~r/[^a-zA-Z0-9\-_\.]/, "_")
  end

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

  defp get_cisco_aps(conn, channel, switch, log_file) do
    log(log_file, "Executing: show power inline")

    # Execute "show power inline" command
    case execute_command(conn, channel, "show power inline") do
      {:ok, power_output} ->
        log(log_file, "Power inline output received (#{String.length(power_output)} bytes)")
        log(log_file, "--- BEGIN show power inline ---")
        log(log_file, power_output)
        log(log_file, "--- END show power inline ---")

        # Get interfaces with powered devices and their models
        interface_models = parse_power_inline_output(power_output)
        log(log_file, "Found #{length(interface_models)} powered local port(s): #{inspect(interface_models)}")

        # For each interface, get MAC address and VLAN, then check if it's a Cisco device
        Enum.map(interface_models, fn {interface, model} ->
          get_ap_details(conn, channel, interface, model, switch, log_file)
        end)
        |> Enum.reject(&is_nil/1)

      {:error, reason} ->
        log(log_file, "ERROR: Failed to execute 'show power inline': #{inspect(reason)}")
        []
    end
  end

  defp get_ap_details(conn, channel, interface, model, switch, log_file) do
    log(log_file, "Processing interface #{interface} (model: #{model})")
    log(log_file, "Executing: show mac address-table interface #{interface}")

    # Get MAC address and VLAN from MAC address table
    case execute_command(conn, channel, "show mac address-table interface #{interface}") do
      {:ok, mac_output} ->
        log(log_file, "--- BEGIN show mac address-table interface #{interface} ---")
        log(log_file, mac_output)
        log(log_file, "--- END show mac address-table interface #{interface} ---")

        case parse_mac_address_table(mac_output) do
          {:ok, vlan, mac_address} ->
            log(log_file, "Parsed MAC table - VLAN: #{vlan}, MAC: #{mac_address}")

            # Check if it's a Cisco device by OUI
            if is_cisco_oui?(mac_address) do
              log(log_file, "MAC #{mac_address} matches Cisco OUI - this is a Cisco device")

              # Get hostname from CDP
              log(log_file, "Executing: show cdp neighbors #{interface} detail")
              hostname = get_hostname_from_cdp(conn, channel, interface, log_file)
              log(log_file, "Hostname from CDP: #{hostname || "Unknown"}")

              log(log_file, "✓ Adding AP: #{hostname || "Unknown"} (#{mac_address}) on #{interface}")

              %AP{
                hostname: hostname || "Unknown",
                mac_address: mac_address,
                interface: interface,
                switch: switch,
                vlan: vlan,
                model: model
              }
            else
              log(log_file, "✗ MAC #{mac_address} does NOT match Cisco OUI - skipping")
              nil
            end

          :error ->
            log(log_file, "✗ Failed to parse MAC address table output")
            nil
        end

      {:error, reason} ->
        log(log_file, "ERROR: Failed to execute 'show mac address-table interface #{interface}': #{inspect(reason)}")
        nil
    end
  end

  defp parse_mac_address_table(output) do
    # Parse output like:
    # Vlan    Mac Address       Type        Ports
    # ----    -----------       --------    -----
    #   50    90e9.5e89.e2a4    STATIC      Gi1/0/10

    lines = String.split(output, "\n")

    # Find the line with MAC address data (skip headers)
    result =
      lines
      |> Enum.find_value(fn line ->
        trimmed = String.trim(line)
        parts = String.split(trimmed, ~r/\s+/)

        # Look for lines with VLAN (number), MAC (format: xxxx.xxxx.xxxx), Type, Port
        cond do
          trimmed == "" -> nil
          String.contains?(trimmed, "Vlan") -> nil
          String.contains?(trimmed, "---") -> nil
          String.contains?(trimmed, "Total") -> nil
          length(parts) >= 4 ->
            vlan_str = Enum.at(parts, 0)
            mac_str = Enum.at(parts, 1)

            # Try to parse VLAN and validate MAC format
            case {Integer.parse(vlan_str), Regex.match?(~r/^[0-9a-fA-F]{4}\.[0-9a-fA-F]{4}\.[0-9a-fA-F]{4}$/, mac_str)} do
              {{vlan, _}, true} -> {:ok, vlan, mac_str}
              _ -> nil
            end

          true -> nil
        end
      end)

    result || :error
  end

  defp get_hostname_from_cdp(conn, channel, interface, log_file) do
    # Try to get hostname from CDP neighbor detail
    case execute_command(conn, channel, "show cdp neighbors #{interface} detail") do
      {:ok, cdp_output} ->
        log(log_file, "--- BEGIN show cdp neighbors #{interface} detail ---")
        log(log_file, cdp_output)
        log(log_file, "--- END show cdp neighbors #{interface} detail ---")

        hostname = extract_cdp_field(String.split(cdp_output, "\n"), "Device ID:")
        if hostname do
          log(log_file, "Extracted hostname from CDP: #{hostname}")
        else
          log(log_file, "No hostname found in CDP output")
        end
        hostname

      {:error, reason} ->
        log(log_file, "ERROR: Failed to execute 'show cdp neighbors #{interface} detail': #{inspect(reason)}")
        nil
    end
  end

  defp execute_command(conn, channel, command) do
    # Send the command (with newline to execute it)
    :ssh_connection.send(conn, channel, to_charlist(command <> "\n"), 0)

    # Collect output (waits for prompt)
    output = collect_output(conn, channel, "")

    # Small delay between commands to let the switch stabilize
    Process.sleep(100)

    {:ok, output}
  end

  defp collect_output(conn, channel, acc) do
    receive do
      {:ssh_cm, ^conn, {:data, ^channel, 0, data}} ->
        new_acc = acc <> to_string(data)

        # Check if we've received the prompt (ends with # or >)
        # This indicates the command has completed
        if String.ends_with?(String.trim(new_acc), "#") or String.ends_with?(String.trim(new_acc), ">") do
          # Wait a tiny bit more to make sure we got everything
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
        # Increased timeout to 10 seconds
        acc
    end
  end

  defp parse_power_inline_output(output) do
    lines = String.split(output, "\n")

    # Find powered devices on local ports (x/0/x) with power > 0
    # Return list of {interface, model} tuples
    lines
    |> Enum.filter(&is_powered_local_port?/1)
    |> Enum.map(&extract_interface_and_model/1)
    |> Enum.reject(&is_nil/1)
  end

  defp is_powered_local_port?(line) do
    # The "show power inline" output typically has columns like:
    # Interface  Admin  Oper  Power   Device              Class Max
    # Tw1/0/1    auto   on    14.0    C9105AXW-B          4     60.0
    # Tw1/0/2    auto   off   0.0     n/a                 n/a   60.0
    #
    # We're looking for:
    # 1. Local ports (x/0/x pattern, NOT x/1/x which are uplinks)
    # 2. Power draw > 0

    trimmed = String.trim(line)

    # Skip header lines and empty lines
    cond do
      trimmed == "" -> false
      String.contains?(trimmed, "Interface") -> false
      String.contains?(trimmed, "---") -> false
      true ->
        # Try to extract interface and power
        parts = String.split(trimmed, ~r/\s+/)

        if length(parts) >= 4 do
          interface = Enum.at(parts, 0)
          power_str = Enum.at(parts, 3)

          # Check if it's a local port (x/0/x) and not an uplink (x/1/x)
          is_local_port = Regex.match?(~r/\d+\/0\/\d+/, interface)

          # Check if power > 0
          case Float.parse(power_str) do
            {power, _} -> is_local_port && power > 0
            :error -> false
          end
        else
          false
        end
    end
  end

  defp extract_interface_and_model(line) do
    # Parse the line to extract interface name and model
    # Format: Tw1/0/1   auto   on    14.0    C9105AXW-B          4     60.0
    # Columns: Interface, Admin, Oper, Power, Device, Class, Max
    parts = String.split(String.trim(line), ~r/\s+/)

    if length(parts) >= 5 do
      interface = Enum.at(parts, 0)
      model = Enum.at(parts, 4)

      # Replace "n/a" with "Unknown"
      model = if model == "n/a", do: "Unknown", else: model

      {interface, model}
    else
      nil
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
    end
  end

  defp is_cisco_oui?(mac_address) do
    # Normalize MAC address to format without separators
    normalized =
      mac_address
      |> String.replace(~r/[:\-\.]/, "")
      |> String.upcase()

    # Get first 6 characters (OUI)
    oui = String.slice(normalized, 0, 6)

    # Check against common Cisco OUIs
    # This is a subset of the most common Cisco OUI prefixes
    cisco_ouis = [
      "E80AB9", "9CE330", "B4DF91", "481BA4", "6C03B5", "B8AB61", "908855", "687161", "4CEC0F", "5C64F1", "08F1B3", "5C3E06", "C828E5", "D009C8", "44643C", "24161B", "E8DC6C", "E8D322", "34B883", "806A00", "ACBCD9", "4006D5", "0845D1", "6887C6", "80248F", "B8A377", "E44E2D", "1CD1E0", "CC9C3E", "045FB9", "B0C53C", "ECCE13", "40B5C1", "DC774C", "94AEF0", "AC4A56", "BC5A56", "24169D", "9CE176", "4CE176", "3C410E", "0027E3", "B40216", "F4BD9E", "084FA9", "084FF9", "308BB2", "6C5E3B", "D46A35", "5486BC", "003085", "C4B36A", "6C8BD3", "00EEAB", "703509", "A8B456", "6899CD", "00B1E3", "00B771", "DCF719", "A0CF5B", "780CF0", "7079B3", "00FCBA", "68CAE4", "28AC9E", "00BE75", "247E12", "501CB0", "B4A8B9", "005D73", "002790", "6CB2AE", "CC5A53", "706BB9", "84802D", "7802B1", "188090", "70DF2F", "881544", "E0ACF1", "001D7E", "00C164", "0014BF", "00E08F", "001868", "887556", "FC9947", "6C2056", "ACF2C5", "005053", "005050", "00906D", "0090AB", "005054", "00500B", "2401C7", "6886A7", "08CC68", "5006AB", "00E0A3", "00902B", "3C0E23", "0C2724", "6C416A", "ECE1A9", "1CE85D", "A89D21", "689CE2", "C067AF", "C0255C", "F44E05", "881DFC", "A0F849", "6CFA89", "001011", "00000C", "046273", "D8B190", "80E86F", "AC7E8A", "185933", "445829", "602AD0", "0023BE", "BCD165", "74547D", "48F8B3", "A4934C", "5057A8", "00DEFB", "442B03", "C40ACB", "D4A02A", "649EF3", "64A0E7", "CCEF48", "64AE0C", "B8621F", "D0C282", "5835D9", "88F077", "40F4EC", "E05FB9", "F02572", "588D09", "C0C1C0", "58BC27", "18EF63", "A8B1D4", "C84C75", "1C17D3", "A40CC3", "ECC882", "003A99", "003A9A", "003A98", "006440", "8843E1", "C47D4F", "3CDF1E", "9CAFCA", "EC3091", "F4ACC1", "00270C", "00260B", "002651", "002583", "0024F9", "0024C3", "0024C4", "002413", "0023AC", "002334", "002155", "001F9D", "001F6C", "001E6B", "001D70", "001B0C", "001AE2", "001A2F", "0019A9", "001906", "001956", "0017E0", "00170E", "001646", "0016C7", "0015C7", "0014F1", "001319", "001280", "00127F", "001243", "0011BB", "000FF8", "000E84", "000DEC", "000AB8", "00097C", "00097B", "0008E3", "000821", "000820", "0006D7", "00055E", "000573", "0004C1", "0003E4", "0003A0", "00027D", "000217", "0001C7", "000164", "00B04A", "000142", "0030A3", "003071", "003096", "00307B", "00D097", "00D063", "0030F2", "00D0BA", "00D0E4", "00D079", "24D5E4", "6C7F0C", "20CC27", "4800B3", "F0D805", "286B5C", "CC6E2A", "A4A584", "905671", "70BD96", "AC69CF", "FC942E", "F43392", "20F120", "ECDD24", "640864", "7824BE", "089707", "0C8DDB", "CC03D9", "A8469D", "6CDEA9", "780F81", "ECBB78", "68D972", "448DD5", "DCD83B", "2C658D", "08711C", "D02C39", "CCD342", "E0D3B4", "18F935", "588B1C", "BCB1D3", "6C29D2", "9C5416", "F4EE31", "242A04", "5CB12E", "78F1C6", "341B2D", "DC0B09", "08F3FB", "345DA8", "3C26E4", "3891B7", "ACD31D", "AC2AA1", "F8E94F", "6026AA", "5C3192", "BC2CE6", "CCED4D", "38FDF8", "2C1A05", "84EBEF", "D0E042", "F04A02", "6C0309", "BCD295", "70617B", "E8EB34", "8C941F", "687DB4", "E41F7B", "A48873", "AC3A67", "AC4A67", "4CA64D", "5CA62D", "CC7F75", "2C5741", "A4B239", "5C710D", "10B3C6", "10B3D6", "2CF89B", "A4530E", "44D3CA", "6CAB05", "00778D", "008764", "7488BB", "002F5C", "08ECF5", "70C9C6", "0CD0F8", "F80F6F", "00B8B3", "00D6FE", "00AA6E", "6C6CD3", "848A8D", "78725D", "0CF5A4", "003C10", "CC8E71", "B4DE31", "F87B20", "74860B", "78BC1A", "0021A1", "00F82C", "00C1B1", "70D379", "70DB98", "2C5A0F", "2C3124", "F80BCB", "00A2EE", "0059DC", "0038DF", "00A6CA", "008731", "C46413", "00FEC8", "009E1E", "006CBC", "008A96", "70E422", "00500F", "0050A2", "00E0B0", "00E0FE", "00E034", "00E0F9", "C8D719", "203A07", "001079", "001029", "000E08", "00603E", "00602F", "006047", "00023D", "00502A", "4403A7", "B0FAEB", "88908D", "F07816", "00223A", "0021BE", "000C41", "1CDEA7", "F07F06", "BC16F5", "FC5B39", "346F90", "F4CFE2", "A80C0D", "7CAD74", "F41FC2", "44ADD9", "0C6803", "C08C60", "E8EDF3", "E4C722", "64E950", "5CFC66", "D46D50", "74A02F", "C07BBC", "24E9B3", "88F031", "0016B6", "0018F8", "00252E", "54D46F", "A4A24A", "44E08E", "BCC810", "7CB21B", "24767D", "481D70", "00E04F", "0010FF", "001054", "0010F6", "0010A6", "F0B2E5", "5897BD", "5C838F", "ECBD1D", "385F66", "D48CB5", "8C604F", "5C5015", "D824BD", "08D09F", "D4D748", "000830", "2C3F38", "70CA9B", "68BC0C", "E8B748", "E80462", "9C4E20", "5475D0", "547FEE", "04FE7F", "EC4476", "002698", "002584", "0025B4", "0023EB", "002369", "00226B", "002255", "001FC9", "001F6D", "001E7A", "001DE5", "001E14", "001DA1", "001D71", "001D45", "001CF6", "001C0F", "001BD5", "001B90", "001B0D", "001AE3", "001AA2", "00169C", "001647", "0015F9", "0014A9", "00141B", "0013C3", "0012DA", "00115C", "00115D", "001121", "000FF7", "000F90", "000E38", "000D29", "000D65", "000CCE", "000CCF", "000BFC", "000B45", "000AF3", "0008A4", "0007EB", "0007EC", "0006D6", "000652", "00059A", "000501", "0004DD", "0004C0", "00046E", "0003E3", "0002FC", "003078", "00B08E", "0030B6", "00D0FF", "A410B6", "C84709", "70DA48", "488002", "8C44A5", "9C098B", "6CEFBD", "C44606", "487410", "C4AB4D", "10E376", "C418FC", "B8B4C9", "5000E0", "74E2E7", "347069", "A0C7D2", "5C0610", "00596C", "4027A8", "680489", "34588A", "E08C3C", "2C3F0B", "303B49", "840C6D", "ECA78D", "FC7288", "D0DC2C", "C414A2", "087B87", "C47EE0", "401482", "246C84", "90EB50", "845A3E", "4891D5", "200BC5", "90E95E", "C08B2A", "5451DE", "684992", "64D814", "001794", "404244", "30F70D", "24813B", "04BD97", "D46624", "BCDB09", "E069BA", "2436DA", "E85C0A", "A49BCD", "28AFFD", "7CF880", "44B6BE", "70F096", "C884A1", "CCDB93", "7018A7", "802DBF", "F86BD9", "C014FE", "7CAD4F", "AC7A56", "00062A", "24B657", "3C5731", "5CE176", "4CE175", "C4B239", "3C510E", "6C410E", "6C310E", "6C710D", "10B3D5", "000C86", "FC589A", "C064E4", "14A2A0", "DC8C37", "00FD22", "D4E880", "2C01B5", "50F722", "D4C93C", "00169D", "700B4F", "F4DBE6", "04EB40", "00A5BF", "00B670", "00BC60", "5061BF", "700F6A", "6CDD30", "F8B7E2", "70708B", "3890A5", "CC9891", "40CE24", "40017A", "C444A0", "A0239F", "70F35A", "00180A", "009AD2", "2CABEB", "2C3311", "1005CA", "08CCA7", "0896AD", "285261", "286F7F", "2CD02D", "2834A2", "006BF1", "001B2A", "00562B", "94D469", "003A7D", "641225", "00C88B", "0C75BD", "00F28B", "000A8A", "0090F2", "60735C", "34A84E", "54781A", "E02F6D", "00605C", "0006C1", "00E014", "0050F0", "005014", "0050BD", "00906F", "58971E", "B4E9B0", "000832", "70105C", "10F311", "B83861", "580A20", "2C3ECF", "508789", "381C1A", "BC671C", "346288", "CCD8C1", "7C0ECE", "A0ECF9", "5CA48A", "1C1D86", "5017FF", "189C5D", "DCA5F4", "547C69", "9C57AD", "004096", "74A2E6", "BCF1F2", "C80084", "40A6E8", "E86549", "B07D47", "38ED18", "382056", "DCCEC1", "001947", "001839", "088039", "C8B373", "18550F", "58BFEA", "2C542D", "A41875", "F4EA67", "002A6A", "000831", "00082F", "708105", "E84040", "C89C1D", "108CCF", "081735", "B4A4E3", "D0574C", "ACA016", "081FF3", "3037A6", "68EFBD", "003A9B", "00270D", "00260A", "00259C", "002546", "002545", "002497", "00235D", "002304", "0022BE", "002290", "00220C", "002129", "001F27", "001F26", "001E49", "001DE6", "001CB1", "001C10", "0019E8", "0019AA", "001930", "0018BA", "0016C8", "00152B", "00152C", "001469", "00135F", "00131A", "000F34", "000ED7", "000D66", "000DBD", "000C85", "000C30", "000B5F", "000B60", "000AB7", "000A8B", "0009B6", "000944", "0008C2", "0008A3", "0007B4", "0007B3", "000750", "000785", "00070D", "00070E", "00055F", "000574", "000532", "000196", "003094", "003040", "00D0D3", "003080", "0050A7", "A4004E", "EC192E", "505C88", "6CC3B2", "F47470", "20DBEA", "884F59", "7864A0", "E8BCE4", "08F4F0", "1096C6", "58DF59", "44C20C", "F814DD", "4CD0F9", "3456FE", "B80756", "ACBDF7", "2CF814", "B8FE90", "34C3FD", "086A0B", "C86340", "247121", "BCABF5", "B8C924", "908A80", "BC8D1F", "68E59E", "348818", "C4D666", "C02C17", "148473", "4C421E", "A411BB", "504921", "8C8442", "149F43", "80276C", "6C4EF6", "1CFC17", "98A2C0", "3CFEAC", "04A741", "8C1E80", "6C8D77", "7411B2", "A84FB1", "1859F5", "EC01D5", "ECF40C", "1006ED", "D4EB68", "C44D84", "20CFAE", "74AD98", "4C5D3C", "34732D", "E455A8", "6C13D5", "A03D6E", "B08BD0", "7C210D", "F87A41", "84F147", "549FC6", "F01D2D", "0476B0", "40F078", "5488DE", "643AEA", "10F920", "9077EE", "3C13CC", "CC7F76", "14169D", "34ED1B", "000163", "58F39C", "CC9070", "ACF5E6", "D0EC35", "70EA1A", "003217", "706D15", "00EABD", "B08BCF", "A09351", "FCFBFB", "007E95", "682C7B", "007278", "4C776D", "701F53", "500F80", "706E6D", "00A3D1", "7426AC", "001192", "2C86D2", "00425A", "00B0E1", "D42C44", "843DC6", "0081C4", "00B064", "005F86", "00F663", "0062EC", "CC167E", "00CAE5", "004268", "007888", "008E73", "00351A", "00AF1F", "00175A", "00DA55", "CC46D6", "0041D2", "58AC78", "006083", "006009", "00067C", "00E0F7", "005073", "00900C", "00905F", "00100B", "00173B", "00107B", "0050E2", "E4D3F1", "8478AC", "04DAD2", "F02929", "20BBC0", "4C4E35", "0090A6", "009086", "005080", "001BD7", "C4143C", "3C08F6", "78BAF9", "0022CE", "000F66", "501CBF", "B000B4", "544A00", "00E16D", "BC1665", "F872EA", "D0C789", "F84F57", "7C69F6", "78DA6E", "E0D173", "E0899D", "C47295", "24374C", "F45FD4", "2CABA4", "34BDC8", "DCEB94", "84B517", "188B9D", "E4AA5D", "F44B2A", "4C83DE", "68EE96", "503955", "0CD996", "10BD18", "D867D9", "A44C11", "2C36F8", "C8F9F9", "A45630", "28940F", "0C8525", "20AA4B", "64D989", "203706", "E8BA70", "B8BEBF", "1CAA07", "44E4D9", "C0626B", "04C5A4", "503DE5", "8CB64F", "B41489", "6C504D", "1CDF0F", "68BDAB", "DC7B94", "D0D0FD", "98FC11", "2893FE", "687F74", "002699", "0026CB", "0025B5", "0024F7", "002450", "002451", "002414", "0023EA", "00235E", "002333", "0022BD", "002305", "00220D", "0021A0", "00211B", "001FCA", "001EF6", "001EBE", "001EBD", "001E4A", "001E79", "001DA2", "001E13", "001D46", "001CF9", "001C58", "001C0E", "001BD4", "001B54", "001A6D", "001A6C", "001A30", "0018B9", "00192F", "001907", "001874", "001819", "001795", "001759", "00170F", "0015FA", "0015C6", "001562", "0014F2", "0014A8", "00141C", "0013C4", "00137F", "0011BC", "000DED", "000DBC", "000BFD", "000BBE", "000B85", "0009E8", "0009E9", "000943", "00087D", "00087C", "00074F", "000628", "0005DD", "00059B", "0005DC", "000500", "00049A", "00044D", "00046D", "000428", "000332", "00039F", "00027E", "000216", "00024A", "000197", "00D090", "00D058", "00503E", "0CD5D3", "8C8881", "E4379F", "CC6A33", "D47F35", "9C6697", "940D4B", "04E387", "48A170", "2CE38E", "4C01F7", "D08543", "F003BC", "080FE5", "887ABC", "7CB353", "E879A3", "E02A66", "683A1E", "F89E28", "388479", "E0CBBC", "30FEFA", "6C4FA1", "E489CA", "14BC68", "78119D", "C834E5", "806132", "60A954", "441A5C", "7C8767", "141923", "F8C650", "60B9C0", "8C9461", "687909", "E4A41C", "58569F", "BC3340", "648F3E", "CCB6C8", "6CD6E3", "ECC018", "748FC2", "E462C4", "001B8F", "24D79C", "00841E", "0CAF31", "10A829", "CC79D7", "E4387E", "889CAD", "DC0539", "448816", "70A983", "BCFAEB", "0C7BC8", "88FC5D", "F8E57E", "482E72", "3C8B7F", "C0F87F", "C48BA3", "A00F37", "00DF1D", "9CD57D", "A47806", "D47798", "548ABA", "44AE25", "BCE712", "F8A73A", "B8114B", "488B0A", "B0A651", "689E0B", "00146A", "BC4A56", "A4B439", "A0B439", "7C310E", "7C210E", "4C710D", "4C710C", "683B78", "D4ADBD", "5C5AC7", "C4C603", "2C4F52", "C4F7D5", "4CBC48", "D4789B", "2C73A0", "0029C2", "D4AD71", "CC70ED", "34F8E7", "70B317", "B0907E", "BC26C7", "DC3979", "502FA8", "00451D", "7001B5", "70695A", "00BF77", "B02680", "EC1D8B", "380E4D", "707DB9", "002291", "00A38E", "002CC8", "C4B9CD", "F8A5C5", "848DC7", "2C0BE9", "A03D6F", "A0E0AF", "007686", "00D78F", "002A10", "00A289", "00A742", "18339D", "00EBD5", "E00EDA", "042AE2", "00CCFC", "0C1167", "0057D2", "188B45", "009021", "0090B1", "00102F", "00100D", "001007", "001014", "00400B", "0090BF", "0050D1", "0090D9", "009092", "006070", "00E01E", "1CE6C7", "18E728", "D072DC", "28C7CE", "F40F1B", "F8C288", "6C9989", "1C6A7A", "5067AE", "F09E63", "CCD539", "500604", "4C0082", "7C95F3", "34DBFD", "885A92", "046C9D", "84B261", "00101F", "54A274", "A0554F", "204C9E", "84B802", "B0AA77", "BCC493", "A46C2A", "D0A5A6", "3C5EC3", "64F69D", "484487", "38C85C", "E448C7", "001217", "001310", "001EE5", "80E01D", "E0553D", "C0C687", "CC0DEC", "10EA59", "34BDFA", "C8FB26", "105F49", "F47F35", "3CCE73", "F0F755", "6C9CED", "30E4DB", "00077D", "6400F1", "405539", "586D8F", "C471FE", "0006F6", "F866F2", "003A9C", "64168D", "0026CA", "002652", "002498", "0023AB", "002256", "002156", "0021D8", "0021D7", "00211C", "001F9E", "001EF7", "001CB0", "001C57", "001B53", "001B2B", "001A70", "001AA1", "0019E7", "001955", "001818", "001873", "0017DF", "001563", "001380", "001360", "0012D9", "001201", "001200", "001244", "001193", "001120", "000F8F", "000F23", "000F24", "000F35", "000E83", "000ED6", "000E39", "000D28", "000C31", "000BBF", "000B46", "000AF4", "000A41", "000A42", "0009B7", "000911", "000912", "0008E2", "000784", "000653", "0004DE", "000531", "00049B", "00044E", "0003FD", "0003FE", "000427", "0002FD", "000331", "00036B", "00036C", "0002B9", "0002BA", "00024B", "0001C9", "00B0C2", "000143", "003019", "003024", "00D0BC", "00D006", "00D0BB", "00D0C0", "CC36CF", "9433D8", "70BC48", "A0BC6F", "B08D57", "98D7E1", "F83918", "9C3818", "B44C90", "28B591", "C8608F", "84FFC2", "788517", "C88234", "A0334F", "A0A47F", "105725", "9CA9B8", "40F49F", "3001AF", "B4CADD", "38AA09", "6C7DB7", "F868FF", "ACC3E5", "8CB50E", "AC17C8", "981888", "4CC8A1", "A49700", "D853AD", "E0D491", "A4DCD5", "C878F7", "A05911", "14E22A"
    ]

    oui in cisco_ouis
  end

  defp display_results(aps, run_time) do
    output_file = "aps.csv"

    IO.puts("\n" <> String.duplicate("=", 80))
    IO.puts("RESULTS: Found #{length(aps)} Cisco AP(s) total")
    IO.puts(String.duplicate("=", 80) <> "\n")

    if Enum.empty?(aps) do
      IO.puts("No Cisco APs found.")
      IO.puts("No output file created.")
    else
      # Write to CSV file
      write_csv_file(output_file, aps, run_time)
      IO.puts("Results written to: #{output_file}")
      IO.puts("\nSummary by switch:")

      # Display summary in terminal
      aps_by_switch = Enum.group_by(aps, & &1.switch)
      Enum.each(aps_by_switch, fn {switch, switch_aps} ->
        IO.puts("  #{switch}: #{length(switch_aps)} AP(s)")
      end)
    end
  end

  defp write_csv_file(filename, aps, run_time) do
    # Create CSV content
    csv_lines = [
      # Header
      "Switch,Interface,VLAN,Model,Hostname,MAC Address"
      |
      # Data rows
      Enum.map(aps, fn ap ->
        [ap.switch, ap.interface, to_string(ap.vlan), ap.model, ap.hostname, ap.mac_address]
        |> Enum.map(&escape_csv_field/1)
        |> Enum.join(",")
      end)
    ]

    content = "# Run: #{run_time}\n" <> Enum.join(csv_lines, "\n") <> "\n"

    case File.write(filename, content) do
      :ok ->
        :ok
      {:error, reason} ->
        IO.puts("Error writing to #{filename}: #{reason}")
    end
  end

  defp escape_csv_field(field) do
    # Escape fields that contain commas, quotes, or newlines
    if String.contains?(field, [",", "\"", "\n"]) do
      "\"#{String.replace(field, "\"", "\"\"")}\""
    else
      field
    end
  end
end

# Run the script
CiscoAPFinder.run()
