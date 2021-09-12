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
              # will expand search rings out to 32 unless something found, doubling ring each time
              result = expand_search_area(h3_index, 4, 0)

              if length(result.nearby_hexes) == 0 do
                %{covered: false, reason: "No nearby signal data found"}
              else
                nearest = distance_from_nearest_uplink(origin, result.nearby_uplinks)

                estimated = estimateCoverage(origin, result.nearby_uplinks, nearest)

                %{}
                |> Map.put(:h3_id, nil)
                |> Map.put(:state, "not_mapped")
                |> Map.put(:estimated_rssi, estimated.rssi)
                |> Map.put(:estimated_snr, estimated.snr)
                |> Map.put(
                  :distance_from_nearest_uplink,
                  nearest
                )
                |> Map.put(:uplinks_in_area, result.nearby_uplinks)
                |> Map.put(:nearby_readings, result.nearby_hexes)
                |> Map.put(:covered, estimated.coverage)
              end

            _ ->
              uplinks = Uplinks.get_uplinks(h3.id)

              %{}
              |> Map.put(:h3_id, h3.id)
              |> Map.put(:state, h3.state)
              |> Map.put(:measured_rssi, h3.best_rssi)
              |> Map.put(:measured_snr, h3.snr)
              |> Map.put(
                :distance_from_nearest_uplink,
                distance_from_nearest_uplink(origin, uplinks)
              )
              |> Map.put(:uplinks_in_area, uplinks)
              |> Map.put(:covered, usable_signal?(h3.best_rssi, h3.snr))
          end

      {:error, reason} ->
        %{error: reason}
    end
  end

  def expand_search_area(h3_origin_int, range, prev) do
    IO.puts("expanding search: range #{range} from range #{prev}...")

    indexes =
      :h3.k_ring_distances(h3_origin_int, range)
      |> Enum.filter(fn {_, dist} -> dist > prev end)
      |> Enum.map(fn {index, _} -> index end)

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

    nearby_hexes = Repo.all(query_hexes)

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
        order_by: [desc: uh.rssi],
        select: %{
          h3_id: h3.h3_res9_id,
          uplink_heard_id: uh.id,
          hotspot_name: uh.hotspot_name,
          rssi: uh.rssi,
          snr: uh.snr,
          lat: uh.latitude,
          lng: uh.longitude,
          timestamp: uh.timestamp
        }

    nearby_uplinks =
      Repo.all(query_uplinks)
      |> Enum.map(fn %{lat: uLat, lng: uLng} = x ->
        {h3_index_int, _} = Integer.parse(x.h3_id, 16)
        measurement_coords = :h3.to_geo(h3_index_int)

        Map.put(x, :distance_at_measure, point_distance(measurement_coords, [uLat, uLng]))
      end)

    if(length(nearby_hexes) == 0 && range < 32) do
      expand_search_area(h3_origin_int, range * 2, range)
    else
      %{nearby_hexes: nearby_hexes, nearby_uplinks: nearby_uplinks}
    end
  end

  def distance_from_nearest_uplink(origin, uplinks) do
    uplinks
    |> Enum.map(fn x ->
      %{lat: uLat, lng: uLng} = x

      # meters to miles
      point_distance(origin, [uLat, uLng])
    end)
    |> Enum.min(&<=/2, fn -> nil end)
  end

  def estimateCoverage(coords, uplinks, nearest_uplink_dist) do
    # estimate whether you should have coverage
    avg_dist =
      uplinks
      |> Enum.map(fn x -> x.distance_at_measure end)
      |> Enum.sum()
      |> Kernel./(length(uplinks))

    avg_rssi =
      uplinks
      |> Enum.map(fn x -> x.rssi end)
      |> Enum.sum()
      |> Kernel./(length(uplinks))

    avg_snr =
      uplinks
      |> Enum.map(fn x -> x.snr end)
      |> Enum.sum()
      |> Kernel./(length(uplinks))

    cond do
      nearest_uplink_dist < avg_dist ->
        %{rssi: avg_rssi, snr: avg_snr, coverage: usable_signal?(avg_rssi, avg_snr)}

      nearest_uplink_dist > avg_dist ->
        diff_dist = nearest_uplink_dist - avg_dist
        estimate = avg_rssi - path_loss(diff_dist, 915, 3, 3)
        %{rssi: estimate, snr: avg_snr, coverage: usable_signal?(avg_rssi, avg_snr)}
    end
  end

  def usable_signal?(rssi, snr) do
    rssi > -120 && snr > -20
  end

  def point_distance(origin, dest) do
    Geocalc.distance_between(origin, dest) / 1609.34
  end

  def path_loss(d, f, gTx, gRx) do
    # units in miles and megahertz
    20 * (:math.log10(d) + :math.log10(f)) - gTx - gRx + 36.5939
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
