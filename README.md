## General 

Simulates the [DCF77](https://en.wikipedia.org/wiki/DCF77) time code signal on a GPIO pin. It uses PWM with carrier frequency set to 25.833 kHz (third harmonic) as Tasmota limits the max PWM frequency to 50kHz (look for `PWM_MAX` in the source code).

## Installation
Upload the Tasmota appication `DCF77Transmitter.tapp` to the file system and reboot. The application run in the background and the transmitted data is written in the logs:

```
DCF77: Sun 04.02.24 16:02 CET: 0-00000000000000-000101-00100001-0110101-001000-111-01000-001001001
```

To build manually, execute following in the repo directory
```
rm -f DCF77Transmitter.tapp; zip -j -0 DCF77Transmitter.tapp src/*.be
```
## Configuration
The signal is submitted to the first configured PWM pin, check with: `gpio.pin(gpio.PWM1)` 

Following parameter could be configured in the `persist` module:

`dcf77_time_offset` - boolean (default: 0): Specify the time offset of the transmitted time (by default next minute)

`dcf77_dst` - integer (default: false): By default the local time is submitted as CET. Set to `true` to submit it as CEST.

## Antenna
Best results are achieved if you connect a ferrite antenna over 330 ohm resistor and a capactior to ground.

It also works with analog beeper or even with a led connected to the GPIO pin. 

Normally the clock gets syncrhonized in about two minutes depending on the distance and signal strength.
