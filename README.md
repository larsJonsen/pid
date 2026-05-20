# pid

Elixir OTP application implementing a PI controller for CO2 levels in mushroom-growing containers. Receives CO2 readings from an MQTT sensor device, computes a PWM fan setpoint, and publishes it back over MQTT. Designed to run alongside the gateway on the same broker.

## How it works

The container CO2 level is measured by the `scd_2` sensor device. The controller subscribes to those readings, computes a PI correction against the target setpoint (default 800 ppm), and sends a PWM value (0–1023) to the `pwm_1` fan controller.

The controller starts **disabled**. Enable it explicitly via MQTT once you are confident the output is reasonable.

All parameters and the last PWM output are persisted to disk (CubDB). On restart the integral is seeded from `last_output` so the fan resumes at the correct position without a bump.

## Prerequisites

- Elixir ≥ 1.18 / Erlang OTP
- An MQTT broker reachable on the network
- `scd_2` and `pwm_1` devices publishing/subscribing to the expected topics

## Getting started

```bash
mix deps.get
iex -S mix          # start with interactive shell — preferred during tuning
```

The application connects to `localhost:1883` by default (see Configuration below).

## Configuration

All settings have defaults for local development. Override via environment variables in production:

| Variable | Default | Description |
|---|---|---|
| `MQTT_HOST` | `localhost` | MQTT broker hostname or IP |
| `MQTT_PORT` | `1883` | MQTT broker port |
| `MQTT_GROUP` | `drejø` | Device group name used in topic paths |
| `MQTT_CO2_DEVICE` | `scd_2` | CO2 sensor device name |
| `MQTT_PWM_DEVICE` | `pwm_1` | Fan PWM controller device name |
| `PID_STATE_DIR` | `priv/pid_state` | Directory for CubDB state files |

## MQTT topics

| Direction | Topic | Payload |
|---|---|---|
| Subscribe | `metric/<group>/<co2_device>` | `{"metric": "co2", "value": 850, ...}` |
| Publish | `cmd/<group>/<pwm_device>` | `{"set_pwm": 512}` |
| Subscribe | `cmd/pid/co2` | Tuning commands (see below) |

With default config: `metric/drejø/scd_2`, `cmd/drejø/pwm_1`.

## Tuning commands

Send JSON to `cmd/pid/co2`. Multiple keys in one message are applied in order.

| Key | Value | Effect |
|---|---|---|
| `set_setpoint` | integer ppm | CO2 target — default 800 |
| `set_kp` | number | Proportional gain |
| `set_ki` | number | Integral gain (per CO2 reading) |
| `set_output_min` | number 0–1023 | Lower PWM clamp |
| `set_output_max` | number 0–1023 | Upper PWM clamp |
| `enable` | `1` | Start the PI loop |
| `disable` | `1` | Stop the loop — fan holds its last value |
| `start_autotune` | `1` | Start relay auto-tuner (controller must be enabled) |
| `stop_autotune` | `1` | Cancel auto-tuner without applying results |

Example — set a conservative setpoint and low gains, then enable:

```sh
mosquitto_pub -t cmd/pid/co2 -m '{"set_setpoint": 900, "set_kp": 0.3, "set_ki": 0.001, "enable": 1}'
```

## Manual tuning

The container has a large dead time and slow response, so start with proportional-only control and observe behaviour before adding integral action.

1. Disable the controller, set `output_min` and `output_max` to safe limits.
2. Set `set_kp` to a small value (e.g. 0.2) with `set_ki` at 0.
3. Enable and watch the CO2 trend in the logs. Increase `set_kp` until the fan responds clearly without oscillating.
4. Add a small `set_ki` (e.g. 0.001) to eliminate steady-state error. Too large causes slow oscillation.

## Auto-tuning

The relay auto-tuner uses the Åström–Hägglund relay-feedback method to estimate the ultimate gain and period of the system, then applies Ziegler–Nichols PI parameters automatically.

**Steps:**

1. Enable the controller first: `{"enable": 1}`
2. Start the tuner: `{"start_autotune": 1}`

The fan will oscillate between PWM 100 and 800 for 3 complete CO2 cycles. Given the slow container dynamics, expect this to take 1–3 hours. When complete, the computed `Kp` and `Ki` are applied and persisted automatically, and the controller switches back to normal PI mode.

Cancel at any time with `{"stop_autotune": 1}` — the last relay output is held until the next CO2 reading.

If the system fails to produce a detectable oscillation within 300 readings, the tuner times out and the previous parameters are kept.

## Architecture

```
Pid.Application
  └── Pid.Store           CubDB — persists parameters and last_output to disk
  └── Pid.MqttClient      emqtt GenServer — subscribes metric/# and cmd/pid/co2,
  │                                         publishes cmd/<group>/<pwm_device>
  └── Pid.Co2Controller   PI GenServer — computes PWM on each CO2 reading
        └── Pid.AutoTuner pure functional relay-feedback tuner (no separate process)
```

The three GenServers are supervised under a `:one_for_one` strategy. `Store` must start first since `Co2Controller` reads persisted state during `init/1`. `MqttClient` is independent — a broker outage does not affect the controller state, only publishing.

## Watchdog

If no CO2 reading arrives for 5 minutes, the controller logs a warning and holds the last PWM output. The integral is not advanced during the silence.

## Development

```bash
mix test              # run unit tests
mix precommit         # compile --warnings-as-errors, format, credo --strict, test
```
