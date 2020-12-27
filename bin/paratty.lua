local ptty = require("ptty")
local component = require("component")
local event = require("event")
--event.handlers = {}
local process = require("process")

local args = {...}

local stream = ptty.new(component.gpu, component.screen.address)

local function init()
  return table.unpack(args, 2)
end
local new = process.load(args[1], nil, init)
process.info(new).data.io[0] = stream
process.info(new).data.io[1] = stream
process.info(new).data.io[2] = stream
process.closeOnExit(stream)

while coroutine.status(new) ~= "dead" do
  coroutine.yield(coroutine.resume(new))
end

