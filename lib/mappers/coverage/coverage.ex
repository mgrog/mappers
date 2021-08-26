defmodule Mappers.Coverage do
  alias Mappers.Repo
  alias Mappers.H3.Res9
  alias Mappers.Uplinks

  def get_coverage_from_geo(coords) do
    check = validateCoords(coords)

    case check do
      {:ok, origin} ->
        h3_index = :h3.from_geo(origin, 9)

        h3 = Repo.get_by(Res9, h3_index_int: h3_index)
        uplinks = Uplinks.get_uplinks(h3.id)

        %{}
        |> Map.put(:hex, h3.id)
        |> Map.put(:best_rssi, h3.best_rssi)
        |> Map.put(:snr, h3.snr)
        |> Map.put(:distance_to_uplink, distance_to_nearest_uplink(origin, uplinks))
        |> Map.put(:uplinks_in_area, uplinks)
        |> Map.put(:covered, covered?())

      {:error, reason} ->
        %{error: reason}
    end
  end

  def distance_to_nearest_uplink(origin, uplinks) do
    uplinks
    |> Enum.map(fn x ->
      %{lat: uLat, lng: uLng} = x

      # meters to miles
      Geocalc.distance_between(origin, [uLat, uLng]) / 1609
    end)
    |> Enum.min(&<=/2, fn -> nil end)
  end

  def covered?() do
    # calculate whether you should have coverage
    true
  end

  def validateCoords(coords) do
    match = String.match?(coords, ~r/([-]?([0-9]*[.])?[0-9]+),([-]?([0-9]*[.])?[0-9]+)/)

    if(match) do
      origin =
        coords
        |> String.split(",")
        |> Enum.map(fn s -> String.to_float(s) end)
        |> List.to_tuple()

      {:ok, origin}
    else
      {:error, "Coordinates are not valid!"}
    end
  end
end
