-- WARNING! NexaOS/autorun.lua is different from OpenOS's autorun.lua and should be used for system variables
-- because it is executed when shin32 library is first loaded (when fuchas is loading).
local sys = require("shin32").getenvs()

sys["PATH"] = "A:/;A:/NexaOS/;A:/Users/Shared/;A:/NexaOS/Binaries/;A:/Users/Shared/Binaries"
sys["PATHEXT"] = ".lua"
sys["LIB_PATH"] = "A:/NexaOS/Libraries/?.lua;A:/Users/Shared/Libraries/?.lua;./?.lua;A:/?.lua"
sys["DRV_PATH"] = "A:/NexaOS/Drivers/;A:/Users/Shared/Drivers/"