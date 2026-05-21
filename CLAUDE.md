# CLAUDE.md

## What this project is

Standalone Elixir OTP application implementing a PI controller for mushroom-container climate control. Connects to the same MQTT broker as the gateway. Receives CO2 readings from `scd_2` and publishes PWM setpoints to `pwm_1`.

Run independently of the gateway so it can be restarted, killed, and iterated on without touching the authentication proxy.

## Commands

```bash
mix deps.get              # install dependencies
mix compile               # compile
mix test                  # run tests
mix precommit             # compile --warnings-as-errors, format, credo --strict, test
```

Start against the real broker (credentials via env vars — never commit them):

```bash
MQTT_HOST=192.168.1.182 \
MQTT_USERNAME=svampekompagniet \
MQTT_PASSWORD=HgrIGQ6uSPRG \
iex -S mix
```

Shut down cleanly from the iex shell:

```
System.stop()
```

(Ctrl+C Ctrl+C does the same thing — both trigger a clean OTP shutdown, CubDB flushes, MQTT disconnects.)

## Architecture

```
Pid.Application
  └── Pid.Store           CubDB GenServer — persists params and last_output to priv/pid_state/
  └── Pid.MqttClient      :emqtt GenServer — subscribes to metric/#, publishes cmd/
  └── Pid.Co2Controller   PI GenServer — receives CO2 via PubSub, computes output, sends PWM
```

## MQTT topics

| Direction | Topic | Content |
|---|---|---|
| Subscribe | `metric/drejø/scd_2` | JSON with `co2` key (ppm, integer) |
| Publish | `cmd/drejø/pwm_1` | `{"set_pwm": N}` where N is 0–1023 |
| Subscribe | `cmd/pid/co2` | Tuning commands (see below) |

## Tuning commands (inbound on `cmd/pid/co2`)

| Key | Type | Effect |
|---|---|---|
| `set_kp` | number | Set proportional gain — e.g. `{"set_kp": 0.3}` |
| `set_ki` | number | Set integral gain — e.g. `{"set_ki": 0.001}` |
| `set_setpoint` | integer ppm | CO2 target, default 800 |
| `set_output_min` | number 0–1023 | Lower clamp for PWM output |
| `set_output_max` | number 0–1023 | Upper clamp for PWM output |
| `enable` | 1 | Activate PI loop |
| `disable` | 1 | Halt loop — fan holds last EEPROM value on pwm_1 |
| `set_relay_low` | integer 0–1023 | Lower relay bound for auto-tuner (default 307 = 30%) |
| `set_relay_high` | integer 0–1023 | Upper relay bound for auto-tuner (default 409 = 40%) |
| `start_autotune` | 1 | Start relay auto-tuner (requires `enable` first); applies Kp/Ki on completion |
| `stop_autotune` | 1 | Cancel auto-tuner without applying results |

## Persistence (CubDB)

Keys stored in `priv/pid_state/`:

- `:kp`, `:ki`, `:setpoint`, `:output_min`, `:output_max` — written on every param change
- `:relay_low`, `:relay_high` — auto-tuner relay bounds, written on change (defaults 307/409)
- `:last_output` — written every 10th PI cycle (~10 minutes)
- `:enabled` — written on every change

On startup the controller reads `:last_output` and seeds the integral for bumpless initialisation.

## Code quality

Run after finishing any module:

```bash
mix credo --strict
mix run -e 'code = File.read!("lib/path/to/file.ex"); result = Credence.fix(code); if result.code != code, do: File.write!("lib/path/to/file.ex", result.code)'
```

When credo and credence conflict, credence wins.

## Infrastructure

- MQTT broker: `svampe-server.localdomain` / `192.168.1.182`, port 1883
- MQTT client tool on dev machine: **MQTTX** (mosquitto is not installed)
- Broker requires authentication — always pass `MQTT_USERNAME` and `MQTT_PASSWORD`
- `emqtt` does NOT send a `{:connected, _}` callback after connect; subscription is done synchronously inside the `with` block in `handle_info(:connect, ...)`

## Design notes

- The controller starts with `enabled: false`. Enable explicitly via MQTT once you are confident in the output.
- Watchdog: if no CO2 reading arrives for 5 minutes, the controller logs a warning and holds the last output.
- Anti-windup: if the raw PI output exceeds `[output_min, output_max]`, the integral is frozen (the returned `PidController` struct is discarded and the old one kept).
- No D term. Derivative amplifies sensor noise and reacts badly to the large dead time in the container.
