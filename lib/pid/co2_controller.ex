defmodule Pid.Co2Controller do
  @moduledoc false

  use GenServer
  require Logger

  alias Pid.{AutoTuner, MqttClient, Store}

  @watchdog_ms 5 * 60 * 1000
  @persist_every 10

  @default_kp 0.0
  @default_ki 0.0
  @default_setpoint 800
  @default_output_min 0.0
  @default_output_max 1023.0
  @default_last_output 300
  @default_enabled false
  @default_relay_low 307
  @default_relay_high 409

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    conf = Application.fetch_env!(:pid, :mqtt)

    kp = Store.get(:kp, @default_kp)
    ki = Store.get(:ki, @default_ki)
    setpoint = Store.get(:setpoint, @default_setpoint)
    output_min = Store.get(:output_min, @default_output_min) * 1.0
    output_max = Store.get(:output_max, @default_output_max) * 1.0
    last_output = Store.get(:last_output, @default_last_output)
    enabled = Store.get(:enabled, @default_enabled)
    relay_low = Store.get(:relay_low, @default_relay_low)
    relay_high = Store.get(:relay_high, @default_relay_high)

    controller = build_controller(kp, ki, last_output, {output_min, output_max})

    Logger.info(
      "Co2Controller started — enabled: #{enabled}, setpoint: #{setpoint} ppm, " <>
        "Kp: #{kp}, Ki: #{ki}, last_output: #{last_output}"
    )

    state = %{
      controller: controller,
      setpoint: setpoint,
      enabled: enabled,
      last_output: last_output,
      output_limits: {output_min, output_max},
      relay_low: relay_low,
      relay_high: relay_high,
      autotune: nil,
      watchdog_ref: nil,
      cycle_count: 0,
      metric_topic: "metric/#{conf[:group]}/#{conf[:co2_device]}"
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:mqtt_message, topic, payload}, state) do
    case Jason.decode(payload) do
      {:ok, msg} ->
        {:noreply, route_message(msg, topic, state)}

      {:error, _} ->
        Logger.warning("Co2Controller: failed to decode payload on #{topic}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:watchdog, state) do
    Logger.warning(
      "Co2Controller: no CO2 reading for 5 minutes — holding output #{state.last_output}"
    )

    {:noreply, %{state | watchdog_ref: nil}}
  end

  # Routing

  defp route_message(
         %{"metric" => "co2", "value" => value},
         topic,
         %{metric_topic: topic} = state
       ) do
    handle_co2(value, state)
  end

  defp route_message(%{"metric" => _}, topic, %{metric_topic: topic} = state), do: state

  defp route_message(msg, _topic, state) do
    apply_commands(msg, state)
  end

  # CO2 reading handler

  defp handle_co2(value, state) do
    co2 = trunc(value)
    state = reset_watchdog(state)

    if state.enabled do
      compute_output(co2, state)
    else
      Logger.debug("Co2Controller: CO2=#{co2} ppm (controller disabled)")
      state
    end
  end

  defp compute_output(co2, %{autotune: %AutoTuner{} = tuner} = state) do
    run_autotune_step(co2, tuner, state)
  end

  defp compute_output(co2, state) do
    run_pi_step(co2, state)
  end

  defp run_autotune_step(co2, tuner, state) do
    error = co2 - state.setpoint
    {output, updated_tuner, result} = AutoTuner.step(error, tuner)

    case MqttClient.publish_pwm(output) do
      :ok ->
        Logger.debug("Co2Controller: autotune CO2=#{co2} ppm, error=#{error}, relay=#{output}")

      {:error, reason} ->
        Logger.warning("Co2Controller: publish failed: #{inspect(reason)}")
    end

    case result do
      :running ->
        %{state | autotune: updated_tuner, last_output: output}

      {:done, kp, ki} ->
        Logger.info(
          "Co2Controller: autotune done — Kp=#{Float.round(kp, 4)}, Ki=#{Float.round(ki, 6)}"
        )

        apply_autotune_results(kp, ki, %{state | autotune: nil, last_output: output})

      :timeout ->
        Logger.warning(
          "Co2Controller: autotune timed out after #{updated_tuner.step} steps without convergence"
        )

        %{state | autotune: nil}
    end
  end

  defp apply_autotune_results(kp, ki, state) do
    Store.put(:kp, kp)
    Store.put(:ki, ki)

    controller =
      state.controller
      |> PidController.set_kp(kp)
      |> PidController.set_ki(ki)
      |> reseed_integral(state.last_output, ki)

    %{state | controller: controller}
  end

  defp run_pi_step(co2, state) do
    input = state.setpoint - co2
    {:ok, raw_output, updated_controller} = PidController.output(input, state.controller)

    output = raw_output |> round() |> clamp_to_limits(state.output_limits)

    controller = antiwindup(raw_output, state.output_limits, updated_controller, state.controller)

    case MqttClient.publish_pwm(output) do
      :ok ->
        Logger.debug(
          "Co2Controller: CO2=#{co2} ppm → error=#{co2 - state.setpoint}, PWM=#{output}"
        )

      {:error, reason} ->
        Logger.warning("Co2Controller: publish failed: #{inspect(reason)}")
    end

    cycle_count = state.cycle_count + 1

    new_state = %{
      state
      | controller: controller,
        last_output: output,
        cycle_count: cycle_count
    }

    if rem(cycle_count, @persist_every) == 0, do: Store.put(:last_output, output)

    new_state
  end

  # Command handlers

  defp apply_commands(msg, state) do
    Enum.reduce(msg, state, fn {key, value}, acc -> apply_command(key, value, acc) end)
  end

  defp apply_command("set_kp", value, state) when is_number(value) do
    kp = value * 1.0
    Store.put(:kp, kp)
    Logger.info("Co2Controller: Kp=#{kp}")
    %{state | controller: PidController.set_kp(state.controller, kp)}
  end

  defp apply_command("set_ki", value, state) when is_number(value) do
    ki = value * 1.0

    controller =
      state.controller |> PidController.set_ki(ki) |> reseed_integral(state.last_output, ki)

    Store.put(:ki, ki)
    Logger.info("Co2Controller: Ki=#{ki}")
    %{state | controller: controller}
  end

  defp apply_command("set_setpoint", value, state) when is_integer(value) do
    Store.put(:setpoint, value)
    Logger.info("Co2Controller: setpoint=#{value} ppm")
    %{state | setpoint: value}
  end

  defp apply_command("set_output_min", value, state) when is_number(value) do
    {_old_min, old_max} = state.output_limits
    new_limits = {value * 1.0, old_max}
    Store.put(:output_min, value * 1.0)
    Logger.info("Co2Controller: output_min=#{value}")
    %{state | output_limits: new_limits}
  end

  defp apply_command("set_output_max", value, state) when is_number(value) do
    {old_min, _old_max} = state.output_limits
    new_limits = {old_min, value * 1.0}
    Store.put(:output_max, value * 1.0)
    Logger.info("Co2Controller: output_max=#{value}")
    %{state | output_limits: new_limits}
  end

  defp apply_command("enable", 1, state) do
    Store.put(:enabled, true)
    Logger.info("Co2Controller: enabled")
    %{state | enabled: true}
  end

  defp apply_command("disable", 1, state) do
    Store.put(:enabled, false)
    Logger.info("Co2Controller: disabled")
    %{state | enabled: false}
  end

  defp apply_command("set_relay_low", value, state) when is_number(value) do
    relay_low = round(value)
    Store.put(:relay_low, relay_low)
    Logger.info("Co2Controller: relay_low=#{relay_low}")
    %{state | relay_low: relay_low}
  end

  defp apply_command("set_relay_high", value, state) when is_number(value) do
    relay_high = round(value)
    Store.put(:relay_high, relay_high)
    Logger.info("Co2Controller: relay_high=#{relay_high}")
    %{state | relay_high: relay_high}
  end

  defp apply_command("start_autotune", 1, state) do
    Logger.info("Co2Controller: starting autotune — relay #{state.relay_low}–#{state.relay_high}")

    tuner = AutoTuner.new(relay_low: state.relay_low, relay_high: state.relay_high)
    %{state | autotune: tuner}
  end

  defp apply_command("stop_autotune", 1, state) do
    Logger.info("Co2Controller: autotune cancelled")
    %{state | autotune: nil}
  end

  defp apply_command(key, _value, state) do
    Logger.debug("Co2Controller: unknown command #{key}")
    state
  end

  # Helpers

  defp reset_watchdog(%{watchdog_ref: ref} = state) do
    if ref, do: Process.cancel_timer(ref)
    %{state | watchdog_ref: Process.send_after(self(), :watchdog, @watchdog_ms)}
  end

  defp clamp_to_limits(value, {min_val, max_val})
       when is_number(min_val) and is_number(max_val) do
    value |> max(round(min_val)) |> min(round(max_val))
  end

  defp clamp_to_limits(value, _limits), do: value

  # Conditional anti-windup: freeze integral only when clamping would worsen windup.
  # Allow integral to grow past the low clamp (CO2 high, building toward operating point).
  # Freeze only when the integral is moving in the saturating direction.
  defp antiwindup(raw, {out_min, out_max}, updated, original) do
    clamped_high = raw > out_max
    clamped_low = raw < out_min
    integral_grew = updated.error_sum > original.error_sum

    if (clamped_high and integral_grew) or (clamped_low and not integral_grew),
      do: original,
      else: updated
  end

  # PidController uses setpoint=0; input = setpoint_ppm - co2.
  # Internally: error = 0 - input = co2 - setpoint_ppm → positive when CO2 high → more fan.
  # No output_limits in PidController — we clamp externally and do anti-windup ourselves.
  defp build_controller(kp, ki, last_output, {out_min, out_max}) do
    controller =
      PidController.new(
        kp: kp,
        ki: ki,
        kd: 0.0,
        setpoint: 0.0
      )

    # If last_output is outside the operating range (e.g. stale CubDB value from a
    # previous misconfigured run), seed from the midpoint so the first PWM is ~350
    # rather than waiting for the integral to build up from scratch.
    seed =
      if last_output >= out_min and last_output <= out_max,
        do: last_output,
        else: (out_min + out_max) / 2.0

    reseed_integral(controller, seed, ki)
  end

  # Seed error_sum so integral reproduces target_output at zero error.
  # PidController I term = Ki * (error_sum + error); at error=0: I = Ki * error_sum.
  defp reseed_integral(controller, target_output, ki) when ki > 0.0 do
    %{controller | error_sum: target_output / ki}
  end

  defp reseed_integral(controller, _target_output, _ki), do: controller
end
