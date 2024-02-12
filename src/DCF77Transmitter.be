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

  static DST_BIT = 17
  static MIN_BIT = 21
  static HOUR_BIT = 29
  static DAY_BIT = 36
  static WEEKDAY_BIT = 42
  static MONTH_BIT = 45
  static YEAR_BIT = 50

  var localtime_offset
  var dcf77_offset, dcf77_dst, dcf77_bits
  var rtc, rtc_millis, on_millis, off_millis
  var lv, clock_label

  def init()
    if gpio.pin(gpio.PWM1) < 0
      print("DCF77: PWM pin not configured.")
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

    self.localtime_offset = persist.find('localtime_offset', 0) # adjust localtime difference
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
    self.rtc = 0
    self.rtc_millis = 0
    self.on_millis = 0
    self.off_millis = 0

    tasmota.cmd(f"PWMFrequency {self.PWM_FREQENCY}",true)
    tasmota.cmd(f"PWMRange {self.PWM_RANGE}",true)

    self.sync_time()
    self.set_dcf77_time(self.rtc + self.dcf77_offset) # next minute

    tasmota.set_timer(700, /-> self.pwm_off_timer(), "pwm_off_timer")
  end

  def deinit()
    self.del()
  end

  def del()
    if self.clock_label
      self.clock_label.del()
    end
    tasmota.remove_timer("pwm_on_timer")
    tasmota.remove_timer("pwm_off_timer")
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
    var dcf77_time = tasmota.strftime("%a %d.%m.%y %H:%M", time)
    var dcf77_tz = self.dcf77_dst ? 'CEST' : 'CET'
    print(f"DCF: {dcf77_time} {dcf77_tz}: {self.dcf77_dump()}")
  end

  def sync_time()
    var rtc = tasmota.rtc_utc()
    while rtc != tasmota.rtc_utc()
      tasmota.delay_microseconds(500)
      tasmota.yield()
      rtc = tasmota.rtc_utc()
    end
    var millis = tasmota.millis()
    self.rtc_millis = millis
    self.off_millis = millis + 1000
    self.rtc = tasmota.rtc()["local"] + self.localtime_offset
  end

  def pwm_on_timer()
    while !tasmota.time_reached(self.on_millis)
      tasmota.delay_microseconds(500)
      tasmota.yield()
    end
    gpio.set_pwm(gpio.pin(gpio.PWM1), self.PWM_ON)
  end

  def pwm_off_timer()
    while !tasmota.time_reached(self.off_millis)
      tasmota.delay_microseconds(500)
      tasmota.yield()
    end
    var millis = tasmota.millis()

    self.rtc += 1
    var sec = self.rtc % 60
    if sec < 59
      gpio.set_pwm(gpio.pin(gpio.PWM1), self.PWM_OFF)
      var dly = self.dcf77_bits[sec] ? 200 : 100
      self.on_millis = millis + dly
      tasmota.set_timer(dly - 50, /-> self.pwm_on_timer(),"pwm_on_timer")
    else
      self.set_dcf77_time(self.rtc + 1 + self.dcf77_offset) # set next minute
    end

    var sec_diff = tasmota.rtc()["local"] + self.localtime_offset - self.rtc
    var ms_diff = 1000 - (millis - self.rtc_millis)
    self.rtc_millis = millis

    if math.abs(sec_diff) > 1
      if math.abs(sec_diff) > 10
        print(f"DCF: Updating time")
      else
        print(f"DCF: Out of sync: {sec_diff}s")
      end
      self.sync_time()
    elif math.abs(ms_diff) > 10
      print(f"DCF: Out of sync: {ms_diff}ms")
      self.sync_time()
    else
      self.off_millis = millis + 1000
    end

    if self.clock_label
      self.clock_label.set_text(tasmota.strftime("%H:%M:%S", self.rtc))
    end

    tasmota.set_timer(700, /-> self.pwm_off_timer(), "pwm_off_timer")
  end
end

return DCF77Transmitter
