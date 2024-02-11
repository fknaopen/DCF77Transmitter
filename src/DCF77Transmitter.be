import string
import persist

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
  var dcf77_offset
  var dcf77_dst
  var dcf77_bits
  var sec

  def init()
    self.localtime_offset = persist.find('localtime_offset', 0) # adjust every_second() time
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

    tasmota.cmd(f"PWMFrequency {self.PWM_FREQENCY}",true)
    tasmota.cmd(f"PWMRange {self.PWM_RANGE}",true)

    var localtime = tasmota.rtc()["local"] + self.localtime_offset
    self.sec = tasmota.time_dump(localtime)["sec"]
    self.set_dcf77_time(localtime)

    tasmota.add_driver(self)
  end

  def deinit()
    self.del()
  end

  def del()
    tasmota.remove_driver(self)
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

  def set_dcf77_time(localtime)
    var dcf77 = localtime + self.dcf77_offset
    var time_dump = tasmota.time_dump(dcf77)
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
    var dcf77_time = tasmota.strftime("%a %d.%m.%y %H:%M", dcf77)
    var dcf77_tz = self.dcf77_dst ? 'CEST' : 'CET'
    print(f"DCF77: {dcf77_time} {dcf77_tz}: {self.dcf77_dump()}")
  end

  def every_second()
    if self.sec < 59
      gpio.set_pwm(gpio.pin(gpio.PWM1), self.PWM_OFF)
      var stop_millis = tasmota.millis()
      var bit = self.dcf77_bits[self.sec]
      var start_millis = stop_millis + (bit ? 200 : 100)
      while !tasmota.time_reached(start_millis)
        tasmota.delay(2)
      end
      gpio.set_pwm(gpio.pin(gpio.PWM1), self.PWM_ON)
      self.sec += 1
    else
      var time = tasmota.rtc()["local"] + self.localtime_offset
      var str_time = tasmota.strftime("%H:%M:%S", time + 1)
      self.set_dcf77_time(time + 1)
      self.sec = 0;
    end
  end
end

return DCF77Transmitter
