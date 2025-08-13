defmodule IceReporter.Boundaries do
  @moduledoc """
  Context for managing US geographic boundaries.
  """

  import Ecto.Query, warn: false
  alias IceReporter.Repo
  alias IceReporter.Boundary

  @doc """
  Get all boundaries that might contain the given point (using bounding box pre-filter)
  """
  def get_candidate_boundaries(lng, lat) do
    from(b in Boundary,
      where: b.geometry_type in ["Polygon", "MultiPolygon"]
    )
    |> Repo.all()
    |> Enum.filter(fn boundary ->
      Boundary.point_in_bbox?(lng, lat, boundary.bbox || "[]")
    end)
  end

  @doc """
  Check if coordinates are within any US boundary
  """
  def contains_point?(lng, lat) do
    get_candidate_boundaries(lng, lat)
    |> Enum.any?(fn boundary ->
      case Boundary.to_geo_polygon(boundary) do
        {:ok, geometry} ->
          test_point = %Geo.Point{coordinates: {lng, lat}}
          Topo.contains?(geometry, test_point)
        {:error, _} ->
          false
      end
    end)
  end

  @doc """
  Import GeoJSON data into the database
  """
  def import_geojson_file(file_path) do
    with {:ok, json_data} <- File.read(file_path),
         {:ok, %{"geometries" => geometries}} <- Jason.decode(json_data) do
      
      # Clear existing data
      Repo.delete_all(Boundary)
      
      # Import each geometry
      Enum.with_index(geometries, fn geometry, index ->
        case geometry do
          %{"type" => "Polygon", "coordinates" => coordinates} ->
            bbox = Boundary.calculate_bbox(coordinates)
            
            attrs = %{
              name: "US State/Territory #{index + 1}",
              geometry_type: "Polygon",
              coordinates: Jason.encode!(coordinates),
              bbox: Jason.encode!(bbox)
            }
            
            %Boundary{}
            |> Boundary.changeset(attrs)
            |> Repo.insert()
            
          %{"type" => "MultiPolygon", "coordinates" => multipolygon_coordinates} ->
            # For MultiPolygon, we need to handle multiple polygons
            # Calculate bbox from all polygons in the MultiPolygon
            # MultiPolygon structure: [[[ring1], [ring2]], [[ring3], [ring4]]]
            all_coordinates = multipolygon_coordinates
            |> Enum.flat_map(fn polygon -> polygon end)  # Flatten polygons to get all rings
            |> Enum.flat_map(fn ring -> ring end)       # Flatten rings to get all coordinate pairs
            bbox = Boundary.calculate_bbox([all_coordinates])
            
            attrs = %{
              name: "US State/Territory #{index + 1}",
              geometry_type: "MultiPolygon",
              coordinates: Jason.encode!(multipolygon_coordinates),
              bbox: Jason.encode!(bbox)
            }
            
            %Boundary{}
            |> Boundary.changeset(attrs)
            |> Repo.insert()
            
          _ ->
            {:ok, :skipped}
        end
      end)
      |> Enum.filter(fn 
        {:ok, %Boundary{}} -> true
        _ -> false
      end)
      |> length()
      |> then(fn count ->
        {:ok, "Imported #{count} boundaries"}
      end)
    end
  end

  @doc """
  Get count of boundaries in database
  """
  def count_boundaries do
    Repo.aggregate(Boundary, :count, :id)
  end
end