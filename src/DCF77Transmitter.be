import string
import persist

# https://en.wikipedia.org/wiki/DCF77
# https://www.dcf77logs.de/live

class DCF77Transmitter
  static PWM_FREQENCY = 25833 # 77.5 / 3
  static PWM_RANGE = 255
  static PWM_ON = 127
  static PWM_OFF = 0

  var dcf77_time_offset
  var dcf77_dst
  var dcf77_bits
  var sec

  def init()
    self.dcf77_time_offset = persist.find('dcf77_time_offset', 0)
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
      0, 0, 0, 0, 0,                            # 36: Day of month (6bit, 1-31)
      0, 0, 0,                                  # 42: Day of week (3bit, 1-7, Monday=1)
      0, 0, 0, 0, 0,                            # 45: Month number (5bit, 1-12)
      0, 0, 0, 0, 0, 0, 0, 0, 0, 0,             # 50: Year within century (8bit + parity, 00-99)
      -1                                        # 59: Not used
    ]

    tasmota.cmd(f"PWMFrequency {self.PWM_FREQENCY}",true)
    tasmota.cmd(f"PWMRange {self.PWM_RANGE}",true)
    self.set_time()

    tasmota.add_driver(self)
  end

  def deinit()
    self.del()
  end

  def del()
    tasmota.remove_driver(self)
  end

  def encode_bcd(val, start, len)
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

  def dcf77_encode(tH, tM, dW, dD, dM, dY, dst)
    self.encode_bcd(dst, 17, 2)
    self.encode_bcd(tM, 21, 7)
    self.even_parity(21, 7)
    self.encode_bcd(tH, 29, 6)
    self.even_parity(29, 6)
    self.encode_bcd(dD, 36, 6)
    self.encode_bcd(dW, 42, 3)
    self.encode_bcd(dM, 45, 5)
    self.encode_bcd(dY, 50, 8)
    self.even_parity(36, 22)
  end

  def dcf77_dump()
    var res = ""
    for i: 0..58
      if [1, 15, 21, 29, 36, 42, 45, 50].find(i) != nil
        res += "-"
      end
      res += string.char(string.byte('0') + self.dcf77_bits[i])
    end
    return res
  end

  def set_time()
    var rtc = tasmota.rtc()["local"] + self.dcf77_time_offset
    self.sec = tasmota.time_dump(rtc)["sec"]
    var time = tasmota.time_dump(rtc+60-self.sec) # transmit next minute
    var tH = time["hour"]
    var tM = time["min"]
    var dW = time["weekday"]
    var dD = time["day"]
    var dM = time["month"]
    var dY = time["year"]
    self.dcf77_encode(tH, tM, dW == 0 ? 7 : dW, dD, dM, dY % 100, self.dcf77_dst  ? 1 : 2)
    var timestr = tasmota.strftime("%a %d.%m.%y %H:%M",tasmota.rtc()["local"])
    print(format("DCF77: %s %s: %s",timestr,self.dcf77_dst ? "CEST" : "CET",self.dcf77_dump()))
  end

  def every_second()
    if self.sec < 59
      gpio.set_pwm(gpio.pin(gpio.PWM1), self.PWM_OFF)
      var start = tasmota.millis()
      var bit = self.dcf77_bits[self.sec]
      var stop = start + (bit ? 200 : 100)
      while !tasmota.time_reached(stop)
        tasmota.delay(5)
      end
      gpio.set_pwm(gpio.pin(gpio.PWM1), self.PWM_ON)
      self.sec += 1
    else
      self.set_time()
    end
  end
end

return DCF77Transmitter
