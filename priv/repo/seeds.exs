# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs

alias IceReporter.{Repo, Boundary}

# Check if boundaries already exist
if Repo.aggregate(Boundary, :count, :id) == 0 do
  IO.puts("Seeding US boundaries data...")
  
  # Import CSV data if file exists, otherwise create basic boundary
  csv_file = Path.join(__DIR__, "../../boundaries_export.csv")
  
  if File.exists?(csv_file) do
    csv_file
    |> File.stream!()
    |> Enum.each(fn line ->
      case String.split(String.trim(line), "|") do
        [id, name, state_code, geometry_type, coordinates, bbox, inserted_at, updated_at] ->
          %Boundary{
            name: name,
            state_code: if(state_code == "", do: nil, else: state_code),
            geometry_type: geometry_type,
            coordinates: coordinates,
            bbox: if(bbox == "", do: nil, else: bbox)
          }
          |> Repo.insert!()
        _ -> :skip
      end
    end)
    
    IO.puts("✅ Imported boundaries from CSV file")
  else
    # Fallback: create basic US boundary
    %Boundary{
      name: "United States (Basic)",
      geometry_type: "Polygon", 
      coordinates: Jason.encode!([[
        [-180, 18], [-180, 72], [-65, 72], [-65, 18], [-180, 18]
      ]]),
      bbox: Jason.encode!([-180, 18, -65, 72])
    }
    |> Repo.insert!()
    
    IO.puts("✅ Created basic US boundary (CSV file not found)")
  end
else
  IO.puts("Boundaries already exist, skipping seed.")
end
