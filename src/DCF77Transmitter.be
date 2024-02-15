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
  static SEC_SYNC_DURATION = 100 # 100ms

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
      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, # 01: Weather broadcast / Civil warning bits
      0,                                        # 15: Call bit: abnormal transmitter operation
      0,                                        # 16: Summer time announcement. Set during hour before change
      0, 1,                                     # 17: 01=CET, 10=CEST
      0,                                        # 19: Leap second announcement. Set during hour before leap second
      1,                                        # 20: Start of encoded time
      0, 0, 0, 0, 0, 0, 0, 0,                   # 21: Minutes (7bit + parity, 00-59)
      0, 0, 0, 0, 0, 0, 0,                      # 29: Hours (6bit + parity, 0-23)
      0, 0, 0, 0, 0, 0,                         # 36: Day of month (6bit, 1-31)
      0, 0, 0,                                  # 42: Day of week (3bit, 1-7, Monday=1)
      0, 0, 0, 0, 0,                            # 45: Month number (5bit, 1-12)
      0, 0, 0, 0, 0, 0, 0, 0, 0,                # 50: Year within century (8bit + parity, 00-99)
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

  def encode_bcd(start, len, val)
    var byte = ((val / 10) << 4) + (val % 10)
    for bit: 0..len-1
      self.dcf77_bits[start + bit] = (byte >> bit) & 1
    end
  end

  def even_parity(start, len)
    var parity = 0
    for bit: 0..len-1
      parity ^= self.dcf77_bits[start + bit] & 1
    end
    self.dcf77_bits[start + len] = parity
  end

  def dcf77_dump()
    var res = ""
    for bit: 0..58
      if [1, 15, 21, 29, 36, 42, 45, 50].find(bit) != nil
        res += "-"
      end
      res += string.char(string.byte('0') + self.dcf77_bits[bit])
    end
    return res
  end

  def set_dcf77_time(time)
    var time_dump = tasmota.time_dump(time)
    self.encode_bcd(self.DST_BIT, 2, self.dcf77_dst  ? 1 : 2)
    self.encode_bcd(self.MIN_BIT, 7, time_dump["min"])
    self.even_parity(self.MIN_BIT, 7)
    self.encode_bcd(self.HOUR_BIT, 6, time_dump["hour"])
    self.even_parity(self.HOUR_BIT, 6)
    self.encode_bcd(self.DAY_BIT, 6, time_dump["day"])
    self.encode_bcd(self.WEEKDAY_BIT, 3, time_dump["weekday"] == 0 ? 7 : time_dump["weekday"])
    self.encode_bcd(self.MONTH_BIT, 5, time_dump["month"])
    self.encode_bcd(self.YEAR_BIT, 8, time_dump["year"]% 100)
    self.even_parity(self.DAY_BIT, 22)
  end

  def display_time(local_time)
    if self.clock_label
      var time_txt = tasmota.strftime("%H:%M:%S", local_time)
      if time_txt[0] == '0'
        time_txt = ' ' .. string.split(time_txt,1)[1] # erase leading zero
      end
      self.clock_label.set_text(time_txt)
    end
    if local_time % 60 == 0
      var dcf77_time = tasmota.strftime("%a %d.%m.%y %H:%M", local_time + self.dcf77_offset)
      var dcf77_tz = self.dcf77_dst ? 'CEST' : 'CET'
      print(f"DCF: {dcf77_time} {dcf77_tz}: {self.dcf77_dump()}")
    end
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
      rtc_utc = tasmota.rtc_utc()
      millis = tasmota.millis()
    end

    var sec = rtc_utc % 60
    if sec < 59
      gpio.set_pwm(gpio.pin(gpio.PWM1), self.PWM_OFF)
      var pwm_silence = self.dcf77_bits[sec] ? 200 : 100
      self.pwm_millis = millis + pwm_silence
      tasmota.set_timer(pwm_silence - self.PWM_SYNC_DURATION, /-> self.pwm_timer(),"pwm_timer")
    end

    var local_time = tasmota.rtc()["local"]

    if sec == 59 # prepare next time code
      self.set_dcf77_time(local_time + 1 + self.dcf77_offset)
    end

    var sync_duration = millis - millis_start
    if sync_duration > self.SEC_SYNC_DURATION
      print(f"DCF: Out of sync")
    end

    self.display_time(local_time)

    var next_second = 1000 - (tasmota.millis() - millis)
    tasmota.set_timer(next_second - self.SEC_SYNC_DURATION, /-> self.seconds_timer(), "seconds_timer")
  end
end

return DCF77Transmitter
