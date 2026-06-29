#!/usr/bin/env elixir

# MAC Address Differ Utility
# Imports two MAC address lists from CSV files, normalizes the MAC addresses,
# differences them to find unique MACs in each list, and exports to a timestamped CSV.

defmodule MacDiffer do
  @moduledoc """
  Script to import 2 MAC address lists from CSV files (one MAC per line),
  normalize the inputs, difference the lists, and output unique MACs per list to CSV.
  """

  def run do
    IO.puts("\n=== MAC Address Differ ===\n")

    # Determine input files (CLI arguments or prompt with defaults)
    {file1, file2} = parse_input_filenames()

    IO.puts("Reading List 1 from: #{file1}")
    IO.puts("Reading List 2 from: #{file2}\n")

    list1_macs = read_and_normalize_macs(file1)
    list2_macs = read_and_normalize_macs(file2)

    IO.puts("Processed #{MapSet.size(list1_macs)} unique valid MAC(s) from #{file1}")
    IO.puts("Processed #{MapSet.size(list2_macs)} unique valid MAC(s) from #{file2}\n")

    # Difference sets
    uniques1 = MapSet.difference(list1_macs, list2_macs) |> MapSet.to_list() |> Enum.sort()
    uniques2 = MapSet.difference(list2_macs, list1_macs) |> MapSet.to_list() |> Enum.sort()

    IO.puts("Found #{length(uniques1)} MAC(s) unique to List 1 (#{file1})")
    IO.puts("Found #{length(uniques2)} MAC(s) unique to List 2 (#{file2})\n")

    # Prepare timestamped output
    run_time = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    file_timestamp = String.replace(run_time, ~r/[:\.]/, "-")

    File.mkdir_p!("output")
    output_path = Path.join("output", "#{file_timestamp}-mac_differ.csv")

    write_csv(output_path, uniques1, uniques2)

    IO.puts("Results written to: #{output_path}\n")
  end

  defp parse_input_filenames do
    case System.argv() do
      [f1, f2 | _] ->
        {f1, f2}

      _ ->
        f1 = get_input_with_default("Enter first CSV file", "list1.csv")
        f2 = get_input_with_default("Enter second CSV file", "list2.csv")
        {f1, f2}
    end
  end

  defp get_input_with_default(prompt, default) do
    case IO.gets("#{prompt} [default: #{default}]: ") do
      :eof ->
        default

      {:error, _} ->
        default

      input ->
        trimmed = String.trim(input)
        if trimmed == "", do: default, else: trimmed
    end
  end

  @doc """
  Reads a file, extracts lines, cleans comments/empty lines, normalizes MAC addresses,
  and returns a MapSet of normalized MAC addresses.
  """
  def read_and_normalize_macs(filename) do
    if not File.exists?(filename) do
      IO.puts("Error: File '#{filename}' not found.")
      System.halt(1)
    end

    filename
    |> File.stream!()
    |> Enum.reduce(MapSet.new(), fn line, acc ->
      case extract_and_normalize_mac(line) do
        {:ok, normalized_mac} -> MapSet.put(acc, normalized_mac)
        :skip -> acc
      end
    end)
  end

  @doc """
  Normalizes a MAC address string into canonical Cisco dot format (aabb.ccdd.eeff).
  Returns {:ok, normalized} if valid 12 hex digits, or :skip if comment, header, or invalid.
  """
  def extract_and_normalize_mac(line) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" or String.starts_with?(trimmed, "#") ->
        :skip

      true ->
        # If line contains CSV columns, take the first column
        col = trimmed |> String.split(",") |> List.first() |> String.trim()

        # Remove quotes if present
        unquoted = String.replace(col, ~r/^["']|["']$/, "")

        # Keep only hexadecimal characters [0-9a-fA-F]
        clean_hex = String.replace(unquoted, ~r/[^0-9a-fA-F]/, "")

        if String.length(clean_hex) == 12 do
          # Format as Cisco dot notation: aabb.ccdd.eeff (lowercase)
          lower = String.downcase(clean_hex)
          p1 = String.slice(lower, 0, 4)
          p2 = String.slice(lower, 4, 4)
          p3 = String.slice(lower, 8, 4)
          {:ok, "#{p1}.#{p2}.#{p3}"}
        else
          :skip
        end
    end
  end

  defp write_csv(output_path, uniques1, uniques2) do
    file = File.open!(output_path, [:write, :utf8])
    IO.write(file, "list1-uniques,list2-uniques\n")

    zip_write(file, uniques1, uniques2)

    File.close(file)
  end

  defp zip_write(_file, [], []), do: :ok
  defp zip_write(file, [h1 | t1], [h2 | t2]) do
    IO.write(file, "#{h1},#{h2}\n")
    zip_write(file, t1, t2)
  end
  defp zip_write(file, [h1 | t1], []) do
    IO.write(file, "#{h1},\n")
    zip_write(file, t1, [])
  end
  defp zip_write(file, [], [h2 | t2]) do
    IO.write(file, ",#{h2}\n")
    zip_write(file, [], t2)
  end
end

# Run script unless loaded for testing/compilation
if System.argv() != ["--no-run"] do
  MacDiffer.run()
end
