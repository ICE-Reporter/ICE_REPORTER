defmodule IceReporter.Boundary do
  @moduledoc """
  Schema for US geographic boundaries from Census data.
  """
  
  use Ecto.Schema
  import Ecto.Changeset

  schema "us_boundaries" do
    field :name, :string
    field :state_code, :string
    field :geometry_type, :string
    field :coordinates, :string  # JSON string of coordinates
    field :bbox, :string         # JSON string of bounding box [min_lng, min_lat, max_lng, max_lat]

    timestamps()
  end

  @doc false
  def changeset(boundary, attrs) do
    boundary
    |> cast(attrs, [:name, :state_code, :geometry_type, :coordinates, :bbox])
    |> validate_required([:geometry_type, :coordinates])
    |> validate_inclusion(:geometry_type, ["Polygon", "MultiPolygon"])
  end

  @doc """
  Convert stored coordinates JSON back to Geo.Polygon or Geo.MultiPolygon struct
  """
  def to_geo_polygon(%__MODULE__{geometry_type: "Polygon", coordinates: coords_json}) do
    with {:ok, coordinates} <- Jason.decode(coords_json) do
      # Convert coordinate arrays back to tuples for Geo.Polygon format
      polygon_coords = Enum.map(coordinates, fn ring ->
        Enum.map(ring, fn [lng, lat] -> {lng, lat} end)
      end)
      
      {:ok, %Geo.Polygon{coordinates: polygon_coords}}
    end
  end

  def to_geo_polygon(%__MODULE__{geometry_type: "MultiPolygon", coordinates: coords_json}) do
    with {:ok, multipolygon_coordinates} <- Jason.decode(coords_json) do
      # Convert MultiPolygon coordinate arrays back to tuples
      multipolygon_coords = Enum.map(multipolygon_coordinates, fn polygon ->
        Enum.map(polygon, fn ring ->
          Enum.map(ring, fn [lng, lat] -> {lng, lat} end)
        end)
      end)
      
      {:ok, %Geo.MultiPolygon{coordinates: multipolygon_coords}}
    end
  end

  def to_geo_polygon(_), do: {:error, :invalid_geometry}

  @doc """
  Calculate bounding box from coordinates
  """
  def calculate_bbox(coordinates) when is_list(coordinates) do
    # Extract all coordinate pairs from all rings
    all_coords = coordinates
    |> Enum.flat_map(fn ring -> ring end)  # Flatten rings to get all coordinate pairs
    |> Enum.filter(fn item -> is_list(item) && length(item) == 2 end)  # Ensure we have [lng, lat] pairs
    
    {min_lng, max_lng} = all_coords |> Enum.map(fn [lng, _lat] -> lng end) |> Enum.min_max()
    {min_lat, max_lat} = all_coords |> Enum.map(fn [_lng, lat] -> lat end) |> Enum.min_max()
    
    [min_lng, min_lat, max_lng, max_lat]
  end

  @doc """
  Quick bounding box check to filter candidates before expensive polygon test
  """
  def point_in_bbox?(lng, lat, bbox_json) when is_binary(bbox_json) do
    case Jason.decode(bbox_json) do
      {:ok, [min_lng, min_lat, max_lng, max_lat]} ->
        lng >= min_lng && lng <= max_lng && lat >= min_lat && lat <= max_lat
      _ ->
        true  # If bbox parsing fails, don't filter out
    end
  end
end