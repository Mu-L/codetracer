#!/usr/bin/env ruby
# HCR flow test -- pre/post reload variable verification.

require 'fileutils'
require_relative 'mymodule'

counter = 0
history = []

12.times do
  counter += 1
  if counter == 7
    FileUtils.cp(
      File.join(__dir__, 'mymodule_v2.rb'),
      File.join(__dir__, 'mymodule.rb')
    )
    load File.join(__dir__, 'mymodule.rb')
  end
  value = compute(counter)                       # line 20: breakpoint target
  delta = transform(value, counter)
  history.push(delta)
  total = aggregate(history)
  puts "step=#{counter} value=#{value} delta=#{delta} total=#{total}"
end
