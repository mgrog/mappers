defmodule MappersWeb.API.V1.CoverageController do
  use MappersWeb, :controller

  alias Mappers.Uplinks

  def get_coverage_from_geo(conn, %{"coords" => coords}) do
    [lat, lng] = coords
    |> String.split(",")
    |> Enum.map(fn s -> String.to_float(s) end)

    h3_index = :h3.from_geo({lat, lng}, 9)
    h3_index_s = to_string(h3_index)

    # uplinks = Uplinks.get_uplinks(h3_index_s)
    uplinks = Jason.decode!(~s(
      [
        {
          "hotspot_name": "big-gunmetal-blackbird",
          "lat": 37.786888477848215,
          "lng": -122.40228617196821,
          "rssi": -93.0,
          "snr": -0.5,
          "timestamp": "2020-10-05T02:47:53.000000Z",
          "uplink_heard_id": "5125d638-ecbf-4d35-9cb9-969a160e589a"
        },
        {
          "hotspot_name": "cool-misty-stallion",
          "lat": 37.79041758042614,
          "lng": -122.4009885878894,
          "rssi": -114.0,
          "snr": -12.0,
          "timestamp": "2021-04-07T18:47:52.000000Z",
          "uplink_heard_id": "54d98b35-0765-4cc7-8871-3bee62b80bff"
        },
        {
          "hotspot_name": "elegant-misty-sloth",
          "lat": 37.7907203954718,
          "lng": -122.40301387640227,
          "rssi": -101.0,
          "snr": -9.199999809265137,
          "timestamp": "2021-08-13T23:30:05.000000Z",
          "uplink_heard_id": "9d49257e-9328-4e94-8f18-830a39628079"
        }]))

    %{"rssi" => best_rssi, "snr" => best_snr, "lat" => uplinkLat, "lng" => uplinkLng} = best_uplink(uplinks)

    conn
    |> json(%{
      hex: h3_index,
      distance_to_best: distance_between([lat, lng], [uplinkLat, uplinkLng]),
      distance_to_closest: closest_distance(uplinks, [lat, lng]),
      best_rssi: best_rssi,
      best_snr: best_snr,
      uplinks: uplinks,
    })
  end

  def best_uplink(uplinks) do
    uplinks
    |> Enum.max_by(fn x -> Map.get(x, "rssi") end)
  end

  def distance_between(origin, uplinkLoc) do
    Geocalc.distance_between(origin, uplinkLoc)/1000 # in km
  end

  def closest_distance(uplinks, origin) do
    uplinks
    |> Enum.map(fn x ->
      %{"lat" => uplinkLat, "lng" => uplinkLng} = x

      distance_between(origin, [uplinkLat, uplinkLng])
      end)
    |> Enum.min
    |> Kernel./(1000) # in km
  end

end
