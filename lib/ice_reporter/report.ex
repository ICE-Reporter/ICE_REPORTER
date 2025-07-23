defmodule IceReporter.Report do
  @moduledoc """
  Ecto schema for ICE activity reports.

  Represents reports submitted by users about ICE checkpoint locations,
  raids, patrols, and detention facilities. Reports automatically expire
  after 4 hours and include location data and descriptions.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: integer() | nil,
          type: String.t(),
          description: String.t() | nil,
          latitude: float(),
          longitude: float(),
          location_description: String.t() | nil,
          expires_at: DateTime.t() | nil,
          is_active: boolean(),
          inserted_at: NaiveDateTime.t() | nil,
          updated_at: NaiveDateTime.t() | nil
        }

  schema "reports" do
    field :type, :string
    field :description, :string
    field :latitude, :float
    field :longitude, :float
    field :location_description, :string
    field :expires_at, :utc_datetime
    field :is_active, :boolean, default: true

    timestamps()
  end

  @doc false
  def changeset(report, attrs) do
    report
    |> cast(attrs, [
      :type,
      :description,
      :latitude,
      :longitude,
      :location_description,
      :expires_at,
      :is_active
    ])
    |> validate_required([:type, :latitude, :longitude])
    |> validate_inclusion(:type, ["checkpoint", "raid", "patrol", "detention"])
    |> validate_number(:latitude, greater_than_or_equal_to: -90, less_than_or_equal_to: 90)
    |> validate_number(:longitude, greater_than_or_equal_to: -180, less_than_or_equal_to: 180)
    |> put_expires_at()
  end

  defp put_expires_at(changeset) do
    case get_field(changeset, :expires_at) do
      nil ->
        # Default to 4 hours from now
        expires_at =
          DateTime.utc_now() |> DateTime.add(4 * 60 * 60, :second) |> DateTime.truncate(:second)

        put_change(changeset, :expires_at, expires_at)

      _ ->
        changeset
    end
  end
end
