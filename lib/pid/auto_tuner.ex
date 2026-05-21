defmodule Pid.AutoTuner do
  @moduledoc false

  # Relay-feedback (Åström-Hägglund) auto-tuner.
  # Drives the output with a bang-bang relay and measures the ultimate gain Ku
  # and period Tu from the resulting limit cycle, then returns Ziegler-Nichols
  # PI parameters: Kp = 0.45*Ku, Ki = Kp*1.2/Tu_steps.

  @max_steps 300

  defstruct [
    :relay_high,
    :relay_low,
    :hysteresis,
    :min_full_cycles,
    step: 0,
    crossings: [],
    peaks: [],
    current_peak: 0,
    last_output: nil
  ]

  def new(opts \\ []) do
    %__MODULE__{
      relay_high: Keyword.get(opts, :relay_high, 409),
      relay_low: Keyword.get(opts, :relay_low, 307),
      hysteresis: Keyword.get(opts, :hysteresis, 20),
      min_full_cycles: Keyword.get(opts, :min_full_cycles, 3)
    }
  end

  @doc "Feed one error sample. Returns {output, updated_tuner, :running | {:done, kp, ki} | :timeout}."
  def step(error, tuner) do
    tuner = %{tuner | step: tuner.step + 1}
    output = relay_output(error, tuner)
    tuner = record_step(output, error, tuner)
    {round(output), tuner, status(tuner)}
  end

  defp relay_output(_error, %{last_output: nil, relay_high: high}), do: high
  defp relay_output(error, %{relay_high: high, hysteresis: h}) when error > h, do: high
  defp relay_output(error, %{relay_low: low, hysteresis: h}) when error < -h, do: low
  defp relay_output(_error, %{last_output: last}), do: last

  defp record_step(output, error, tuner) do
    peak = max(tuner.current_peak, abs(error))

    if output != tuner.last_output and not is_nil(tuner.last_output) do
      %{
        tuner
        | crossings: [tuner.step | tuner.crossings],
          peaks: [peak | tuner.peaks],
          current_peak: 0,
          last_output: output
      }
    else
      %{tuner | current_peak: peak, last_output: output}
    end
  end

  defp status(%{step: step}) when step >= @max_steps, do: :timeout

  defp status(tuner) do
    if length(tuner.crossings) >= tuner.min_full_cycles * 2 + 1 do
      compute_result(tuner)
    else
      :running
    end
  end

  defp compute_result(tuner) do
    half_periods =
      tuner.crossings
      |> Enum.reverse()
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [a, b] -> b - a end)

    full_periods =
      half_periods
      |> Enum.chunk_every(2, 2, :discard)
      |> Enum.map(fn [a, b] -> a + b end)

    {sum, count} = Enum.reduce(full_periods, {0, 0}, fn x, {s, c} -> {s + x, c + 1} end)
    tu = sum / count

    amps = tuner.peaks |> Enum.reverse() |> Enum.drop(1)
    {sum, count} = Enum.reduce(amps, {0, 0}, fn x, {s, c} -> {s + x, c + 1} end)
    a = sum / count

    d = (tuner.relay_high - tuner.relay_low) / 2.0
    ku = 4.0 * d / (:math.pi() * a)

    kp = 0.45 * ku
    ki = kp * 1.2 / tu

    {:done, kp, ki}
  end
end
