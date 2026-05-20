defmodule Pid.MqttClient do
  @moduledoc false

  use GenServer
  require Logger

  @connect_retry 5_000
  @qos 1

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Publish a set_pwm command. Returns :ok or {:error, reason}."
  def publish_pwm(value) when is_integer(value) do
    GenServer.call(__MODULE__, {:publish_pwm, value})
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    conf = Application.fetch_env!(:pid, :mqtt)

    topics = %{
      metric: "metric/#{conf[:group]}/#{conf[:co2_device]}",
      cmd: "cmd/pid/co2",
      pwm: "cmd/#{conf[:group]}/#{conf[:pwm_device]}"
    }

    send(self(), :connect)
    {:ok, %{emqtt: nil, topics: topics}}
  end

  @impl true
  def handle_call({:publish_pwm, _value}, _from, %{emqtt: nil} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:publish_pwm, value}, _from, state) do
    payload = Jason.encode!(%{"set_pwm" => value})

    result =
      case :emqtt.publish(state.emqtt, state.topics.pwm, payload, @qos) do
        {:ok, _packet_id} -> :ok
        :ok -> :ok
        {:error, reason} -> {:error, reason}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_info(:connect, state) do
    conf = Application.fetch_env!(:pid, :mqtt)

    opts =
      [
        host: conf[:host],
        port: conf[:port],
        client_id: "pid_controller",
        clean_start: false,
        reconnect: :infinity,
        reconnect_timeout: 5,
        keepalive: 60
      ]
      |> then(fn o ->
        if conf[:username],
          do: o ++ [username: conf[:username], password: conf[:password]],
          else: o
      end)

    with {:ok, pid} <- :emqtt.start_link(opts),
         {:ok, _} <- :emqtt.connect(pid),
         {:ok, _, _} <-
           :emqtt.subscribe(pid, [{state.topics.metric, @qos}, {state.topics.cmd, @qos}]) do
      Logger.info(
        "MqttClient connected, subscribed to #{state.topics.metric} and #{state.topics.cmd}"
      )

      {:noreply, %{state | emqtt: pid}}
    else
      {:error, reason} ->
        Logger.warning(
          "MqttClient failed to connect: #{inspect(reason)}, retrying in #{@connect_retry}ms"
        )

        Process.send_after(self(), :connect, @connect_retry)
        {:noreply, state}
    end
  end

  def handle_info({:publish, %{topic: topic, payload: payload}}, state) do
    GenServer.cast(Pid.Co2Controller, {:mqtt_message, topic, payload})
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    Logger.warning("MqttClient emqtt process down: #{inspect(reason)}")
    Process.send_after(self(), :connect, @connect_retry)
    {:noreply, %{state | emqtt: nil}}
  end

  def handle_info({:EXIT, _pid, reason}, state) do
    Logger.warning("MqttClient received EXIT: #{inspect(reason)}")
    Process.send_after(self(), :connect, @connect_retry)
    {:noreply, %{state | emqtt: nil}}
  end

  def handle_info(msg, state) do
    Logger.debug("MqttClient unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end
end
