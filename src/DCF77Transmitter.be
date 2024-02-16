import string
import persist
import introspect
import math

# https://en.wikipedia.org/wiki/DCF77
# https://www.dcf77logs.de/live

class DCF77Transmitter
  static PWM_FREQENCY = 25833 # 77.5 / 3
  static PWM_RANGE = 255
  static PWM_ON = 127
  static PWM_OFF = 0

  static PWM_SYNC_DURATION = 50 # 50ms
  static SEC_SYNC_DURATION = 80 # 80ms

  static DST_BIT = 17
  static MIN_BIT = 21
  static HOUR_BIT = 29
  static DAY_BIT = 36
  static WEEKDAY_BIT = 42
  static MONTH_BIT = 45
  static YEAR_BIT = 50

  var dcf77_offset, dcf77_dst, dcf77_bits
  var pwm_millis
  var lv, clock_label

  def init()
    if gpio.pin(gpio.PWM1) < 0
      print("DCF: PWM pin not configured.")
      return
    end

    self.lv = introspect.module("lv")
    if self.lv != nil
      self.lv.start()
      var scr = self.lv.scr_act()
      self.clock_label = self.lv.label(scr)
      self.clock_label.set_text("--:--:--")
      self.clock_label.set_align(self.lv.ALIGN_CENTER)
      self.clock_label.set_style_text_font(self.lv.seg7_font(36), self.lv.PART_MAIN | self.lv.STATE_DEFAULT)
      self.clock_label.set_style_text_color(self.lv.color(self.lv.COLOR_WHITE), self.lv.PART_MAIN | self.lv.STATE_DEFAULT)
    end

    self.dcf77_offset = persist.find('dcf77_offset', 60) # submit next minute
    self.dcf77_dst = persist.find('dcf77_dst', false)
    self.dcf77_bits = [
      0,                                        # 00: Start of minute
      8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, # 01: Weather broadcast / Civil warning bits
      8,                                        # 15: Call bit: abnormal transmitter operation
      0,                                        # 16: Summer time announcement. Set during hour before change
      0, 1,                                     # 17: 01=CET, 10=CEST
      0,                                        # 19: Leap second announcement. Set during hour before leap second
      1,                                        # 20: Start of encoded time
      8, 0, 0, 0, 0, 0, 0, 0,                   # 21: Minutes (7bit + parity, 00-59)
      8, 0, 0, 0, 0, 0, 0,                      # 29: Hours (6bit + parity, 0-23)
      8, 0, 0, 0, 0, 0,                         # 36: Day of month (6bit, 1-31)
      8, 0, 0,                                  # 42: Day of week (3bit, 1-7, Monday=1)
      8, 0, 0, 0, 0,                            # 45: Month number (5bit, 1-12)
      8, 0, 0, 0, 0, 0, 0, 0, 0,                # 50: Year within century (8bit + parity, 00-99)
      0                                         # 59: Not used
    ]
    self.pwm_millis = 0

    tasmota.cmd(f"PWMFrequency {self.PWM_FREQENCY}",true)
    tasmota.cmd(f"PWMRange {self.PWM_RANGE}",true)

    tasmota.set_timer(100, /-> self.seconds_timer(), "seconds_timer")
  end

  def deinit()
    self.del()
  end

  def del()
    if self.clock_label
      self.clock_label.del()
    end
    tasmota.remove_timer("pwm_timer")
    tasmota.remove_timer("seconds_timer")
  end

  def dcf77_encode(start, len, val, par)
    var parity = (par == nil ? self.dcf77_bits[start] : par) & 1
    var byte = ((val / 10) << 4) + (val % 10)
    for bit: 0..len-1
      var dcf77_bit = (byte >> bit) & 1
      parity ^= dcf77_bit
      self.dcf77_bits[start + bit] = (self.dcf77_bits[start + bit] & 0xE) + dcf77_bit
    end
    self.dcf77_bits[start + len] = (self.dcf77_bits[start + len] & 0xE) + (parity & 1)
  end

  def pwm_timer()
    while !tasmota.time_reached(self.pwm_millis)
      tasmota.delay_microseconds(100)
    end
    gpio.set_pwm(gpio.pin(gpio.PWM1), self.PWM_ON)
  end

  def seconds_timer()
    var rtc_utc = tasmota.rtc_utc()
    var rtc_utc_start = rtc_utc
    var millis = tasmota.millis()
    var millis_start = millis
    while rtc_utc == rtc_utc_start # wait next second
      millis = tasmota.millis()
      rtc_utc = tasmota.rtc_utc()
    end

    var sec = rtc_utc % 60
    if sec < 59
      gpio.set_pwm(gpio.pin(gpio.PWM1), self.PWM_OFF)
      var pwm_silence = self.dcf77_bits[sec] & 1 ? 200 : 100
      self.pwm_millis = millis + pwm_silence
      tasmota.set_timer(pwm_silence - self.PWM_SYNC_DURATION, /-> self.pwm_timer(),"pwm_timer")
    end

    var local_time = tasmota.rtc()["local"]

    if sec == 59 # prepare next time code
      var time_dump = tasmota.time_dump(local_time + 1 + self.dcf77_offset)
      self.dcf77_encode(self.DST_BIT, 2, self.dcf77_dst  ? 1 : 2, 1) # parity = leap second -> 0
      self.dcf77_encode(self.MIN_BIT, 7, time_dump["min"], 0)
      self.dcf77_encode(self.HOUR_BIT, 6, time_dump["hour"], 0)
      self.dcf77_encode(self.DAY_BIT, 6, time_dump["day"], 0)
      self.dcf77_encode(self.WEEKDAY_BIT, 3, time_dump["weekday"] == 0 ? 7 : time_dump["weekday"])
      self.dcf77_encode(self.MONTH_BIT, 5, time_dump["month"])
      self.dcf77_encode(self.YEAR_BIT, 8, time_dump["year"]% 100)
    end

    if self.clock_label
      var time_dump = tasmota.time_dump(local_time)
      self.clock_label.set_text(f"{time_dump['hour']}:{time_dump['min']:02d}:{time_dump['sec']:02d}")
    end

    if local_time % 60 == 0
      var dcf77_time = tasmota.strftime(f"%a %d.%m.%y %H:%M ", local_time + self.dcf77_offset)
      dcf77_time += (self.dcf77_dst ? "CEST" : "CET") + ": "
      for bit: 0..58
        dcf77_time += (self.dcf77_bits[bit] & 8 ? "-" : "") + string.char(string.byte('0') + (self.dcf77_bits[bit] & 1))
      end
      print(f"DCF: {dcf77_time}")
    end

    if (millis - millis_start) > self.SEC_SYNC_DURATION
      print(f"DCF: Out of sync")
    end

    var next_second = 1000 - (tasmota.millis() - millis)
    tasmota.set_timer(next_second - self.SEC_SYNC_DURATION, /-> self.seconds_timer(), "seconds_timer")
  end
end

return DCF77Transmitter
