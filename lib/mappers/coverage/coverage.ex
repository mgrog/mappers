defmodule Mappers.Coverage do
  import Ecto.Query
  import Geo.PostGIS
  alias Mappers.Repo
  alias Mappers.H3.Res9
  alias Mappers.Uplinks
  alias Mappers.H3.Links.Link
  alias Mappers.UplinksHeards.UplinkHeard

  def get_coverage_from_geo(coords_s) do
    check = validateCoords(coords_s)

    case check do
      {:ok, origin} ->
        h3_index = :h3.from_geo(origin, 9)

        h3 = Repo.get_by(Res9, h3_index_int: h3_index)

        resp =
          case h3 do
            nil ->
              IO.puts("no data, searching nearby area")
              result = search_area_for_signal_data(h3_index)

              if length(result.nearby_hexes) == 0 do
                %{covered: false, reason: "No nearby signal data found"}
              else
                avg_rssi =
                  result.nearby_hexes
                  |> Enum.reduce(0, fn x, acc -> x.best_rssi + acc end)
                  |> Kernel./(length(result.nearby_hexes))

                avg_snr =
                  result.nearby_hexes
                  |> Enum.reduce(0, fn x, acc -> x.snr + acc end)
                  |> Kernel./(length(result.nearby_hexes))

                %{}
                |> Map.put(:h3_id, nil)
                |> Map.put(:state, "not mapped")
                |> Map.put(:best_rssi, avg_rssi)
                |> Map.put(:snr, avg_snr)
                |> Map.put(
                  :distance_to_uplink,
                  distance_to_nearest_uplink(origin, result.nearby_uplinks)
                )
                |> Map.put(:uplinks_in_area, result.nearby_uplinks)
                |> Map.put(:covered, covered?())
              end

            _ ->
              uplinks = Uplinks.get_uplinks(h3.id)

              %{}
              |> Map.put(:h3_id, h3.id)
              |> Map.put(:state, h3.state)
              |> Map.put(:best_rssi, h3.best_rssi)
              |> Map.put(:snr, h3.snr)
              |> Map.put(
                :distance_to_uplink,
                distance_to_nearest_uplink(origin, uplinks)
              )
              |> Map.put(:uplinks_in_area, uplinks)
              |> Map.put(:covered, covered?())
          end

      {:error, reason} ->
        %{error: reason}
    end
  end

  def search_area_for_signal_data(h3_origin_int) do
    indexes = :h3.k_ring(h3_origin_int, 9)

    query_hexes =
      from h3_res9 in Res9,
        where: h3_res9.h3_index_int in ^indexes,
        select: %{
          id: h3_res9.id,
          h3_index_int: h3_res9.h3_index_int,
          state: h3_res9.state,
          best_rssi: h3_res9.best_rssi,
          snr: h3_res9.snr
        }

    nearby_hexes =
      Repo.all(query_hexes)
      |> Enum.map(fn x ->
        Map.put(x, :distance, :h3.grid_distance(h3_origin_int, x.h3_index_int))
      end)

    hex_ids =
      nearby_hexes
      |> Enum.map(fn x -> x.id end)

    query_uplinks =
      from u in Uplinks.Uplink,
        join: uh in UplinkHeard,
        on: u.id == uh.uplink_id,
        join: h3 in Link,
        on: h3.uplink_id == u.id,
        where: h3.h3_res9_id in ^hex_ids,
        distinct: [uh.hotspot_name],
        order_by: [desc: uh.rssi],
        select: %{
          uplink_heard_id: uh.id,
          hotspot_name: uh.hotspot_name,
          rssi: uh.rssi,
          snr: uh.snr,
          lat: uh.latitude,
          lng: uh.longitude,
          timestamp: uh.timestamp
        }

    nearby_uplinks = Repo.all(query_uplinks)

    %{nearby_hexes: nearby_hexes, nearby_uplinks: nearby_uplinks}
  end

  def distance_to_nearest_uplink(origin, uplinks) do
    uplinks
    |> Enum.map(fn x ->
      %{lat: uLat, lng: uLng} = x

      # meters to miles
      Geocalc.distance_between(origin, [uLat, uLng]) / 1609.34
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
