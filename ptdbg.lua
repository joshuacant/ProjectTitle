local EventListener = require("ui/widget/eventlistener")
local time = require("ui/time")
local logger = require("logger")

local ptdbg = EventListener:extend{
    start_time = nil
}

ptdbg.enabled = false

ptdbg.logprefix = "Project: Title -"

function ptdbg:init()
    if ptdbg.enabled then
        self.start_time = time.now()
    end
end

function ptdbg:report(description)
    if ptdbg.enabled then
        logger.info(ptdbg.logprefix, description, string.format("done in %.3f", time.to_ms(time.since(self.start_time))))
    end
end

return ptdbg