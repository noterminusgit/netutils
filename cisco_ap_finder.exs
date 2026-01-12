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

    # Create logging directory with timestamp
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601() |> String.replace(~r/[:\.]/, "-")
    log_dir = Path.join(["logs", timestamp])
    File.mkdir_p!(log_dir)
    IO.puts("Logging to: #{log_dir}\n")

    # Get credentials
    username = get_input("Enter username: ")
    password = get_password("Enter password: ")

    # Read switches list
    switches = read_switches_file("switches.txt")

    if Enum.empty?(switches) do
      IO.puts("Error: No switches found in switches.txt")
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
    display_results(all_aps)
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
        aps = get_cisco_aps(conn, switch, log_file)
        disconnect_ssh(conn)
        log(log_file, "Found #{length(aps)} Cisco AP(s) on #{switch}")
        log(log_file, "=== Scan complete ===")
        IO.puts("  Found #{length(aps)} Cisco AP(s) on #{switch}")
        aps

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

  defp connect_ssh(host, username, password) do
    # Convert host to charlist
    host_charlist = to_charlist(host)
    username_charlist = to_charlist(username)
    password_charlist = to_charlist(password)

    # SSH connection options
    opts = [
      {:user, username_charlist},
      {:password, password_charlist},
      {:silently_accept_hosts, true},
      {:user_interaction, false},
      {:connect_timeout, 10000}
    ]

    case :ssh.connect(host_charlist, 22, opts) do
      {:ok, conn} ->
        {:ok, conn}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp disconnect_ssh(conn) do
    :ssh.close(conn)
  end

  defp get_cisco_aps(conn, switch, log_file) do
    log(log_file, "Executing: show power inline")

    # Execute "show power inline" command
    case execute_command(conn, "show power inline") do
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
          get_ap_details(conn, interface, model, switch, log_file)
        end)
        |> Enum.reject(&is_nil/1)

      {:error, reason} ->
        log(log_file, "ERROR: Failed to execute 'show power inline': #{inspect(reason)}")
        []
    end
  end

  defp get_ap_details(conn, interface, model, switch, log_file) do
    log(log_file, "Processing interface #{interface} (model: #{model})")
    log(log_file, "Executing: show mac address-table interface #{interface}")

    # Get MAC address and VLAN from MAC address table
    case execute_command(conn, "show mac address-table interface #{interface}") do
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
              hostname = get_hostname_from_cdp(conn, interface, log_file)
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

  defp get_hostname_from_cdp(conn, interface, log_file) do
    # Try to get hostname from CDP neighbor detail
    case execute_command(conn, "show cdp neighbors #{interface} detail") do
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

  defp execute_command(conn, command) do
    case :ssh_connection.session_channel(conn, :infinity) do
      {:ok, channel} ->
        # Send the command
        :ssh_connection.exec(conn, channel, to_charlist(command), :infinity)

        # Collect output
        output = collect_output(conn, channel, "")
        :ssh_connection.close(conn, channel)

        {:ok, output}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp collect_output(conn, channel, acc) do
    receive do
      {:ssh_cm, ^conn, {:data, ^channel, 0, data}} ->
        collect_output(conn, channel, acc <> to_string(data))

      {:ssh_cm, ^conn, {:eof, ^channel}} ->
        acc

      {:ssh_cm, ^conn, {:exit_status, ^channel, _status}} ->
        collect_output(conn, channel, acc)

      {:ssh_cm, ^conn, {:closed, ^channel}} ->
        acc
    after
      5000 ->
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
      "000142", "000143", "000163", "000164", "000196", "000197", "0001C7", "0001C9",
      "000216", "000217", "00023D", "00024A", "00024B", "00027D", "00027E", "0002B9",
      "0002BA", "0002FC", "0002FD", "000331", "000332", "00036B", "00036C", "00039F",
      "0003A0", "0003E3", "0003E4", "0003FD", "0003FE", "000427", "000428", "00044D",
      "00044E", "00046D", "00046E", "00049A", "00049B", "0004C0", "0004C1", "0004DD",
      "0004DE", "000500", "000501", "000531", "000532", "00055E", "00055F", "000573",
      "000574", "00059A", "00059B", "0005DC", "0005DD", "000628", "000629", "000652",
      "000653", "00067C", "00067D", "0006C1", "0006D6", "0006D7", "0006F6", "00070D",
      "00070E", "00074F", "000750", "00077D", "000784", "000785", "0007B3", "0007B4",
      "0007EB", "0007EC", "000820", "000821", "00082F", "000830", "000831", "000832",
      "00087C", "00087D", "0008A3", "0008A4", "0008C2", "0008E2", "0008E3", "000911",
      "000912", "000943", "000944", "00097B", "00097C", "0009B6", "0009B7", "0009E8",
      "0009E9", "000A41", "000A42", "000A8A", "000A8B", "000AB7", "000AB8", "000AF3",
      "000AF4", "000B45", "000B46", "000B5F", "000B60", "000B85", "000BBE", "000BBF",
      "000BFC", "000BFD", "000C30", "000C31", "000C41", "000C85", "000C86", "000CCE",
      "000CCF", "000D28", "000D29", "000D65", "000D66", "000DBC", "000DBD", "000DEC",
      "000DED", "000E38", "000E39", "000E83", "000E84", "000ED6", "000ED7", "000F23",
      "000F24", "000F34", "000F35", "000F66", "000F8F", "000F90", "000FF7", "000FF8",
      "001007", "001011", "001014", "001029", "00102F", "001054", "001079", "00107B",
      "0010A6", "0010F6", "001120", "001121", "00115C", "00115D", "001192", "001193",
      "0011BB", "0011BC", "001200", "001201", "001217", "001243", "001244", "00127F",
      "001280", "0012D9", "0012DA", "001319", "00131A", "00135F", "001360", "00137F",
      "001380", "0013C3", "0013C4", "00141B", "00141C", "001469", "00146A", "0014A8",
      "0014A9", "0014BF", "0014F1", "0014F2", "00152B", "00152C", "001562", "001563",
      "0015C6", "0015C7", "0015F9", "0015FA", "001646", "001647", "00169C", "00169D",
      "0016C7", "0016C8", "00170E", "00170F", "001733", "001759", "00175A", "001794",
      "001795", "0017DF", "0017E0", "001818", "001819", "001839", "001868", "001873",
      "001874", "0018B9", "0018BA", "001906", "001907", "00192F", "001930", "001955",
      "001956", "0019A9", "0019AA", "0019E7", "0019E8", "001A2F", "001A30", "001A6C",
      "001A6D", "001AA1", "001AA2", "001AE2", "001AE3", "001B0C", "001B0D", "001B2A",
      "001B2B", "001B53", "001B54", "001B67", "001B8F", "001B90", "001BD4", "001BD5",
      "001BD7", "001C0E", "001C0F", "001C57", "001C58", "001CB0", "001CB1", "001D45",
      "001D46", "001D70", "001D71", "001DA1", "001DA2", "001DE5", "001DE6", "001E13",
      "001E14", "001E49", "001E4A", "001E79", "001E7A", "001EBD", "001EBE", "001EF6",
      "001EF7", "001F26", "001F27", "001F6C", "001F6D", "001F9D", "001F9E", "001FC9",
      "001FCA", "002035", "00211B", "00211C", "002129", "002155", "002156", "0021A0",
      "0021A1", "0021BE", "0021D7", "0021D8", "00220C", "00220D", "00223A", "002255",
      "002256", "00226B", "002290", "002291", "0022BD", "0022BE", "0022CE", "002304",
      "002305", "002333", "002334", "00235D", "00235E", "0023AB", "0023AC", "0023BE",
      "0023EA", "0023EB", "002413", "002414", "002450", "002451", "002497", "002498",
      "0024C3", "0024C4", "0024F7", "0024F9", "00252E", "002545", "002546", "002583",
      "002584", "0025B4", "0025B5", "00260A", "00260B", "002651", "002652", "002698",
      "002699", "0026CA", "0026CB", "00270C", "00270D", "002790", "0027BD", "0027BE",
      "0027E3", "0027E4", "002857", "002858", "00290D", "00290E", "00293F", "002940",
      "00294B", "00294C", "002A10", "002A6A", "002A6B", "003019", "003024", "003040",
      "003071", "003078", "003080", "003085", "003094", "003096", "0030A3", "0030B6",
      "0030F2", "003A98", "003A99", "003A9A", "003A9B", "003A9C", "004096", "00425A",
      "004268", "00500B", "00500F", "005014", "00502A", "00503E", "005050", "005053",
      "005054", "005073", "005080", "0050A2", "0050A7", "0050BD", "0050D1", "0050E2",
      "0050F0", "006009", "00602F", "00603E", "006047", "00605C", "006070", "006083",
      "00900C", "009021", "00902B", "00905F", "00906D", "00906F", "009086", "009092",
      "0090A6", "0090AB", "0090B1", "0090BF", "0090D9", "0090F2", "00A0C9", "00B04A",
      "00B064", "00B08E", "00B0C2", "00C017", "00C01D", "00C08A", "00C0B7", "00D001",
      "00D006", "00D058", "00D079", "00D090", "00D097", "00D0BA", "00D0BB", "00D0BC",
      "00D0C0", "00D0D3", "00D0E4", "00D0FF", "00E014", "00E01E", "00E034", "00E04F",
      "00E08F", "00E0A3", "00E0B0", "00E0F7", "00E0F9", "00F28B", "042EAC", "046C9D",
      "04C5A4", "04DAD2", "04FE7F", "081735", "0896AD", "08CC68", "0C1167", "0C2724",
      "0C6803", "0C75BD", "0C8525", "0CD0F8", "0CF5A4", "100000", "1005CA", "108CCF",
      "10BD18", "141F78", "144AA8", "14A698", "14B7F7", "18339D", "18550F", "188090",
      "188B45", "188B9D", "189C5D", "18E728", "18EF63", "1C1D86", "1C6A7A", "1CAA07",
      "1CDEA7", "203706", "203A07", "204C03", "20AA4B", "20BBC0", "2401C7", "24374C",
      "247F3F", "24B657", "286F7F", "2893FE", "28940F", "28C7CE", "2C36F8", "2C3ECF",
      "2C3F38", "2C542D", "2C5A0F", "3037A6", "30E4DB", "3464A9", "34A84E", "34BDC8",
      "34DBFD", "381C1A", "382056", "38C85C", "38ED18", "3C08F6", "3C0E23", "3C5EC3",
      "3CCE73", "405539", "40A6E8", "40F4EC", "4403A7", "445829", "44ADD9", "44D3CA",
      "44E4D9", "4844F7", "487B6B", "48F8B3", "4C0082", "4C4E35", "500604", "500F80",
      "5017FF", "501CBF", "503DE5", "5057A8", "5067AE", "508789", "54781A", "547FEE",
      "54A274", "580A20", "586D8F", "588D09", "58971E", "58AC78", "58BC27", "58BFEA",
      "58F39C", "5C5015", "5C5AC7", "5C838E", "5CA48A", "602AD0", "60735C", "6400F1",
      "641225", "64168D", "649EF3", "64A0E7", "64AE0C", "64D4DA", "64D989", "64D954",
      "687DB4", "68BC0C", "68BDAB", "68EE96", "6C2056", "6C416A", "6C504D", "6C9989",
      "70105C", "701F53", "703A0E", "705681", "708105", "70CA9B", "70D379", "70DB98",
      "70EA1A", "7426AC", "74547D", "74A02F", "74A2E6", "784558", "78725D", "78BAF9",
      "7C0ECE", "7C210D", "7C6166", "7C69F6", "7C95F3", "7CAD74", "7CB21B", "801F02",
      "802AA8", "8478AC", "84802D", "84B261", "84B802", "8843E1", "885A92", "887556",
      "88908D", "88F031", "8C604F", "8CB64F", "90E95E", "94D469", "98FC11", "9C37F4",
      "9C4E36", "A03D6F", "A0554F", "A0E0AF", "A0ECF9", "A0F445", "A40CC3", "A45630",
      "A46C2A", "A4934C", "A80C0D", "AC4A67", "AC7E8A", "ACA016", "B000B4", "B07D47",
      "B0AA77", "B41489", "B4A4E3", "B4E9B0", "B83861", "B8621F", "B8BEBF", "BC1665",
      "BC671C", "BCC493", "C00054", "C0255C", "C0626B", "C067AF", "C07BBC", "C08C60",
      "C40ACB", "C46413", "C47154", "C47D4F", "C80084", "C84C75", "C89C1D", "CC167E",
      "CC46D6", "CC5A53", "CCD539", "CCEF48", "D0574C", "D48CB5", "D4A02A", "D4D748",
      "D824BD", "D867D9", "D8B190", "DC7B94", "DCCEC1", "E02F6D", "E05FB9", "E0899D",
      "E4AA5D", "E4C722", "E8040B", "E84040", "E86549", "E8B748", "E8BA70", "EC1D8B",
      "EC4476", "ECBD1D", "F02572", "F02929", "F07F06", "F09E63", "F40F1B", "F44E05",
      "F47F35", "F4ACC1", "F4CFE2", "F4DBE6", "F80BCB", "F84F57", "F866F2", "F872EA",
      "F8B7E2", "F8C288", "FC5B39", "FC9947", "FCFBFB"
    ]

    oui in cisco_ouis
  end

  defp display_results(aps) do
    output_file = "aps.csv"

    IO.puts("\n" <> String.duplicate("=", 80))
    IO.puts("RESULTS: Found #{length(aps)} Cisco AP(s) total")
    IO.puts(String.duplicate("=", 80) <> "\n")

    if Enum.empty?(aps) do
      IO.puts("No Cisco APs found.")
      IO.puts("No output file created.")
    else
      # Write to CSV file
      write_csv_file(output_file, aps)
      IO.puts("Results written to: #{output_file}")
      IO.puts("\nSummary by switch:")

      # Display summary in terminal
      aps_by_switch = Enum.group_by(aps, & &1.switch)
      Enum.each(aps_by_switch, fn {switch, switch_aps} ->
        IO.puts("  #{switch}: #{length(switch_aps)} AP(s)")
      end)
    end
  end

  defp write_csv_file(filename, aps) do
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

    content = Enum.join(csv_lines, "\n") <> "\n"

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
