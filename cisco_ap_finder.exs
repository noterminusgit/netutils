#!/usr/bin/env elixir

# Cisco AP Finder Script
# Connects to Cisco switches via SSH and identifies Cisco APs from "show power inline" output

defmodule CiscoAPFinder do
  @moduledoc """
  Script to connect to Cisco switches and find Cisco APs with their hostnames and MAC addresses.
  """

  defmodule AP do
    defstruct [:hostname, :mac_address, :interface, :switch]
  end

  def run do
    IO.puts("\n=== Cisco AP Finder ===\n")

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

    # Connect to each switch and find APs
    all_aps = Enum.flat_map(switches, fn switch ->
      find_aps_on_switch(switch, username, password)
    end)

    # Display results
    display_results(all_aps)
  end

  defp get_input(prompt) do
    IO.write(prompt)
    IO.read(:stdio, :line) |> String.trim()
  end

  defp get_password(prompt) do
    IO.write(prompt)
    password = IO.read(:stdio, :line) |> String.trim()
    password
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

  defp find_aps_on_switch(switch, username, password) do
    IO.puts("Connecting to switch: #{switch}...")

    case connect_ssh(switch, username, password) do
      {:ok, conn} ->
        aps = get_cisco_aps(conn, switch)
        disconnect_ssh(conn)
        IO.puts("  Found #{length(aps)} Cisco AP(s) on #{switch}")
        aps

      {:error, reason} ->
        IO.puts("  Error connecting to #{switch}: #{inspect(reason)}")
        []
    end
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

  defp get_cisco_aps(conn, switch) do
    # Execute "show power inline" command
    case execute_command(conn, "show power inline") do
      {:ok, power_output} ->
        # Get interfaces with Cisco APs
        interfaces = parse_power_inline_output(power_output)

        # For each interface, get CDP neighbor details to find hostname and MAC
        Enum.map(interfaces, fn interface ->
          get_ap_details(conn, interface, switch)
        end)
        |> Enum.reject(&is_nil/1)

      {:error, _reason} ->
        []
    end
  end

  defp get_ap_details(conn, interface, switch) do
    # Get CDP neighbor detail for this specific interface
    case execute_command(conn, "show cdp neighbors #{interface} detail") do
      {:ok, cdp_output} ->
        parse_cdp_neighbor_detail(cdp_output, interface, switch)

      {:error, _reason} ->
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

    # Find Cisco APs - devices starting with "C" in the Device column
    # Return list of interface names
    lines
    |> Enum.filter(&is_cisco_ap_line?/1)
    |> Enum.map(&extract_interface/1)
    |> Enum.reject(&is_nil/1)
  end

  defp is_cisco_ap_line?(line) do
    # The "show power inline" output typically has columns like:
    # Interface  Admin  Oper  Power   Device              Class Max
    # Gi1/0/1    auto   on    15.4    AIR-AP2802I-B-K9    4     30.0
    #
    # We're looking for lines where the Device column starts with "C"
    # Note: This is a simplified parser - adjust regex based on actual output format

    trimmed = String.trim(line)

    # Skip header lines and empty lines
    cond do
      trimmed == "" -> false
      String.contains?(trimmed, "Interface") -> false
      String.contains?(trimmed, "---") -> false
      true ->
        # Try to extract device name (typically the 5th column)
        parts = String.split(trimmed, ~r/\s+/)
        length(parts) >= 5 && String.starts_with?(Enum.at(parts, 4), "C")
    end
  end

  defp extract_interface(line) do
    # Parse the line to extract interface name
    parts = String.split(String.trim(line), ~r/\s+/)

    if length(parts) >= 1 do
      Enum.at(parts, 0)
    else
      nil
    end
  end

  defp parse_cdp_neighbor_detail(output, interface, switch) do
    # Parse CDP neighbor detail output to extract hostname and MAC address
    # Example output:
    # Device ID: AP-HOSTNAME
    # Platform: cisco AIR-AP2802I-B-K9, Capabilities: Trans-Bridge
    # ...
    # Entry address(es):
    #   IP address: 192.168.1.100
    # ...
    # Management address(es):
    # ...

    lines = String.split(output, "\n")

    hostname = extract_cdp_field(lines, "Device ID:")
    mac_address = extract_cdp_mac_address(lines)

    if hostname do
      %AP{
        hostname: hostname,
        mac_address: mac_address || "N/A",
        interface: interface,
        switch: switch
      }
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

  defp extract_cdp_mac_address(lines) do
    # Look for platform line which often contains MAC or look for address fields
    # CDP detail may show MAC in different formats, we'll try to extract it
    # Common patterns:
    # - In "Platform:" line: "cisco AIR-AP2802I-B-K9, Capabilities: ..."
    # - In address lines
    # - Sometimes as separate MAC address field

    # Try to find a MAC address pattern (xx:xx:xx:xx:xx:xx or xxxx.xxxx.xxxx)
    mac_regex = ~r/([0-9a-fA-F]{2}[:-]){5}[0-9a-fA-F]{2}|([0-9a-fA-F]{4}\.){2}[0-9a-fA-F]{4}/

    lines
    |> Enum.find_value(fn line ->
      case Regex.run(mac_regex, line) do
        [mac | _] -> mac
        nil -> nil
      end
    end)
  end

  defp display_results(aps) do
    IO.puts("\n" <> String.duplicate("=", 80))
    IO.puts("RESULTS: Found #{length(aps)} Cisco AP(s) total")
    IO.puts(String.duplicate("=", 80) <> "\n")

    if Enum.empty?(aps) do
      IO.puts("No Cisco APs found.")
    else
      # Group by switch
      aps_by_switch = Enum.group_by(aps, & &1.switch)

      Enum.each(aps_by_switch, fn {switch, switch_aps} ->
        IO.puts("Switch: #{switch}")
        IO.puts(String.duplicate("-", 80))

        Enum.each(switch_aps, fn ap ->
          IO.puts("  Interface: #{ap.interface}")
          IO.puts("  Hostname:  #{ap.hostname}")
          IO.puts("  MAC:       #{ap.mac_address}")
          IO.puts("")
        end)
      end)
    end
  end
end

# Run the script
CiscoAPFinder.run()
