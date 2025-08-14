# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs

alias IceReporter.{Repo, Boundary}

current_count = Repo.aggregate(Boundary, :count, :id)

# Only seed if we have no boundaries or less than 50 (indicating incomplete import)
if current_count == 0 or current_count < 50 do
  
  # Clear existing boundaries if we need to re-seed
  if current_count > 0 do
    IO.puts("🗑️ Removing #{current_count} existing boundaries, loading full US boundaries...")
    Repo.delete_all(Boundary)
  else
    IO.puts("🌱 Seeding US boundaries data...")
  end
  
  # Look for CSV file in multiple possible locations
  csv_locations = [
    "/app/boundaries_export.csv",  # Production location
    Path.join(__DIR__, "../../boundaries_export.csv"),  # Development location
    "boundaries_export.csv"  # Current directory
  ]
  
  csv_file = Enum.find(csv_locations, &File.exists?/1)
  
  if csv_file do
    IO.puts("📍 Found CSV file at: #{csv_file}")
    line_count = File.stream!(csv_file) |> Enum.count()
    IO.puts("📄 Processing #{line_count} lines...")
    
    results = csv_file
    |> File.stream!()
    |> Enum.reduce({0, 0}, fn line, {success_count, error_count} ->
      case String.split(String.trim(line), "|") do
        [_id, name, state_code, geometry_type, coordinates, bbox, _inserted_at, _updated_at] ->
          try do
            %Boundary{
              name: name,
              state_code: if(state_code == "", do: nil, else: state_code),
              geometry_type: geometry_type,
              coordinates: coordinates,
              bbox: if(bbox == "", do: nil, else: bbox)
            }
            |> Repo.insert!()
            {success_count + 1, error_count}
          rescue
            error ->
              IO.puts("❌ Error inserting boundary '#{name}': #{inspect(error)}")
              {success_count, error_count + 1}
          end
        _ -> 
          IO.puts("⚠️ Skipping malformed line: #{String.slice(line, 0, 100)}...")
          {success_count, error_count}
      end
    end)
    
    {success_count, error_count} = results
    IO.puts("✅ Successfully imported #{success_count} boundaries (#{error_count} errors)")
    
    if success_count == 0 do
      raise "❌ CRITICAL: No boundaries were imported! Check CSV format and file contents."
    end
  else
    searched_locations = Enum.join(csv_locations, "\n  - ")
    error_message = """
    ❌ CRITICAL ERROR: boundaries_export.csv not found!
    
    Searched locations:
      - #{searched_locations}
    
    Cannot proceed without boundary data. Please ensure the CSV file is included in the deployment.
    """
    
    IO.puts(error_message)
    raise error_message
  end
else
  IO.puts("📊 Found #{current_count} boundaries already exist, skipping seed.")
end
