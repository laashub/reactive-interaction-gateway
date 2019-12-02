defmodule RigInboundGateway.ApiProxy.Handler.Kinesis do
  @moduledoc """
  Handles requests for Kinesis targets.

  """
  use Rig.Config, [:kinesis_request_stream, :kinesis_request_region, :response_timeout]

  alias ExAws
  alias Plug.Conn

  alias RigMetrics.ProxyMetrics

  alias Rig.Connection.Codec

  alias RigInboundGateway.ApiProxy.Handler
  @behaviour Handler

  @help_text """
  Produce the request to a Kinesis topic and optionally wait for the (correlated) response.

  Expects a JSON encoded HTTP body with the following fields:

  - `event`: The published CloudEvent >= v0.2. The event is extended by metadata
  written to the "rig" extension field (following the CloudEvents v0.2 spec).
  - `partition`: The targetted Kafka partition.

  """

  # ---

  @impl Handler
  def handle_http_request(conn, api, endpoint, request_path)

  @doc "CORS response for preflight request."
  def handle_http_request(
        %{method: "OPTIONS"} = conn,
        _,
        %{"target" => "kinesis"} = endpoint,
        _
      ) do
    ProxyMetrics.count_proxy_request(
      conn.method,
      conn.request_path,
      "kinesis",
      Map.get(endpoint, "response_from", "http"),
      "ok"
    )

    conn
    |> with_cors()
    |> Conn.send_resp(:no_content, "")
  end

  @doc @help_text
  def handle_http_request(conn, api, endpoint, request_path)

  def handle_http_request(
        conn,
        _,
        %{"target" => "kinesis"} = endpoint,
        request_path
      ) do
    response_from = Map.get(endpoint, "response_from", "http")

    conn.assigns[:body]
    |> Jason.decode()
    |> case do
      # Deprecated way to pass events:
      {:ok, %{"partition" => partition, "event" => event}} ->
        do_handle_http_request(conn, request_path, partition, event, response_from)

      # Preferred way to pass events, where the partition goes into the "rig" extension:
      {:ok, %{"specversion" => _, "rig" => %{"target_partition" => partition}} = event} ->
        do_handle_http_request(conn, request_path, partition, event, response_from)

      {:ok, _} ->
        respond_with_bad_request(conn, response_from, "the body does not look like a CloudEvent")

      {:error, _} ->
        respond_with_bad_request(conn, response_from, "expected a JSON encoded request body")
    end
  end

  # ---

  def do_handle_http_request(
        conn,
        request_path,
        partition,
        event,
        response_from
      ) do
    kinesis_message =
      event
      |> Map.put("rig", %{
        correlation: Codec.serialize(self()),
        remoteip: to_string(:inet_parse.ntoa(conn.remote_ip)),
        host: conn.host,
        port: conn.port,
        scheme: conn.scheme,
        headers: Enum.map(conn.req_headers, &Tuple.to_list(&1)),
        method: conn.method,
        path: request_path,
        query: conn.query_string
      })
      |> Poison.encode!()

    produce(partition, kinesis_message)

    wait_for_response? =
      case response_from do
        # TODO: "kinesis" -> true
        _ -> false
      end

    conn = with_cors(conn)

    if wait_for_response? do
      wait_for_response(conn, response_from)
    else
      ProxyMetrics.count_proxy_request(
        conn.method,
        conn.request_path,
        "kinesis",
        response_from,
        "ok"
      )

      Conn.send_resp(conn, :accepted, "Accepted.")
    end
  end

  def respond_with_bad_request(conn, response_from, description) do
    response = """
    Bad request: #{description}.

    # Usage

    #{@help_text}
    """

    ProxyMetrics.count_proxy_request(
      conn.method,
      conn.request_path,
      "kinesis",
      response_from,
      "bad_request"
    )

    Conn.send_resp(conn, :bad_request, response)
  end

  # ---

  defp wait_for_response(conn, response_from) do
    conf = config()

    receive do
      {:response_received, response} ->
        ProxyMetrics.count_proxy_request(
          conn.method,
          conn.request_path,
          "kinesis",
          response_from,
          "ok"
        )

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.send_resp(:ok, response)
    after
      conf.response_timeout ->
        ProxyMetrics.count_proxy_request(
          conn.method,
          conn.request_path,
          "kinesis",
          response_from,
          "response_timeout"
        )

        conn
        |> Conn.send_resp(:gateway_timeout, "")
    end
  end

  # ---

  defp produce(partition_key, plaintext) do
    conf = config()

    ExAws.Kinesis.put_record(
      _stream_name = conf.kinesis_request_stream,
      _partition_key = partition_key,
      _data = plaintext
    )
    |> ExAws.request(region: conf.kinesis_request_region)
  end

  # ---

  defp with_cors(conn) do
    conn
    |> Conn.put_resp_header("access-control-allow-origin", config().cors)
    |> Conn.put_resp_header("access-control-allow-methods", "*")
    |> Conn.put_resp_header("access-control-allow-headers", "content-type,authorization")
  end
end