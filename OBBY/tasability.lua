-- PC Version only!

-- Config
local FPS = 120 -- Client FPS cap. This can be higher than the TAS recording/playback FPS.
local TASRecordingFPS = 60 -- TAS samples recorded per second. Client FPS can be higher. Playback uses this saved FPS.
local PlaybackInputs = true -- Sets if you want replays to playback your inputs when playing them (AHK connection is required for mouse scroll playback)
local PlaybackMouseLocation = true -- Sets if you want replays to move your mouse when playing them (glitchy when loading checkpoints)
local RoundDigits = 15 -- Rounds all numbers when writing, to greatly decrease file size (set to 50 to disable rounding)
local ReplayStartTime = 1 -- Number of seconds to wait before starting to read the replay
local FrameBacktrackCount = 1000 -- Number of frames to backtrack when frozen to see which keys are currently pressed. Increase as much as your computer can handle
local MinimumJSONFPS = 1/60 -- Lowest you want your FPS to go while encoding/decoding (higher = faster encoding/decoding, lower = better fps) 1/30: 30 fps, 1/60: 60 fps\
local BypassAntiExploit = false -- If this is true games with anti cheat (like beans) will not kick you, but there is a chance animations will be broken

-- Inputs that will not be recorded
local InputBlacklist = {
	["Q"] = true;
	["T"] = true;
	["F"] = true;
	["G"] = true;
	["E"] = true;
	["U"] = true;
	["Z"] = true;
	["R"] = true;
	["V"] = true;
}

-- Color codes for the color code frame
local ColorCodes = {
	WaitingForInput = Color3.new(1,1,0);
	Recording = Color3.new(1,0,0);
	Reading = Color3.new(0,0,5,1);
	Idle = Color3.new(1,1,1);
	Frozen = Color3.new(0,1,1);
	
	None = Color3.new(0,0,0);
}

-- data roblox cursor xD
local Cursors = {
	["ArrowFarCursor"] = {
		Icon = "rbxasset://textures/Cursors/KeyboardMouse/ArrowFarCursor.png";
		Size = UDim2.fromOffset(64,64);
		Offset = Vector2.new(4, 4);
	};
	["MouseLockedCursor"] = {
		Icon = "rbxasset://textures/MouseLockedCursor.png";
		Size = UDim2.fromOffset(32,32);
		Offset = Vector2.new(-16,-16);
	};
}

-- Constants
local Version = "V1.2.5-TAS5"
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local Player = game.Players.LocalPlayer
local Mouse = Player:GetMouse()
local random = math.random
local min = math.min
local max = math.max
local floor = math.floor
local ceil = math.ceil
local ReplayFileBeginning = "{\"Replay\":"
local ReplayFileEnding = "}"
local PlayerModule = Player.PlayerScripts:WaitForChild("PlayerModule")
local ShiftLockBoundKeys = PlayerModule:WaitForChild("CameraModule"):WaitForChild("MouseLockController"):WaitForChild("BoundKeys")
local ShiftLockEnabled = false
local GuiInset = GuiService:GetGuiInset()

-- Variables
local pathVisualsEnabled = false
local pathLines = {}
local pathStartText = nil
local pathEndText = nil
local PlaybackPressedKeys = {}
local ReplayNeedsReload = true -- Flag to track if we need to reload from file
local LastLoadedPath = nil -- Track which file was last loaded
local ExecutionTick = tick()
local PlaceId = game.PlaceId
-- These will be set later --
local Character = nil
local Humanoid = nil
local RootPart = nil
local DefaultGravity = nil
local DefaultJumpPower = nil
local DefaultWalkSpeed = nil
local Resolution = nil
local ConsoleMessage = print
-----------------------------
local Reading = false
local Paused = false 
local Writing = false
local Saving = false
local AnimateDisabled = false
local Checkpoints = {}
local RenderSteppedConnections = {}
local SteppedConnections = {}
local FolderPath = "Tasability\\"..tostring(PlaceId)
local ReplayPath = FolderPath.."\\Replay.tas"
if isfolder(FolderPath) then
    local legacyReplayPath = nil
    for _, filePath in ipairs(listfiles(FolderPath)) do
        if type(filePath) == "string" then
            local lowerPath = filePath:lower()
            if lowerPath:sub(-4) == ".tas" then
                ReplayPath = filePath
                break
            elseif lowerPath:sub(-5) == ".json" and not legacyReplayPath then
                legacyReplayPath = filePath
            end
        end
    end
    if not isfile(ReplayPath) and legacyReplayPath then
        ReplayPath = legacyReplayPath
    end
end
local AHKConnectionFolderPath = "Replayability+_AHK"
local AHKConnectionRequestPath = "Replayability+_AHK/Request"
local ReplayTable = {} -- Should always be used instead of the json string except when encoding or decoding
local RecordingTable = {} -- List of frames that will be added to ReplayTable if recording is saved
local RecordingFPSCapActive = false -- Kept for compatibility; no real FPS cap is applied while recording.
local RecordingReplayFPS = nil -- FPS used by the currently buffered recording.
local ActiveReplayFPS = TASRecordingFPS -- Playback FPS follows the replay recording FPS.
local ReplaySourceFPS = TASRecordingFPS -- FPS the replay data was recorded/saved at.
local TASCompressionLevel = 3 -- Save-only Zstd level. Lower = faster save, higher = smaller file. Playback is unaffected.
local ReplaySaveState = {Version = 0, Encoded = nil, EncodedVersion = -1} -- Save-only cache; never used by playback.
local PlaybackAccumulator = 0 -- Wall-clock accumulator used to pace playback.
local PlaybackSourcePosition = 1 -- Fractional source-frame position for playback resampling.
local RecordingAccumulator = 0 -- Wall-clock accumulator used to pace recording samples.
local ReplayRootWasAnchored = false
local ReplayTableIndex = 0 -- The index in ReplayTable that will be read from
local AnimationQueue = {} -- Functions that were called by the animation script (clear every frame)
local RunSpeed = 0 -- Set in the onRunning function, reset to 0 every frame (AnimationId 2)
local ClimbSpeed = 0 -- Set in the onClimbing function, reset to 0 every frame (AnimationId 4)
local HumanoidStateQueue = {} -- States that were activated on the humanoid (clear every frame)
local InputBeganQueue = {} -- Inputs that have just began (for recording inputs) (clear every frame)
local InputEndedQueue = {} -- Inputs that have just ended (for recording inputs) (clear every frame)
local Cursor = Instance.new("ImageLabel") -- Fake cursor so the icon doesnt change all the time
local CursorIcon = nil -- Icon of the cursor
local CursorSize = nil -- Size of the cursor
local CursorOffset = nil -- Offset of the cursor from UserInputService:GetMouseLocation()
local Dead = false -- If the player is dead this is true
local CameraCFrame = workspace.CurrentCamera.CFrame -- Used when reading so that nothing else can change the camera's CFrame
local Pressed = {} -- Current keys that are pressed
local IgnoreGameProcessed = false -- To ignore GameProcessed in InputBegan, InputChanged, InputEnded

-- Tasability update
local Frozen = false
local FreezeFrame = 1 -- Frame to render while frozen
local SeekDirection = 0 -- Stays 0 normally, -1 when going backwards while frozen, 1 when going fowards
local SeekDirectionMultiplier = 1 -- To go faster or slower when seeking with R and T

-- Converting inputs
-- To add to this table, use https://docs.microsoft.com/en-us/windows/win32/inputdev/virtual-key-codes
local InputCodes = {
	["A"] = 0x41;
	["B"] = 0x42;
	["C"] = 0x43;
	["D"] = 0x44;
	["E"] = 0x45;
	["F"] = 0x46;
	["G"] = 0x47;
	["H"] = 0x48;
	["I"] = 0x49;
	["J"] = 0x4A;
	["K"] = 0x4B;
	["L"] = 0x4C;
	["M"] = 0x4D;
	["N"] = 0x4E;
	["O"] = 0x4F;
	["P"] = 0x50;
	["Q"] = 0x51;
	["R"] = 0x52;
	["S"] = 0x53;
	["T"] = 0x54;
	["U"] = 0x55;
	["V"] = 0x56;
	["W"] = 0x57;
	["X"] = 0x58;
	["Y"] = 0x59;
	["Z"] = 0x5A;
	["Space"] = 0x20;
	["LeftShift"] = 0x10;
	["RightShift"] = 0x10;
    ["Comma"] = 0xBC;
    ["Period"] = 0xBE
}

-- Compatibility
mouse1press = mouse1press or mouse1down
mouse2press = mouse2press or mouse2down
mouse1release = mouse1release or mouse1up
mouse2release = mouse2release or mouse2up
keypress = keypress or keydown
keyrelease = keyrelease or keyup

-- Variables used in Animate script
local pose = "Standing" -- The pose that is used in the move function
local currentAnimSpeed = 1.0 -- Animation speed

-- Other
local GUIParent = Player:WaitForChild("PlayerGui")
local json
do -- Overwriting JSON
	json = (function()
																			local json = { _version = "0.1.2" }
																			
																			local t = tick()
																			local currentstr
																			local lasti
																			local function checkwait(i)
																				if tick() - t > MinimumJSONFPS then
																					lasti = lasti or i
																					if i >= lasti then
																						local Type = (type(currentstr) == "table" and "En") or (type(currentstr) == "string" and "De")
																						if Type then
																							ConsoleMessage(Type.."coding... ("..tostring(i).."/"..tostring(#currentstr)..")")
																						end
																						game:GetService("RunService").Stepped:Wait()
																						t = tick()
																						lasti = i
																					end
																				end
																			end

																			-------------------------------------------------------------------------------
																			-- Encode
																			-------------------------------------------------------------------------------

																			

																			local encode

																			local escape_char_map = {
																				[ "\\" ] = "\\",
																				[ "\"" ] = "\"",
																				[ "\b" ] = "b",
																				[ "\f" ] = "f",
																				[ "\n" ] = "n",
																				[ "\r" ] = "r",
																				[ "\t" ] = "t",
																			}

																			local escape_char_map_inv = { [ "/" ] = "/" }
																			for k, v in pairs(escape_char_map) do
																				escape_char_map_inv[v] = k
																			end


																			local function escape_char(c)
																				return "\\" .. (escape_char_map[c] or string.format("u%04x", c:byte()))
																			end


																			local function encode_nil(val)
																				return "null"
																			end


																			local function encode_table(val, stack)
																				local res = {}
																				stack = stack or {}

																				-- Circular reference?
																				if stack[val] then error("circular reference") end

																				stack[val] = true

																				if rawget(val, 1) ~= nil or next(val) == nil then
																					-- Treat as array -- check keys are valid and it is not sparse
																					local n = 0
																					for k in pairs(val) do
																						if type(k) ~= "number" then
																							error("invalid table: mixed or invalid key types")
																						end
																						n = n + 1
																					end
																					if n ~= #val then
																						error("invalid table: sparse array")
																					end
																					-- Encode
																					for i, v in ipairs(val) do
																						checkwait(i)
																						res[#res + 1] = encode(v, stack)
																					end
																					stack[val] = nil
																					
																					return "[" .. table.concat(res, ",") .. "]"

																				else
																					-- Treat as an object
																					local i = 0
																					for k, v in pairs(val) do
																						i = i + 1
																						if type(k) ~= "string" then
																							error("invalid table: mixed or invalid key types")
																						end
																						checkwait(i)
																						res[#res + 1] = encode(k, stack) .. ":" .. encode(v, stack)
																					end
																					stack[val] = nil
																					
																					return "{" .. table.concat(res, ",") .. "}"
																				end
																			end


																			local function encode_string(val)
																				return '"' .. val:gsub('[%z\1-\31\\"]', escape_char) .. '"'
																			end


																			local function encode_number(val)
																				-- Check for NaN, -inf and inf
																				if val ~= val or val <= -math.huge or val >= math.huge then
																					error("unexpected number value '" .. tostring(val) .. "'")
																				end
																				return string.format("%.14g", val)
																			end


																			local type_func_map = {
																				[ "nil"     ] = encode_nil,
																				[ "table"   ] = encode_table,
																				[ "string"  ] = encode_string,
																				[ "number"  ] = encode_number,
																				[ "boolean" ] = tostring,
																			}


																			encode = function(val, stack)
																				local t = type(val)
																				local f = type_func_map[t]
																				if f then
																					t = tick()
																					return f(val, stack)
																				end
																				error("unexpected type '" .. t .. "'")
																			end


																			function json.encode(val)
																				currentstr = val
																				lasti = nil
																				return ( encode(val) )
																			end


																			-------------------------------------------------------------------------------
																			-- Decode
																			-------------------------------------------------------------------------------

																			local parse

																			local function create_set(...)
																				local res = {}
																				for i = 1, select("#", ...) do
																					res[ select(i, ...) ] = true
																				end
																				return res
																			end

																			local space_chars   = create_set(" ", "\t", "\r", "\n")
																			local delim_chars   = create_set(" ", "\t", "\r", "\n", "]", "}", ",")
																			local escape_chars  = create_set("\\", "/", '"', "b", "f", "n", "r", "t", "u")
																			local literals      = create_set("true", "false", "null")

																			local literal_map = {
																				[ "true"  ] = true,
																				[ "false" ] = false,
																				[ "null"  ] = nil,
																			}


																			local function next_char(str, idx, set, negate)
																				for i = idx, #str do
																					if set[str:sub(i, i)] ~= negate then
																						return i
																					end
																				end
																				return #str + 1
																			end


																			local function decode_error(str, idx, msg)
																				local line_count = 1
																				local col_count = 1
																				for i = 1, idx - 1 do
																					col_count = col_count + 1
																					if str:sub(i, i) == "\n" then
																						line_count = line_count + 1
																						col_count = 1
																					end
																				end
																				error( string.format("%s at line %d col %d", msg, line_count, col_count) )
																			end



																			local function codepoint_to_utf8(n)
																				-- http://scripts.sil.org/cms/scripts/page.php?site_id=nrsi&id=iws-appendixa
																				local f = math.floor
																				if n <= 0x7f then
																					return string.char(n)
																				elseif n <= 0x7ff then
																					return string.char(f(n / 64) + 192, n % 64 + 128)
																				elseif n <= 0xffff then
																					return string.char(f(n / 4096) + 224, f(n % 4096 / 64) + 128, n % 64 + 128)
																				elseif n <= 0x10ffff then
																					return string.char(f(n / 262144) + 240, f(n % 262144 / 4096) + 128,
																						f(n % 4096 / 64) + 128, n % 64 + 128)
																				end
																				error( string.format("invalid unicode codepoint '%x'", n) )
																			end


																			local function parse_unicode_escape(s)
																				local n1 = tonumber( s:sub(1, 4),  16 )
																				local n2 = tonumber( s:sub(7, 10), 16 )
																				-- Surrogate pair?
																				if n2 then
																					return codepoint_to_utf8((n1 - 0xd800) * 0x400 + (n2 - 0xdc00) + 0x10000)
																				else
																					return codepoint_to_utf8(n1)
																				end
																			end


																			local function parse_string(str, i)
																				local res = ""
																				local j = i + 1
																				local k = j

																				while j <= #str do
																					local x = str:byte(j)

																					if x < 32 then
																						decode_error(str, j, "control character in string")

																					elseif x == 92 then -- `\`: Escape
																						res = res .. str:sub(k, j - 1)
																						j = j + 1
																						local c = str:sub(j, j)
																						if c == "u" then
																							local hex = str:match("^[dD][89aAbB]%x%x\\u%x%x%x%x", j + 1)
																								or str:match("^%x%x%x%x", j + 1)
																								or decode_error(str, j - 1, "invalid unicode escape in string")
																							res = res .. parse_unicode_escape(hex)
																							j = j + #hex
																						else
																							if not escape_chars[c] then
																								decode_error(str, j - 1, "invalid escape char '" .. c .. "' in string")
																							end
																							res = res .. escape_char_map_inv[c]
																						end
																						k = j + 1

																					elseif x == 34 then -- `"`: End of string
																						res = res .. str:sub(k, j - 1)
																						return res, j + 1
																					end

																					j = j + 1
																					checkwait(i)
																				end

																				decode_error(str, i, "expected closing quote for string")
																			end


																			local function parse_number(str, i)
																				local x = next_char(str, i, delim_chars)
																				local s = str:sub(i, x - 1)
																				local n = tonumber(s)
																				if not n then
																					decode_error(str, i, "invalid number '" .. s .. "'")
																				end
																				checkwait(i)
																				return n, x
																			end


																			local function parse_literal(str, i)
																				local x = next_char(str, i, delim_chars)
																				local word = str:sub(i, x - 1)
																				if not literals[word] then
																					decode_error(str, i, "invalid literal '" .. word .. "'")
																				end
																				checkwait(i)
																				return literal_map[word], x
																			end


																			local function parse_array(str, i)
																				local res = {}
																				local n = 1
																				i = i + 1
																				while 1 do
																					local x
																					i = next_char(str, i, space_chars, true)
																					-- Empty / end of array?
																					if str:sub(i, i) == "]" then
																						i = i + 1
																						break
																					end
																					-- Read token
																					x, i = parse(str, i)
																					res[n] = x
																					n = n + 1
																					-- Next token
																					i = next_char(str, i, space_chars, true)
																					local chr = str:sub(i, i)
																					i = i + 1
																					checkwait(i)
																					if chr == "]" then break end
																					if chr ~= "," then decode_error(str, i, "expected ']' or ','") end
																				end
																				return res, i
																			end


																			local function parse_object(str, i)
																				local res = {}
																				i = i + 1
																				while 1 do
																					local key, val
																					i = next_char(str, i, space_chars, true)
																					-- Empty / end of object?
																					if str:sub(i, i) == "}" then
																						i = i + 1
																						break
																					end
																					-- Read key
																					if str:sub(i, i) ~= '"' then
																						decode_error(str, i, "expected string for key")
																					end
																					key, i = parse(str, i)
																					-- Read ':' delimiter
																					i = next_char(str, i, space_chars, true)
																					if str:sub(i, i) ~= ":" then
																						decode_error(str, i, "expected ':' after key")
																					end
																					i = next_char(str, i + 1, space_chars, true)
																					-- Read value
																					val, i = parse(str, i)
																					-- Set
																					res[key] = val
																					-- Next token
																					i = next_char(str, i, space_chars, true)
																					local chr = str:sub(i, i)
																					i = i + 1
																					--ConsoleMessage(tick() - t, 1/60)
																					checkwait(i)
																					if chr == "}" then break end
																					if chr ~= "," then decode_error(str, i, "expected '}' or ','") end
																				end
																				return res, i
																			end


																			local char_func_map = {
																				[ '"' ] = parse_string,
																				[ "0" ] = parse_number,
																				[ "1" ] = parse_number,
																				[ "2" ] = parse_number,
																				[ "3" ] = parse_number,
																				[ "4" ] = parse_number,
																				[ "5" ] = parse_number,
																				[ "6" ] = parse_number,
																				[ "7" ] = parse_number,
																				[ "8" ] = parse_number,
																				[ "9" ] = parse_number,
																				[ "-" ] = parse_number,
																				[ "t" ] = parse_literal,
																				[ "f" ] = parse_literal,
																				[ "n" ] = parse_literal,
																				[ "[" ] = parse_array,
																				[ "{" ] = parse_object,
																			}


																			parse = function(str, idx)
																				local chr = str:sub(idx, idx)
																				local f = char_func_map[chr]
																				if f then
																					return f(str, idx)
																				end
																				decode_error(str, idx, "unexpected character '" .. chr .. "'")
																			end


																			function json.decode(str)
																				t = tick()
																				currentstr = str
																				lasti = nil
																				if type(str) ~= "string" then
																					error("expected argument of type string, got " .. type(str))
																				end
																				local res, idx = parse(str, next_char(str, 1, space_chars, true))
																				idx = next_char(str, idx, space_chars, true)
																				if idx <= #str then
																					decode_error(str, idx, "trailing garbage")
																				end
																				return res
																			end


																			return json
	end)()
end

-- Functions
-- General Functions


local TracerEnabled = false
local TracerLines = {}
local TRACER_STEPS = 30
local TRACER_LOOKAHEAD = 0.5 -- seconds ahead to predict

local function clearTracerLines()
    for _, line in pairs(TracerLines) do
        pcall(function() line:Remove() end)
    end
    TracerLines = {}
end

local function updateTracer()
    if not TracerEnabled then
        clearTracerLines()
        return
    end

    if not Drawing then
        ConsoleMessage("Tracer: Drawing API not supported")
        TracerEnabled = false
        return
    end

    if not RootPart then return end

    local cam = workspace.CurrentCamera
    local gravity = Vector3.new(0, -workspace.Gravity, 0)
    local dt = TRACER_LOOKAHEAD / TRACER_STEPS

    -- Make sure we have enough line objects
    while #TracerLines < TRACER_STEPS do
        local ok, line = pcall(function()
            local l = Drawing.new("Line")
            l.Thickness = 2
            l.Visible = false
            return l
        end)
        if ok then
            table.insert(TracerLines, line)
        else
            ConsoleMessage("Tracer: Drawing.new failed")
            return
        end
    end

    -- Simulate trajectory
    local pos = RootPart.Position
    local vel = RootPart.Velocity
    local points = {pos}

    local onGround = Humanoid and (
        Humanoid:GetState() == Enum.HumanoidStateType.Running or
        Humanoid:GetState() == Enum.HumanoidStateType.RunningNoPhysics
    )

    for i = 1, TRACER_STEPS do
        if onGround then
            -- On ground: just extrapolate flat velocity
            pos = pos + vel * dt
        else
            -- In air: apply gravity
            vel = vel + gravity * dt
            pos = pos + vel * dt
        end
        table.insert(points, pos)
    end

    -- Draw lines between points
    for i = 1, #points - 1 do
        local line = TracerLines[i]
        if not line then continue end

        local s1, on1 = cam:WorldToViewportPoint(points[i])
        local s2, on2 = cam:WorldToViewportPoint(points[i + 1])

        if on1 and on2 then
            line.From = Vector2.new(s1.X, s1.Y)
            line.To   = Vector2.new(s2.X, s2.Y)

            -- Color gradient: green at start -> red at end
            local t = (i - 1) / (#points - 2)
            line.Color = Color3.fromRGB(
                math.floor(50  + 205 * t),
                math.floor(255 - 205 * t),
                50
            )
            line.Visible = true
        else
            line.Visible = false
        end
    end
end

-- Hook into existing RenderStepped connections
RenderSteppedConnections.GhostAndTracer = function()
    if TracerEnabled then
        updateTracer()
    elseif #TracerLines > 0 then
        clearTracerLines()
    end
end


local StatsHudEnabled = false
local StatsHudGui = nil
 
local function createStatsHud()
    if StatsHudGui then StatsHudGui:Destroy() end
 
    -- ── Colors (match main GUI theme) ────────────────────────────
    local HUD_BG       = Color3.fromRGB(10, 10, 14)
    local HUD_INLINE   = Color3.fromRGB(21, 21, 28)
    local HUD_BORDER   = Color3.fromRGB(8, 8, 12)
    local HUD_OUTLINE  = Color3.fromRGB(30, 30, 40)
    local HUD_ACCENT   = Color3.fromRGB(100, 175, 255)
    local HUD_TEXT      = Color3.fromRGB(215, 215, 228)
    local HUD_MUTED     = Color3.fromRGB(115, 115, 138)
    local HUD_TXTSHADOW = Color3.fromRGB(0, 0, 0)
 
    local gui = Instance.new("ScreenGui")
    gui.Name = "TAS_StatsHud"
    gui.ResetOnSpawn = false
    gui.DisplayOrder = 9998
    gui.IgnoreGuiInset = true
    gui.Parent = Player.PlayerGui
 
    -- Main frame
    local frame = Instance.new("Frame")
    frame.Name = "StatsFrame"
    frame.Size = UDim2.new(0, 290, 0, 310)
    frame.Position = UDim2.new(0, 10, 1, -320)
    frame.BackgroundColor3 = HUD_BG
    frame.BorderSizePixel = 2
    frame.BorderColor3 = HUD_BORDER
    frame.Parent = gui
 
    -- Outline stroke
    local stroke = Instance.new("UIStroke")
    stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    stroke.LineJoinMode = Enum.LineJoinMode.Miter
    stroke.Color = HUD_OUTLINE
    stroke.Thickness = 1
    stroke.Parent = frame
 
    -- Accent line at top
    local accentLine = Instance.new("Frame")
    accentLine.Size = UDim2.new(1, 0, 0, 2)
    accentLine.Position = UDim2.new(0, 0, 0, 0)
    accentLine.BackgroundColor3 = HUD_ACCENT
    accentLine.BorderSizePixel = 0
    accentLine.ZIndex = 3
    accentLine.Parent = frame
 
    local accentGrad = Instance.new("UIGradient")
    accentGrad.Rotation = 90
    accentGrad.Color = ColorSequence.new{
        ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 255)),
        ColorSequenceKeypoint.new(1, Color3.fromRGB(65, 65, 65)),
    }
    accentGrad.Parent = accentLine
 
    -- Title
    local titleLbl = Instance.new("TextLabel")
    titleLbl.Size = UDim2.new(1, 0, 0, 18)
    titleLbl.Position = UDim2.new(0, 8, 0, 4)
    titleLbl.BackgroundTransparency = 1
    titleLbl.Text = "STATS HUD"
    titleLbl.TextColor3 = HUD_ACCENT
    titleLbl.Font = Enum.Font.GothamBold
    titleLbl.TextSize = 11
    titleLbl.TextXAlignment = Enum.TextXAlignment.Left
    titleLbl.Parent = frame
 
    local titleShadow = Instance.new("UIStroke")
    titleShadow.LineJoinMode = Enum.LineJoinMode.Miter
    titleShadow.Color = HUD_TXTSHADOW
    titleShadow.Parent = titleLbl
 
    -- Separator below title
    local sep = Instance.new("Frame")
    sep.Size = UDim2.new(1, -16, 0, 1)
    sep.Position = UDim2.new(0, 8, 0, 22)
    sep.BackgroundColor3 = HUD_OUTLINE
    sep.BorderSizePixel = 0
    sep.Parent = frame
 
    -- Content area
    local content = Instance.new("Frame")
    content.Size = UDim2.new(1, -16, 1, -30)
    content.Position = UDim2.new(0, 8, 0, 26)
    content.BackgroundTransparency = 1
    content.BorderSizePixel = 0
    content.Parent = frame
 
    local layout = Instance.new("UIListLayout")
    layout.Padding = UDim.new(0, 2)
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Parent = content
 
    -- Auto-resize
    layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
        frame.Size = UDim2.new(0, 290, 0, layout.AbsoluteContentSize.Y + 34)
        frame.Position = UDim2.new(0, 10, 1, -(layout.AbsoluteContentSize.Y + 44))
    end)
 
    -- ── Label factory ────────────────────────────────────────────
    local function makeHeader(text)
        local lbl = Instance.new("TextLabel")
        lbl.Size = UDim2.new(1, 0, 0, 16)
        lbl.BackgroundTransparency = 1
        lbl.Text = text
        lbl.TextColor3 = HUD_ACCENT
        lbl.Font = Enum.Font.GothamBold
        lbl.TextSize = 10
        lbl.TextXAlignment = Enum.TextXAlignment.Left
        lbl.Parent = content
        local s = Instance.new("UIStroke")
        s.LineJoinMode = Enum.LineJoinMode.Miter
        s.Color = HUD_TXTSHADOW
        s.Parent = lbl
        return lbl
    end
 
    local function makeLabel(name, defaultText)
        local lbl = Instance.new("TextLabel")
        lbl.Name = name
        lbl.Size = UDim2.new(1, 0, 0, 15)
        lbl.BackgroundTransparency = 1
        lbl.Text = defaultText
        lbl.RichText = true
        lbl.TextColor3 = HUD_TEXT
        lbl.Font = Enum.Font.GothamMedium
        lbl.TextSize = 12
        lbl.TextXAlignment = Enum.TextXAlignment.Left
        lbl.Parent = content
        local s = Instance.new("UIStroke")
        s.LineJoinMode = Enum.LineJoinMode.Miter
        s.Color = HUD_TXTSHADOW
        s.Parent = lbl
        return lbl
    end
 
    local function makeDivider()
        local div = Instance.new("Frame")
        div.Size = UDim2.new(1, 0, 0, 1)
        div.BackgroundColor3 = HUD_OUTLINE
        div.BackgroundTransparency = 0.5
        div.BorderSizePixel = 0
        div.Parent = content
    end
 
    -- ── Build labels ─────────────────────────────────────────────
    makeHeader("POSITION")
    local posX   = makeLabel("PosX",   "X: 0.000")
    local posY   = makeLabel("PosY",   "Y: 0.000")
    local posZ   = makeLabel("PosZ",   "Z: 0.000")
    makeDivider()
    makeHeader("VELOCITY")
    local velX   = makeLabel("VelX",   "X: 0.000")
    local velY   = makeLabel("VelY",   "Y: 0.000")
    local velZ   = makeLabel("VelZ",   "Z: 0.000")
    local velMag = makeLabel("VelMag", "Magnitude: 0.000")
    makeDivider()
    makeHeader("ROTATION")
    local rotX   = makeLabel("RotX",   "Pitch: 0.00°")
    local rotY   = makeLabel("RotY",   "Yaw:   0.00°")
    local rotZ   = makeLabel("RotZ",   "Roll:  0.00°")
    makeDivider()
    makeHeader("CHARACTER")
    local stateLabel = makeLabel("State", "State: None")
    local floorLabel = makeLabel("Floor", "Floor: None")
    local jumpLabel  = makeLabel("Jump",  "JumpPower: 50")
    local wsLabel    = makeLabel("WS",    "WalkSpeed: 16")
    local gravLabel  = makeLabel("Grav",  "Gravity: 196.2")
    makeDivider()
    makeHeader("REPLAY")
    local frameLabel = makeLabel("Frame", "Frame: 0 / 0")
    local timeLabel  = makeLabel("Time",  "Time:  0.00s")
    local zoomLabel  = makeLabel("Zoom",  "Zoom:  0.00")
    makeDivider()
    makeHeader("CSYNC")
    local coPartLabel  = makeLabel("COParts", "Tracked: 0")
    local coFrameLabel = makeLabel("COState", "CO State: idle")
 
    -- ── Update loop ──────────────────────────────────────────────
    local hudAccumulator = 0
    local updateConn = RunService.RenderStepped:Connect(function(dt)
        if not StatsHudEnabled or not StatsHudGui then return end
        if not RootPart or not Humanoid then return end
        hudAccumulator = hudAccumulator + (dt or 0)
        if hudAccumulator < (1 / 15) then return end
        hudAccumulator = 0
 
        local pos = RootPart.Position
        posX.Text = string.format("X: <font color='#ff8080'>%.4f</font>", pos.X)
        posY.Text = string.format("Y: <font color='#80ff80'>%.4f</font>", pos.Y)
        posZ.Text = string.format("Z: <font color='#8080ff'>%.4f</font>", pos.Z)
 
        local vel = RootPart.Velocity
        velX.Text   = string.format("X: <font color='#ff8080'>%.4f</font>", vel.X)
        velY.Text   = string.format("Y: <font color='#80ff80'>%.4f</font>", vel.Y)
        velZ.Text   = string.format("Z: <font color='#8080ff'>%.4f</font>", vel.Z)
        velMag.Text = string.format("Magnitude: <font color='#ffdc50'>%.4f</font>", vel.Magnitude)
 
        local rx, ry, rz = RootPart.CFrame:ToOrientation()
        rotX.Text = string.format("Pitch: <font color='#ff8080'>%.2f°</font>", math.deg(rx))
        rotY.Text = string.format("Yaw:   <font color='#80ff80'>%.2f°</font>", math.deg(ry))
        rotZ.Text = string.format("Roll:  <font color='#8080ff'>%.2f°</font>", math.deg(rz))
 
        local stateStr = tostring(Humanoid:GetState()):gsub("Enum.HumanoidStateType.", "")
        local sc = "#ffffff"
        if stateStr == "Jumping" or stateStr == "Freefall" then sc = "#80ff80"
        elseif stateStr == "Running" then sc = "#ffdc50"
        elseif stateStr == "Climbing" then sc = "#ff9650"
        elseif stateStr == "Dead" then sc = "#ff5050" end
        stateLabel.Text = string.format("State: <font color='%s'>%s</font>", sc, stateStr)
 
        local floorMat = tostring(Humanoid.FloorMaterial):gsub("Enum.Material.", "")
        floorLabel.Text = string.format("Floor: <font color='#aaaaff'>%s</font>", floorMat)
        jumpLabel.Text  = string.format("JumpPower: <font color='#c8c8ff'>%.1f</font>", Humanoid.JumpPower)
        wsLabel.Text    = string.format("WalkSpeed: <font color='#c8c8ff'>%.1f</font>", Humanoid.WalkSpeed)
        gravLabel.Text  = string.format("Gravity: <font color='#c8c8ff'>%.2f</font>", workspace.Gravity)
 
        local totalFrames = #ReplayTable
        local cf = Frozen and RoundNumber(FreezeFrame, 0) or (Reading and ReplayTableIndex or 0)
        frameLabel.Text = string.format("Frame: <font color='#64afff'>%d / %d</font>", cf, totalFrames)
        timeLabel.Text  = string.format("Time:  <font color='#64afff'>%.2fs</font>", cf / math.max(ReplaySourceFPS or TASRecordingFPS or 1, 1))
 
        local zoom = GetZoom()
        zoomLabel.Text = string.format("Zoom:  <font color='#64afff'>%.2f</font>", zoom)
 
        -- CSync info
        local partCount = CO.GetPartCount and CO.GetPartCount() or 0
        coPartLabel.Text = string.format("Tracked: <font color='#64afff'>%d</font> parts", partCount)
        local coStatus = "idle"
        if Writing then coStatus = "recording"
        elseif Reading then coStatus = "playing"
        elseif Frozen then coStatus = "frozen" end
        coFrameLabel.Text = string.format("CO State: <font color='#64afff'>%s</font>", coStatus)
    end)
 
    getgenv().StatsHudConnection = updateConn
    StatsHudGui = gui
    ConsoleMessage("Stats HUD enabled")
end
 
local function destroyStatsHud()
    if getgenv().StatsHudConnection then
        getgenv().StatsHudConnection:Disconnect()
        getgenv().StatsHudConnection = nil
    end
    if StatsHudGui then
        StatsHudGui:Destroy()
        StatsHudGui = nil
    end
    ConsoleMessage("Stats HUD disabled")
end


-- Fast conversion functions for better performance
local function FastTableToCFrame(t)
	return CFrame.new(t[1], t[2], t[3], t[4], t[5], t[6], t[7], t[8], t[9], t[10], t[11], t[12])
end

local function FastTableToVector3(t)
	return Vector3.new(t[1], t[2], t[3])
end

local function FastTableToVector2(t)
	return Vector2.new(t[1], t[2])
end
local RandomString --RandomString() -> string
local RoundNumber -- RoundNumber(Number,Digits) -> number
local Vector3ToTable -- Vector3ToTable(Vector3) -> table
local TableToVector3 -- TableToVector3(Table) -> vector3
local CFrameToTable -- CFrameToTable(CFrame) -> table
local TableToCFrame -- TableToCFrame(Table) -> cframe
local RoundVector3 -- RoundVector3(Vector3,Digits) -> vector3
local RoundCFrame -- RoundCFrame(CFrame,Digits) -> cframe
local FindListIndex -- FindListIndex(Table,Search) -> number
local WaitForInput -- WaitForInput() -> nil
do
	RandomString = function()
		local str = ""
		for _ = 1,random(1,20) do
			local type = random(1,3)
			if type == 1 then
				str = str..string.char(random(97,122)) -- Lowercase
			elseif type == 2 then
				str = str..string.char(random(65,90)) -- Uppercase
			elseif type == 3 then
				str = str..string.char(random(48,57)) -- Numbers
			end
		end
		return str
	end
	RoundNumber = function(Number,Digits)
		local Mult = 10^max(tonumber(Digits) or 0,0)
		return floor(Number*Mult+0.5)/Mult
	end
	Vector3ToTable = function(V3)
		return {V3.X,V3.Y,V3.Z}
	end
	TableToVector3 = function(Table)
		return Vector3.new(unpack(Table))
	end
	Vector2ToTable = function(V2)
		return {V2.X,V2.Y}
	end
	TableToVector2 = function(Table)
		return Vector2.new(unpack(Table))
	end
	CFrameToTable = function(CF)
		return {CF:GetComponents()}
	end
	TableToCFrame = function(Table)
		return CFrame.new(unpack(Table))
	end
	RoundTable = function(Table,Digits)
		local RoundedTable = {}
		for Index,Number in pairs(Table) do
			RoundedTable[Index] = RoundNumber(Number,Digits)
		end
		return RoundedTable
	end
	FindListIndex = function(Table,Search)
		for Index,Value in pairs(Table) do
			if Value == Search then
				return Index
			end
		end
	end
	WaitForInput = function()
		local KeyPressed = Instance.new("BindableEvent")
		local InputBeganConnection
		InputBeganConnection = UserInputService.InputBegan:Connect(function(Input)
			if Input.UserInputType == Enum.UserInputType.Keyboard then
				RunService.RenderStepped:Wait()
				KeyPressed:Fire()
			end
		end)
		KeyPressed.Event:Wait()
		InputBeganConnection:Disconnect()
		KeyPressed:Destroy()
	end
end

local function ReleaseAllPlaybackKeys()
    for Input, Code in pairs(PlaybackPressedKeys) do
        if Code == "b1" then
            mouse1release()
        elseif Code == "b2" then
            mouse2release()
        elseif type(Code) == "number" then
            keyrelease(Code)
        end
    end
    PlaybackPressedKeys = {}
end



-- ── Services ─────────────────────────────────────────────────────────────────
local TweenService = game:GetService("TweenService")

-- ── Font ─────────────────────────────────────────────────────────────────────
local UIFont = Font.fromEnum(Enum.Font.Code)
local UIFontBold = Font.fromEnum(Enum.Font.GothamBold)
pcall(function()
    UIFont = Font.fromEnum(Enum.Font.GothamMedium)
    UIFontBold = Font.fromEnum(Enum.Font.GothamBold)
end)

-- ── Utilities ────────────────────────────────────────────────────────────────
local function tw(obj, props, dur, style)
    TweenService:Create(
        obj,
        TweenInfo.new(dur or 0.22, style or Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
        props
    ):Play()
end

local function mk(cls, props)
    local inst = Instance.new(cls)
    for k, v in pairs(props) do inst[k] = v end
    return inst
end

-- ══════════════════════════════════════════════════════════════════════════════
--  THEME SYSTEM
-- ══════════════════════════════════════════════════════════════════════════════

local ThemeBindings = {} -- {inst, property, themeKey}

local Theme = {
    -- Layered backgrounds (deep → surface)
    bg_deep     = Color3.fromRGB(10, 10, 14),
    bg_window   = Color3.fromRGB(15, 15, 21),
    bg_inline   = Color3.fromRGB(21, 21, 28),
    bg_panel    = Color3.fromRGB(28, 28, 35),
    bg_element  = Color3.fromRGB(35, 35, 42),
    bg_hover    = Color3.fromRGB(44, 44, 54),

    -- Accent
    accent      = Color3.fromRGB(100, 175, 255),
    accent_dim  = Color3.fromRGB(30, 60, 100),
    accent_glow = Color3.fromRGB(75, 145, 225),

    -- Borders (the layered system from )
    border      = Color3.fromRGB(8, 8, 12),    -- innermost, dark
    outline     = Color3.fromRGB(30, 30, 40),   -- outer stroke

    -- Text
    txt         = Color3.fromRGB(215, 215, 228),
    txt_muted   = Color3.fromRGB(115, 115, 138),
    txt_dim     = Color3.fromRGB(55, 55, 70),
    txt_shadow  = Color3.fromRGB(0, 0, 0),

    -- Status
    red    = Color3.fromRGB(220, 60, 60),
    green  = Color3.fromRGB(60, 220, 100),
    cyan   = Color3.fromRGB(60, 200, 220),
    yellow = Color3.fromRGB(220, 200, 60),
}

local ThemePresets = {
    ["Midnight Blue"] = {
        accent = Color3.fromRGB(100, 175, 255), accent_dim = Color3.fromRGB(30, 60, 100),
        accent_glow = Color3.fromRGB(75, 145, 225),
        bg_deep = Color3.fromRGB(10, 10, 14), bg_window = Color3.fromRGB(15, 15, 21),
        bg_inline = Color3.fromRGB(21, 21, 28), bg_panel = Color3.fromRGB(28, 28, 35),
        bg_element = Color3.fromRGB(35, 35, 42), border = Color3.fromRGB(8, 8, 12),
        outline = Color3.fromRGB(30, 30, 40),
    },
    ["Neon Green"] = {
        accent = Color3.fromRGB(80, 255, 120), accent_dim = Color3.fromRGB(25, 80, 40),
        accent_glow = Color3.fromRGB(60, 200, 90),
        bg_deep = Color3.fromRGB(8, 10, 8), bg_window = Color3.fromRGB(12, 16, 12),
        bg_inline = Color3.fromRGB(18, 22, 18), bg_panel = Color3.fromRGB(24, 30, 24),
        bg_element = Color3.fromRGB(30, 38, 30), border = Color3.fromRGB(6, 10, 6),
        outline = Color3.fromRGB(28, 42, 28),
    },
    ["Blood Red"] = {
        accent = Color3.fromRGB(255, 50, 50), accent_dim = Color3.fromRGB(85, 20, 20),
        accent_glow = Color3.fromRGB(200, 45, 45),
        bg_deep = Color3.fromRGB(12, 8, 8), bg_window = Color3.fromRGB(18, 12, 12),
        bg_inline = Color3.fromRGB(26, 16, 16), bg_panel = Color3.fromRGB(34, 20, 20),
        bg_element = Color3.fromRGB(42, 26, 26), border = Color3.fromRGB(10, 6, 6),
        outline = Color3.fromRGB(45, 25, 25),
    },
    ["Purple Haze"] = {
        accent = Color3.fromRGB(180, 100, 255), accent_dim = Color3.fromRGB(55, 28, 90),
        accent_glow = Color3.fromRGB(145, 75, 215),
        bg_deep = Color3.fromRGB(11, 9, 16), bg_window = Color3.fromRGB(17, 13, 24),
        bg_inline = Color3.fromRGB(24, 18, 34), bg_panel = Color3.fromRGB(32, 24, 44),
        bg_element = Color3.fromRGB(40, 30, 54), border = Color3.fromRGB(9, 7, 14),
        outline = Color3.fromRGB(38, 28, 55),
    },
    ["Teal"] = {
        accent = Color3.fromRGB(0, 210, 180), accent_dim = Color3.fromRGB(0, 65, 55),
        accent_glow = Color3.fromRGB(0, 170, 140),
        bg_deep = Color3.fromRGB(7, 11, 11), bg_window = Color3.fromRGB(11, 17, 17),
        bg_inline = Color3.fromRGB(17, 24, 24), bg_panel = Color3.fromRGB(22, 32, 32),
        bg_element = Color3.fromRGB(28, 40, 40), border = Color3.fromRGB(5, 9, 9),
        outline = Color3.fromRGB(24, 42, 40),
    },
    ["Gold"] = {
        accent = Color3.fromRGB(255, 200, 60), accent_dim = Color3.fromRGB(90, 70, 18),
        accent_glow = Color3.fromRGB(215, 165, 45),
        bg_deep = Color3.fromRGB(13, 11, 7), bg_window = Color3.fromRGB(19, 17, 11),
        bg_inline = Color3.fromRGB(27, 23, 15), bg_panel = Color3.fromRGB(35, 29, 19),
        bg_element = Color3.fromRGB(43, 35, 23), border = Color3.fromRGB(10, 8, 5),
        outline = Color3.fromRGB(48, 38, 20),
    },
    ["Monochrome"] = {
        accent = Color3.fromRGB(200, 200, 200), accent_dim = Color3.fromRGB(55, 55, 55),
        accent_glow = Color3.fromRGB(160, 160, 160),
        bg_deep = Color3.fromRGB(9, 9, 9), bg_window = Color3.fromRGB(15, 15, 15),
        bg_inline = Color3.fromRGB(22, 22, 22), bg_panel = Color3.fromRGB(30, 30, 30),
        bg_element = Color3.fromRGB(38, 38, 38), border = Color3.fromRGB(6, 6, 6),
        outline = Color3.fromRGB(35, 35, 35),
    },
}

local function applyTheme(inst, prop, key)
    inst[prop] = Theme[key]
    table.insert(ThemeBindings, {inst, prop, key})
end

local function refreshAllTheme()
    for _, b in ipairs(ThemeBindings) do
        if b[1] and b[1].Parent then
            pcall(function() b[1][b[2]] = Theme[b[3]] end)
        end
    end
end

local function setThemePreset(name)
    local p = ThemePresets[name]
    if not p then return end
    for k, v in pairs(p) do Theme[k] = v end
    refreshAllTheme()
end

-- ── Instance helpers ─────────────────────────────────────────────────────────

-- Layered border: BorderSizePixel=2, BorderColor3=border, UIStroke=outline
local function addLayeredBorder(parent)
    parent.BorderSizePixel = 2
    parent.BorderColor3 = Theme.border
    applyTheme(parent, "BorderColor3", "border")
    local s = mk("UIStroke", {
        Parent = parent,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
        LineJoinMode = Enum.LineJoinMode.Miter,
        Color = Theme.outline,
        Thickness = 1,
    })
    applyTheme(s, "Color", "outline")
    return s
end

-- Simple outline stroke (no inner border)
local function addStroke(parent, themeKey, thickness, transparency)
    local s = mk("UIStroke", {
        Parent = parent,
        Color = Theme[themeKey or "outline"],
        Thickness = thickness or 1,
        Transparency = transparency or 0,
        LineJoinMode = Enum.LineJoinMode.Miter,
    })
    applyTheme(s, "Color", themeKey or "outline")
    return s
end

-- Text shadow stroke
local function addTextShadow(parent)
    return mk("UIStroke", {
        Parent = parent,
        LineJoinMode = Enum.LineJoinMode.Miter,
        Color = Theme.txt_shadow,
        Thickness = 1,
    })
end

-- Accent gradient line
local function addAccentLine(parent, pos, size)
    local line = mk("Frame", {
        Parent = parent,
        Position = pos or UDim2.new(0, 0, 0, 0),
        Size = size or UDim2.new(1, 0, 0, 2),
        BackgroundColor3 = Theme.accent,
        BorderSizePixel = 0,
        ZIndex = 3,
    })
    applyTheme(line, "BackgroundColor3", "accent")
    mk("UIGradient", {
        Parent = line,
        Rotation = 90,
        Color = ColorSequence.new{
            ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 255)),
            ColorSequenceKeypoint.new(1, Color3.fromRGB(65, 65, 65)),
        },
    })
    return line
end

-- Vertical gradient overlay for buttons / elements
local function addVertGradient(parent)
    return mk("UIGradient", {
        Parent = parent,
        Rotation = 90,
        Color = ColorSequence.new{
            ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 255)),
            ColorSequenceKeypoint.new(1, Color3.fromRGB(100, 100, 100)),
        },
    })
end

-- ══════════════════════════════════════════════════════════════════════════════
--  ROOT GUI
-- ══════════════════════════════════════════════════════════════════════════════

local RootGui = mk("ScreenGui", {
    Name = "TasabilityGUI",
    ResetOnSpawn = false,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    DisplayOrder = 9990,
    IgnoreGuiInset = true,
    Parent = game:GetService("CoreGui"),
})

-- Dedicated topmost layer for dropdown lists. It sits above popups/windows/overlays.
local DropdownGui = mk("ScreenGui", {
    Name = "TasabilityDropdowns",
    ResetOnSpawn = false,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    DisplayOrder = 10000000,
    IgnoreGuiInset = true,
    Parent = game:GetService("CoreGui"),
})

-- ══════════════════════════════════════════════════════════════════════════════
--  MAIN WINDOW
-- ══════════════════════════════════════════════════════════════════════════════

local MainFrame = mk("Frame", {
    Name = "MainFrame",
    Size = UDim2.fromOffset(700, 500),
    Position = UDim2.fromOffset(70, 70),
    BackgroundColor3 = Theme.bg_window,
    BorderSizePixel = 0,
    Parent = RootGui,
})
applyTheme(MainFrame, "BackgroundColor3", "bg_window")

-- Accent outer stroke 
local accentBorder = mk("UIStroke", {
    Parent = MainFrame,
    ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
    LineJoinMode = Enum.LineJoinMode.Miter,
    Color = Theme.accent,
    Thickness = 1,
})
applyTheme(accentBorder, "Color", "accent")

-- Top accent gradient line
addAccentLine(MainFrame, UDim2.new(0, 0, 0, 0), UDim2.new(1, 0, 0, 2))

-- ── Title bar ────────────────────────────────────────────────────────────────
local TitleBar = mk("Frame", {
    Size = UDim2.new(1, 0, 0, 28),
    Position = UDim2.fromOffset(0, 2),
    BackgroundColor3 = Theme.bg_deep,
    BorderSizePixel = 0,
    Parent = MainFrame,
})
applyTheme(TitleBar, "BackgroundColor3", "bg_deep")

-- Title bar bottom separator
mk("Frame", {
    Size = UDim2.new(1, 0, 0, 1),
    Position = UDim2.new(0, 0, 1, -1),
    BackgroundColor3 = Theme.outline,
    BorderSizePixel = 0,
    Parent = TitleBar,
})

-- Drag
do
    local dragging, dragStart, frameStart
    TitleBar.InputBegan:Connect(function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging = true; dragStart = inp.Position; frameStart = MainFrame.Position
        end
    end)
    TitleBar.InputEnded:Connect(function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1 then dragging = false end
    end)
    UserInputService.InputChanged:Connect(function(inp)
        if dragging and inp.UserInputType == Enum.UserInputType.MouseMovement then
            local d = inp.Position - dragStart
            MainFrame.Position = UDim2.fromOffset(
                frameStart.X.Offset + d.X, frameStart.Y.Offset + d.Y)
        end
    end)
end

-- Title label
local TitleLabel = mk("TextLabel", {
    Size = UDim2.new(1, -80, 1, 0),
    Position = UDim2.fromOffset(8, 0),
    BackgroundTransparency = 1,
    Text = "TASABILITY",
    TextColor3 = Theme.accent,
    FontFace = UIFontBold,
    TextSize = 13,
    TextXAlignment = Enum.TextXAlignment.Left,
    Parent = TitleBar,
})
applyTheme(TitleLabel, "TextColor3", "accent")
addTextShadow(TitleLabel)

-- Version label
mk("TextLabel", {
    Size = UDim2.fromOffset(0, 28),
    Position = UDim2.fromOffset(88, 0),
    BackgroundTransparency = 1,
    Text = Version,
    TextColor3 = Theme.txt_muted,
    FontFace = UIFont,
    TextSize = 11,
    TextXAlignment = Enum.TextXAlignment.Left,
    AutomaticSize = Enum.AutomaticSize.X,
    Parent = TitleBar,
})

-- Minimize button
local HideBtn = mk("TextButton", {
    Size = UDim2.fromOffset(22, 16),
    Position = UDim2.new(1, -28, 0.5, -8),
    BackgroundColor3 = Theme.bg_element,
    BorderSizePixel = 2,
    BorderColor3 = Theme.border,
    Text = "—",
    TextColor3 = Theme.txt_muted,
    FontFace = UIFontBold,
    TextSize = 11,
    AutoButtonColor = false,
    Parent = TitleBar,
})
applyTheme(HideBtn, "BackgroundColor3", "bg_element")
applyTheme(HideBtn, "BorderColor3", "border")
addStroke(HideBtn, "outline", 1)
HideBtn.MouseButton1Click:Connect(function() MainFrame.Visible = not MainFrame.Visible end)
HideBtn.MouseEnter:Connect(function() tw(HideBtn, {TextColor3 = Theme.accent}) end)
HideBtn.MouseLeave:Connect(function() tw(HideBtn, {TextColor3 = Theme.txt_muted}) end)

-- ── Inline frame ( style: window > inline > content) ─────────────────
local InlineFrame = mk("Frame", {
    Position = UDim2.fromOffset(7, 32),
    Size = UDim2.new(1, -14, 1, -39),
    BackgroundColor3 = Theme.bg_inline,
    BorderSizePixel = 0,
    Parent = MainFrame,
})
applyTheme(InlineFrame, "BackgroundColor3", "bg_inline")
addLayeredBorder(InlineFrame)

-- ── Tab bar (inside inline) ──────────────────────────────────────────────────
local TabBar = mk("Frame", {
    Position = UDim2.fromOffset(7, 7),
    Size = UDim2.new(1, -14, 0, 22),
    BackgroundTransparency = 1,
    ClipsDescendants = true,
    Parent = InlineFrame,
})
mk("UIListLayout", {
    FillDirection = Enum.FillDirection.Horizontal,
    SortOrder = Enum.SortOrder.LayoutOrder,
    VerticalAlignment = Enum.VerticalAlignment.Center,
    Padding = UDim.new(0, 5),
    Parent = TabBar,
})

-- ── Content frame (inside inline, below tabs) ────────────────────────────────
local ContentFrame = mk("Frame", {
    Position = UDim2.fromOffset(7, 32),
    Size = UDim2.new(1, -14, 1, -39),
    BackgroundColor3 = Theme.bg_deep,
    BorderSizePixel = 0,
    Parent = InlineFrame,
})
applyTheme(ContentFrame, "BackgroundColor3", "bg_deep")
addLayeredBorder(ContentFrame)

-- ══════════════════════════════════════════════════════════════════════════════
--  TAB SYSTEM
-- ══════════════════════════════════════════════════════════════════════════════

local tabPages = {}
local tabButtons = {}  -- stores the button Instances
local tabData = {}     -- stores {textLbl, hideBar} per tab name (separate from Instance)
local activeTab = nil

local function switchTab(name)
    for n, pg in pairs(tabPages) do pg.Visible = (n == name) end
    for n, _ in pairs(tabButtons) do
        local data = tabData[n]
        if not data then continue end
        if n == name then
            data.textLbl.TextColor3 = Theme.accent
            data.textLbl.TextTransparency = 0
            data.hideBar.Visible = true
        else
            data.textLbl.TextColor3 = Theme.txt
            data.textLbl.TextTransparency = 0.48
            data.hideBar.Visible = false
        end
    end
    activeTab = name
end

local function addTab(label)
    local btn = mk("TextButton", {
        Size = UDim2.new(0, 90, 1, 0),
        BackgroundColor3 = Theme.bg_panel,
        BorderSizePixel = 2,
        BorderColor3 = Theme.border,
        Text = "",
        AutoButtonColor = false,
        Parent = TabBar,
    })
    applyTheme(btn, "BackgroundColor3", "bg_panel")
    applyTheme(btn, "BorderColor3", "border")
    addStroke(btn, "outline", 1)
    addVertGradient(btn)

    local textLbl = mk("TextLabel", {
        Size = UDim2.fromScale(1, 1),
        Position = UDim2.fromOffset(0, -1),
        BackgroundTransparency = 1,
        Text = label:upper(),
        TextColor3 = Theme.txt,
        TextTransparency = 0.48,
        FontFace = UIFont,
        TextSize = 11,
        Parent = btn,
    })
    addTextShadow(textLbl)

    -- "Hide bar" that covers bottom border when active 
    local hideBar = mk("Frame", {
        Size = UDim2.new(1, 0, 0, 3),
        Position = UDim2.new(0, 0, 1, 0),
        AnchorPoint = Vector2.new(0, 1),
        BackgroundColor3 = Theme.bg_deep,
        BorderSizePixel = 0,
        Visible = false,
        ZIndex = 2,
        Parent = btn,
    })
    applyTheme(hideBar, "BackgroundColor3", "bg_deep")

    -- Store data in a plain Lua table, NOT on the Instance
    tabData[label] = {textLbl = textLbl, hideBar = hideBar}

    btn.MouseEnter:Connect(function()
        if activeTab ~= label then tw(textLbl, {TextColor3 = Theme.accent_glow}) end
    end)
    btn.MouseLeave:Connect(function()
        if activeTab ~= label then tw(textLbl, {TextColor3 = Theme.txt}) end
    end)

    -- Page
    local page = mk("ScrollingFrame", {
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ScrollBarThickness = 2,
        ScrollBarImageColor3 = Theme.accent_dim,
        CanvasSize = UDim2.fromScale(0, 0),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        Visible = false,
        Parent = ContentFrame,
    })
    mk("UIPadding", {PaddingTop=UDim.new(0,8), PaddingBottom=UDim.new(0,8),
        PaddingLeft=UDim.new(0,8), PaddingRight=UDim.new(0,8), Parent=page})
    mk("UIListLayout", {FillDirection=Enum.FillDirection.Vertical, SortOrder=Enum.SortOrder.LayoutOrder,
        Padding=UDim.new(0,7), Parent=page})

    tabPages[label] = page
    tabButtons[label] = btn
    btn.MouseButton1Click:Connect(function() switchTab(label) end)
    return page
end

-- ══════════════════════════════════════════════════════════════════════════════
--  SECTION BUILDER 
-- ══════════════════════════════════════════════════════════════════════════════

local function addSection(page, title)
    local wrap = mk("Frame", {
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundColor3 = Theme.bg_inline,
        BorderSizePixel = 0,
        Parent = page,
    })
    applyTheme(wrap, "BackgroundColor3", "bg_inline")
    addLayeredBorder(wrap)

    -- Accent line at top
    addAccentLine(wrap, UDim2.fromOffset(0, 0), UDim2.new(1, 0, 0, 2))

    -- Section title
    local titleLbl = mk("TextLabel", {
        Size = UDim2.new(1, -10, 0, 16),
        Position = UDim2.fromOffset(6, 4),
        BackgroundTransparency = 1,
        Text = title:upper(),
        TextColor3 = Theme.accent_glow,
        FontFace = UIFontBold,
        TextSize = 10,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = wrap,
    })
    applyTheme(titleLbl, "TextColor3", "accent_glow")
    addTextShadow(titleLbl)

    -- Body container
    local body = mk("Frame", {
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        Position = UDim2.fromOffset(0, 22),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Parent = wrap,
    })
    mk("UIPadding", {PaddingTop=UDim.new(0,4), PaddingBottom=UDim.new(0,6),
        PaddingLeft=UDim.new(0,8), PaddingRight=UDim.new(0,8), Parent=body})
    mk("UIListLayout", {FillDirection=Enum.FillDirection.Vertical, SortOrder=Enum.SortOrder.LayoutOrder,
        Padding=UDim.new(0,5), Parent=body})

    return body
end

-- ══════════════════════════════════════════════════════════════════════════════
--  ELEMENT BUILDERS
-- ══════════════════════════════════════════════════════════════════════════════

-- addLabel ─────────────────────────────────────────────
local function addLabel(parent, defaultText)
    local lbl = mk("TextLabel", {
        Size = UDim2.new(1, 0, 0, 14),
        BackgroundTransparency = 1,
        Text = defaultText or "",
        TextColor3 = Theme.txt_muted,
        FontFace = UIFont, TextSize = 11,
        TextXAlignment = Enum.TextXAlignment.Left,
        RichText = true,
        Parent = parent,
    })
    addTextShadow(lbl)
    local shim = {}
    setmetatable(shim, {
        __index = function(_, k)
            if k == "Text" then return lbl.Text end
            if k == "TextColor3" then return lbl.TextColor3 end
        end,
        __newindex = function(_, k, v)
            if k == "Text" then lbl.Text = v
            elseif k == "TextColor3" then lbl.TextColor3 = v end
        end,
    })
    return shim
end

-- addButton ────────────────────────────────────────────
local function addButton(parent, label, callback)
    local btn = mk("TextButton", {
        Size = UDim2.new(1, 0, 0, 22),
        BackgroundColor3 = Theme.bg_element,
        BorderSizePixel = 2,
        BorderColor3 = Theme.border,
        Text = "",
        AutoButtonColor = false,
        Parent = parent,
    })
    applyTheme(btn, "BackgroundColor3", "bg_element")
    applyTheme(btn, "BorderColor3", "border")
    addStroke(btn, "outline", 1)
    addVertGradient(btn)

    local textLbl = mk("TextLabel", {
        Size = UDim2.fromScale(1, 1),
        Position = UDim2.fromOffset(0, -1),
        BackgroundTransparency = 1,
        Text = label,
        TextColor3 = Theme.txt,
        FontFace = UIFont, TextSize = 11,
        Parent = btn,
    })
    applyTheme(textLbl, "TextColor3", "txt")
    addTextShadow(textLbl)

    btn.MouseButton1Click:Connect(callback or function() end)
    btn.MouseEnter:Connect(function()
        tw(btn, {BackgroundColor3 = Theme.bg_hover})
        tw(textLbl, {TextColor3 = Theme.accent})
    end)
    btn.MouseLeave:Connect(function()
        tw(btn, {BackgroundColor3 = Theme.bg_element})
        tw(textLbl, {TextColor3 = Theme.txt})
    end)

    local shim = {}
    setmetatable(shim, {
        __index = function(_, k) if k == "Text" then return textLbl.Text end end,
        __newindex = function(_, k, v) if k == "Text" then textLbl.Text = v end end,
    })
    return shim
end

-- addRow ───────────────────────────────────────────────
local function addRow(parent)
    local row = mk("Frame", {
        Size = UDim2.new(1, 0, 0, 22),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Parent = parent,
    })
    mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal, SortOrder=Enum.SortOrder.LayoutOrder,
        Padding=UDim.new(0,4), Parent=row})

    local rowShim = {}
    function rowShim:Button(cfg)
        local b = mk("TextButton", {
            Size = UDim2.new(0.55, 0, 1, 0),
            BackgroundColor3 = Theme.bg_element,
            BorderSizePixel = 2, BorderColor3 = Theme.border,
            Text = "", AutoButtonColor = false, Parent = row,
        })
        applyTheme(b, "BackgroundColor3", "bg_element")
        applyTheme(b, "BorderColor3", "border")
        addStroke(b, "outline", 1)
        addVertGradient(b)

        local t = mk("TextLabel", {
            Size=UDim2.fromScale(1,1), Position=UDim2.fromOffset(0,-1),
            BackgroundTransparency=1, Text=cfg.Text or "button",
            TextColor3=Theme.txt, FontFace=UIFont, TextSize=11, Parent=b,
        })
        addTextShadow(t)

        b.MouseButton1Click:Connect(cfg.Callback or function() end)
        b.MouseEnter:Connect(function()
            tw(b, {BackgroundColor3 = Theme.bg_hover})
            tw(t, {TextColor3 = Theme.accent})
        end)
        b.MouseLeave:Connect(function()
            tw(b, {BackgroundColor3 = Theme.bg_element})
            tw(t, {TextColor3 = Theme.txt})
        end)
        return b
    end
    function rowShim:Keybind(cfg)
        return addKeybind(row, cfg, UDim2.new(0.45, -4, 1, 0))
    end
    return rowShim
end

-- addKeybind ──────────────────────────────────────────
function addKeybind(parent, cfg, size)
    local currentKey = cfg.Value or Enum.KeyCode.Unknown
    local binding = false

    local btn = mk("TextButton", {
        Size = size or UDim2.new(1, 0, 0, 22),
        BackgroundColor3 = Theme.bg_element,
        BorderSizePixel = 2, BorderColor3 = Theme.border,
        Text = "", AutoButtonColor = false, Parent = parent,
    })
    applyTheme(btn, "BackgroundColor3", "bg_element")
    applyTheme(btn, "BorderColor3", "border")
    addStroke(btn, "outline", 1)

    local inner = mk("Frame", {Size=UDim2.fromScale(1,1), BackgroundTransparency=1, Parent=btn})
    mk("UIPadding", {PaddingLeft=UDim.new(0,6), PaddingRight=UDim.new(0,4), Parent=inner})

    mk("TextLabel", {
        Size=UDim2.new(0.55,0,1,0), BackgroundTransparency=1,
        Text=cfg.Label or "keybind", TextColor3=Theme.txt_muted,
        FontFace=UIFont, TextSize=10, TextXAlignment=Enum.TextXAlignment.Left,
        Parent=inner,
    })

    local keyBg = mk("Frame", {
        Size=UDim2.new(0.42,0,0.7,0), Position=UDim2.new(0.58,0,0.15,0),
        BackgroundColor3=Theme.bg_deep, BorderSizePixel=2, BorderColor3=Theme.border,
        Parent=inner,
    })
    applyTheme(keyBg, "BackgroundColor3", "bg_deep")
    applyTheme(keyBg, "BorderColor3", "border")
    addStroke(keyBg, "accent_dim", 1, 0.4)

    local keyLbl = mk("TextLabel", {
        Size=UDim2.fromScale(1,1), BackgroundTransparency=1,
        Text=tostring(currentKey):gsub("Enum.KeyCode.", ""),
        TextColor3=Theme.accent, FontFace=UIFont, TextSize=10,
        TextXAlignment=Enum.TextXAlignment.Center, Parent=keyBg,
    })
    applyTheme(keyLbl, "TextColor3", "accent")
    addTextShadow(keyLbl)

    local shim = {Value = currentKey}
    btn.MouseButton1Click:Connect(function()
        if binding then return end
        binding = true
        keyLbl.Text = "..."
        keyLbl.TextColor3 = Theme.yellow
        local conn
        conn = UserInputService.InputBegan:Connect(function(inp)
            if inp.UserInputType == Enum.UserInputType.Keyboard then
                shim.Value = inp.KeyCode
                currentKey = inp.KeyCode
                keyLbl.Text = tostring(inp.KeyCode):gsub("Enum.KeyCode.", "")
                keyLbl.TextColor3 = Theme.accent
                binding = false
                conn:Disconnect()
            end
        end)
    end)
    return shim
end

-- addCheckbox ─────────────────────────────────────────
local function addCheckbox(parent, cfg)
    local enabled = cfg.Default or false

    local row = mk("TextButton", {
        Size=UDim2.new(1,0,0,18), BackgroundTransparency=1, BorderSizePixel=0,
        Text="", AutoButtonColor=false, Parent=parent,
    })

    local box = mk("Frame", {
        Size=UDim2.fromOffset(12,12), Position=UDim2.fromOffset(0,3),
        BackgroundColor3=Theme.bg_deep, BorderSizePixel=2, BorderColor3=Theme.border,
        Parent=row,
    })
    applyTheme(box, "BackgroundColor3", "bg_deep")
    applyTheme(box, "BorderColor3", "border")
    addStroke(box, "outline", 1)
    addVertGradient(box)

    local tick = mk("TextLabel", {
        Size=UDim2.fromScale(1,1), BackgroundTransparency=1,
        Text="✓", TextColor3=Theme.accent, FontFace=UIFontBold, TextSize=9,
        TextXAlignment=Enum.TextXAlignment.Center, Visible=enabled, Parent=box,
    })
    applyTheme(tick, "TextColor3", "accent")

    local lbl = mk("TextLabel", {
        Size=UDim2.new(1,-20,1,0), Position=UDim2.fromOffset(20,0),
        BackgroundTransparency=1, Text=cfg.Label or "",
        TextColor3=Theme.txt, FontFace=UIFont, TextSize=11,
        TextXAlignment=Enum.TextXAlignment.Left, Parent=row,
    })
    addTextShadow(lbl)

    local shim = {Value = enabled}
    local function setState(v)
        shim.Value = v
        tick.Visible = v
        if v then
            tw(box, {BackgroundColor3 = Theme.accent_dim})
        else
            tw(box, {BackgroundColor3 = Theme.bg_deep})
        end
        if cfg.Callback then cfg.Callback(shim) end
    end
    row.MouseButton1Click:Connect(function() setState(not shim.Value) end)
    setState(enabled)
    return shim
end

-- addTextbox ──────────────────────────────────────────
local function addTextbox(parent, cfg)
    local wrap = mk("Frame", {
        Size=UDim2.new(1,0,0,22), BackgroundTransparency=1, BorderSizePixel=0, Parent=parent,
    })
    mk("TextLabel", {
        Size=UDim2.new(0.38,0,1,0), BackgroundTransparency=1,
        Text=cfg.Label or "", TextColor3=Theme.txt_muted,
        FontFace=UIFont, TextSize=10, TextXAlignment=Enum.TextXAlignment.Left,
        Parent=wrap,
    })
    local box = mk("TextBox", {
        Size=UDim2.new(0.62,0,1,0), Position=UDim2.fromScale(0.38,0),
        BackgroundColor3=Theme.bg_element, BorderSizePixel=2, BorderColor3=Theme.border,
        Text=tostring(cfg.Value or ""), PlaceholderText=cfg.Placeholder or "",
        PlaceholderColor3=Theme.txt_dim, TextColor3=Theme.txt,
        FontFace=UIFont, TextSize=11, TextXAlignment=Enum.TextXAlignment.Left,
        ClearTextOnFocus=false, Parent=wrap,
    })
    applyTheme(box, "BackgroundColor3", "bg_element")
    applyTheme(box, "BorderColor3", "border")
    mk("UIPadding", {PaddingLeft=UDim.new(0,5), PaddingRight=UDim.new(0,4), Parent=box})
    local bxStroke = addStroke(box, "outline", 1)

    box.Focused:Connect(function()
        tw(bxStroke, {Color = Theme.accent, Transparency = 0.3})
        tw(box, {TextColor3 = Theme.accent})
    end)
    box.FocusLost:Connect(function()
        tw(bxStroke, {Color = Theme.outline, Transparency = 0})
        tw(box, {TextColor3 = Theme.txt})
        if cfg.Callback then cfg.Callback(box, box.Text) end
    end)

    local shim = {Value = cfg.Value or ""}
    setmetatable(shim, {
        __index = function(_, k) if k == "Value" then return box.Text end end,
        __newindex = function(_, k, v) if k == "Value" then box.Text = tostring(v) end end,
    })
    function shim:SetValue(v) box.Text = tostring(v) end
    return shim
end

-- addCombo (dropdown) ─────────────────────────────────
local function addCombo(parent, cfg)
    local selected = ""
    local open = false

    local wrap = mk("Frame", {
        Size=UDim2.new(1,0,0,22), BackgroundTransparency=1, BorderSizePixel=0, Parent=parent,
    })
    mk("TextLabel", {
        Size=UDim2.new(0.38,0,1,0), BackgroundTransparency=1,
        Text=cfg.Text or "", TextColor3=Theme.txt_muted,
        FontFace=UIFont, TextSize=10, TextXAlignment=Enum.TextXAlignment.Left,
        Parent=wrap,
    })

    local dropBtn = mk("TextButton", {
        Size=UDim2.new(0.62,0,1,0), Position=UDim2.fromScale(0.38,0),
        BackgroundColor3=Theme.bg_element, BorderSizePixel=2, BorderColor3=Theme.border,
        Text="  "..(cfg.Placeholder or "select..."), TextColor3=Theme.txt_muted,
        FontFace=UIFont, TextSize=10, TextXAlignment=Enum.TextXAlignment.Left,
        AutoButtonColor=false, Parent=wrap,
    })
    applyTheme(dropBtn, "BackgroundColor3", "bg_element")
    applyTheme(dropBtn, "BorderColor3", "border")
    addStroke(dropBtn, "outline", 1)

    mk("TextLabel", {
        Size=UDim2.fromOffset(16,22), Position=UDim2.new(1,-18,0,0),
        BackgroundTransparency=1, Text="▾", TextColor3=Theme.txt_dim,
        FontFace=UIFontBold, TextSize=11, Parent=dropBtn,
    })

    -- Floating list
    local listFrame = mk("Frame", {
        BackgroundColor3=Theme.bg_deep, BorderSizePixel=2, BorderColor3=Theme.border,
        Visible=false, ZIndex=10, Size=UDim2.fromOffset(0,0), Parent=DropdownGui,
    })
    applyTheme(listFrame, "BackgroundColor3", "bg_deep")
    applyTheme(listFrame, "BorderColor3", "border")
    addStroke(listFrame, "outline", 1)
    mk("UIListLayout", {FillDirection=Enum.FillDirection.Vertical, SortOrder=Enum.SortOrder.LayoutOrder,
        Padding=UDim.new(0,0), Parent=listFrame})

    local shim = {Value = ""}

    local function buildList()
        for _, ch in ipairs(listFrame:GetChildren()) do
            if ch:IsA("TextButton") then ch:Destroy() end
        end
        local items = (cfg.GetItems and cfg.GetItems()) or cfg.Items or {}
        listFrame.Size = UDim2.fromOffset(dropBtn.AbsoluteSize.X, math.min(#items, 8) * 20)
        for _, item in ipairs(items) do
            local opt = mk("TextButton", {
                Size=UDim2.new(1,0,0,20), BackgroundTransparency=1, BorderSizePixel=0,
                Text="  "..tostring(item), TextColor3=Theme.txt_muted,
                FontFace=UIFont, TextSize=10, TextXAlignment=Enum.TextXAlignment.Left,
                AutoButtonColor=false, ZIndex=11, Parent=listFrame,
            })
            opt.MouseEnter:Connect(function()
                opt.BackgroundTransparency = 0.85
                tw(opt, {TextColor3 = Theme.accent})
            end)
            opt.MouseLeave:Connect(function()
                opt.BackgroundTransparency = 1
                tw(opt, {TextColor3 = Theme.txt_muted})
            end)
            opt.MouseButton1Click:Connect(function()
                selected = tostring(item); shim.Value = selected
                dropBtn.Text = "  "..selected; dropBtn.TextColor3 = Theme.txt
                listFrame.Visible = false; open = false
                if cfg.Callback then cfg.Callback(shim, item) end
            end)
        end
    end

    dropBtn.MouseButton1Click:Connect(function()
        open = not open
        if open then
            buildList()
            local abs = dropBtn.AbsolutePosition
            listFrame.Position = UDim2.fromOffset(abs.X, abs.Y + 23)
            listFrame.Visible = true
        else listFrame.Visible = false end
    end)
    UserInputService.InputBegan:Connect(function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1 and open then
            task.wait()
            local mx, my = inp.Position.X, inp.Position.Y
            local ap, as = listFrame.AbsolutePosition, listFrame.AbsoluteSize
            if not (mx >= ap.X and mx <= ap.X+as.X and my >= ap.Y and my <= ap.Y+as.Y) then
                listFrame.Visible = false; open = false
            end
        end
    end)
    return shim
end

-- makeConsole ─────────────────────────────────────────
local function makeConsole(parent)
    local frame = mk("Frame", {
        Size=UDim2.fromScale(1,1), BackgroundColor3=Theme.bg_deep, BorderSizePixel=0, Parent=parent,
    })
    applyTheme(frame, "BackgroundColor3", "bg_deep")

    local sf = mk("ScrollingFrame", {
        Size=UDim2.new(1,0,1,-26), BackgroundTransparency=1, BorderSizePixel=0,
        ScrollBarThickness=2, ScrollBarImageColor3=Theme.accent_dim,
        CanvasSize=UDim2.fromScale(0,0), AutomaticCanvasSize=Enum.AutomaticSize.Y,
        Parent=frame,
    })
    mk("UIPadding", {PaddingTop=UDim.new(0,4), PaddingBottom=UDim.new(0,4),
        PaddingLeft=UDim.new(0,6), PaddingRight=UDim.new(0,6), Parent=sf})
    mk("UIListLayout", {FillDirection=Enum.FillDirection.Vertical, SortOrder=Enum.SortOrder.LayoutOrder,
        Padding=UDim.new(0,2), Parent=sf})

    -- Prompt bar
    local promptBar = mk("Frame", {
        Size=UDim2.new(1,0,0,26), Position=UDim2.new(0,0,1,-26),
        BackgroundColor3=Theme.bg_inline, BorderSizePixel=0, Parent=frame,
    })
    applyTheme(promptBar, "BackgroundColor3", "bg_inline")

    -- Top border
    mk("Frame", {Size=UDim2.new(1,0,0,1), BackgroundColor3=Theme.outline, BorderSizePixel=0, Parent=promptBar})

    -- Accent left edge
    mk("Frame", {Size=UDim2.new(0,2,1,0), BackgroundColor3=Theme.accent, BorderSizePixel=0, Parent=promptBar})

    mk("TextLabel", {
        Size=UDim2.fromOffset(14,26), Position=UDim2.fromOffset(6,0),
        BackgroundTransparency=1, Text=">", TextColor3=Theme.accent_glow,
        FontFace=UIFont, TextSize=13, TextXAlignment=Enum.TextXAlignment.Center,
        Parent=promptBar,
    })

    local inputBox = mk("TextBox", {
        Size=UDim2.new(1,-22,1,0), Position=UDim2.fromOffset(20,0),
        BackgroundTransparency=1, BorderSizePixel=0,
        Text="", PlaceholderText="enter command...", PlaceholderColor3=Theme.txt_dim,
        TextColor3=Theme.accent, FontFace=UIFont, TextSize=11,
        TextXAlignment=Enum.TextXAlignment.Left, ClearTextOnFocus=false,
        Parent=promptBar,
    })
    mk("UIPadding", {PaddingLeft=UDim.new(0,4), PaddingRight=UDim.new(0,4), Parent=inputBox})

    local consoleShim = {Callback = nil}

    function consoleShim:AppendText(...)
        local parts = {}
        for _, v in ipairs({...}) do parts[#parts+1] = tostring(v) end
        local msg = table.concat(parts, " ")

        local lbl = mk("TextLabel", {
            Size=UDim2.new(1,0,0,0), AutomaticSize=Enum.AutomaticSize.Y,
            BackgroundTransparency=1, Text=msg, RichText=false,
            TextColor3=Theme.txt_muted, FontFace=UIFont, TextSize=11,
            TextXAlignment=Enum.TextXAlignment.Left, TextWrapped=true, Parent=sf,
        })
        local lo = msg:lower()
        if lo:find("error") or lo:find("fail") or lo:find("warn") then
            lbl.TextColor3 = Theme.yellow
        elseif lo:find("loaded") or lo:find("saved") or lo:find("done") or lo:find("ok") then
            lbl.TextColor3 = Theme.green
        elseif lo:find("reading") or lo:find("decod") or lo:find("encod") then
            lbl.TextColor3 = Theme.cyan
        end

        task.defer(function()
            sf.CanvasPosition = Vector2.new(0, sf.AbsoluteCanvasSize.Y)
        end)
    end

    inputBox.FocusLost:Connect(function(enter)
        if enter and #inputBox.Text > 0 then
            local txt = inputBox.Text; inputBox.Text = ""
            if consoleShim.Callback then
                local shimSelf = {Clear = function() inputBox.Text = "" end}
                consoleShim.Callback(shimSelf, txt)
            end
        end
    end)

    local inputShim = {}
    setmetatable(inputShim, {
        __newindex = function(_, k, v) if k == "Callback" then consoleShim.Callback = v end end,
        __index = function(_, k) if k == "Callback" then return consoleShim.Callback end end,
    })
    return consoleShim, inputShim
end

-- makePopup ───────────────────────────────────────────
local function makePopup(title)
    local overlay = mk("Frame", {
        Size=UDim2.fromScale(1,1), BackgroundColor3=Color3.new(0,0,0),
        BackgroundTransparency=0.5, BorderSizePixel=0, ZIndex=9000, Parent=RootGui,
    })
    local box = mk("Frame", {
        Size=UDim2.fromOffset(320,0), AutomaticSize=Enum.AutomaticSize.Y,
        Position=UDim2.fromScale(0.5,0.5), AnchorPoint=Vector2.new(0.5,0.5),
        BackgroundColor3=Theme.bg_window, BorderSizePixel=2, BorderColor3=Theme.border,
        ZIndex=9001, Parent=overlay,
    })
    applyTheme(box, "BackgroundColor3", "bg_window")
    applyTheme(box, "BorderColor3", "border")
    addStroke(box, "outline", 1)

    -- Popup header
    addAccentLine(box, UDim2.fromOffset(0,0), UDim2.new(1,0,0,2))
    local popHdr = mk("Frame", {
        Size=UDim2.new(1,0,0,26), BackgroundColor3=Theme.bg_deep,
        BorderSizePixel=0, ZIndex=9002, Parent=box,
    })
    applyTheme(popHdr, "BackgroundColor3", "bg_deep")

    mk("TextLabel", {
        Size=UDim2.new(1,0,1,0), BackgroundTransparency=1,
        Text=title:upper(), TextColor3=Theme.accent,
        FontFace=UIFontBold, TextSize=11, ZIndex=9002, Parent=popHdr,
    })

    mk("Frame", {
        Size=UDim2.new(1,0,0,1), Position=UDim2.new(0,0,1,-1),
        BackgroundColor3=Theme.outline, BorderSizePixel=0, ZIndex=9002, Parent=popHdr,
    })

    local body = mk("Frame", {
        Size=UDim2.new(1,0,0,0), AutomaticSize=Enum.AutomaticSize.Y,
        Position=UDim2.fromOffset(0,26), BackgroundTransparency=1,
        BorderSizePixel=0, ZIndex=9002, Parent=box,
    })
    mk("UIPadding", {PaddingTop=UDim.new(0,8), PaddingBottom=UDim.new(0,10),
        PaddingLeft=UDim.new(0,10), PaddingRight=UDim.new(0,10), Parent=body})
    mk("UIListLayout", {FillDirection=Enum.FillDirection.Vertical, SortOrder=Enum.SortOrder.LayoutOrder,
        Padding=UDim.new(0,6), Parent=body})

    local popup = {}
    function popup:Textbox(c) return addTextbox(body, {Label=c.Text or "", Placeholder=c.Placeholder or "", Callback=c.Callback}) end
    function popup:Combo(c) return addCombo(body, c) end
    function popup:Button(c) addButton(body, c.Text or "ok", function() if c.Callback then c.Callback() end end) end
    function popup:ClosePopup() overlay:Destroy() end
    return popup
end

-- ══════════════════════════════════════════════════════════════════════════════
--  BUILD THE UI
-- ══════════════════════════════════════════════════════════════════════════════

local controlsPage = addTab("controls")
local physicsPage  = addTab("physics")
local visualsPage  = addTab("visuals")
local consolePage  = addTab("console")
local settingsPage = addTab("settings")
switchTab("controls")

-- ── INFO SECTION ─────────────────────────────────────────────────────────────
local infoSec = addSection(controlsPage, "info")

RecordedFramesLabel    = addLabel(infoSec, "Frames: 0")
PressedKeysLabel       = addLabel(infoSec, "Pressed keys: |")
WritingPressedKeysLabel = addLabel(infoSec, "Writing Pressed keys: |")

-- ColorCodeFrame shim
do
    local _cfLbl = mk("TextLabel", {
        Size=UDim2.new(1,0,0,14), BackgroundTransparency=1,
        Text="Status: Idle", TextColor3=Theme.txt,
        FontFace=UIFontBold, TextSize=11, TextXAlignment=Enum.TextXAlignment.Left,
        Parent=infoSec,
    })
    addTextShadow(_cfLbl)
    ColorCodeFrame = {}
    setmetatable(ColorCodeFrame, {
        __newindex = function(_, k, v)
            if k == "Text" then _cfLbl.Text = v
            elseif k == "TextColor3" then _cfLbl.TextColor3 = v end
        end,
        __index = function(_, k)
            if k == "Text" then return _cfLbl.Text end
            if k == "TextColor3" then return _cfLbl.TextColor3 end
            return nil
        end,
    })
end

ConnectedLabel = addLabel(infoSec, "AHK folder not found")

do
    local _cpBtn = addButton(infoSec, "Place id: "..tostring(PlaceId), function()
        if setclipboard then setclipboard(tostring(PlaceId)) end
    end)
    CurrentPlaceIdButton = _cpBtn
end

local _currentFileLbl = addLabel(infoSec, "Current File: ")
CurrentFile = _currentFileLbl

-- ── CONTROLS SECTION ─────────────────────────────────────────────────────────
local ctrlSec = addSection(controlsPage, "controls")

-- Frozen → Idle row
local FrozenRow = addRow(ctrlSec)
FrozenRow:Button({Text = "Frozen → Idle", Callback = function() IdleButton_MouseButton1Click() end})
Frozenkeybind = FrozenRow:Keybind({Label = "keybind", Value = Enum.KeyCode.M})

-- Pause keybind
Pausekeybind = addKeybind(ctrlSec, {Label = "Pause / Resume", Value = Enum.KeyCode.R})

-- Ignore game processed
IgnoreGameProcessedButton = addCheckbox(ctrlSec, {
    Label = "Ignore Game Processed", Default = false,
    Callback = function() IgnoreGameProcessed = not IgnoreGameProcessed end,
})

-- Keyboard overlay themes
local KeyboardOverlayThemes = {
    ["Default"] = {
        create = function(container)
            local function createKey(name, position, size, displayText)
                local key = Instance.new("TextLabel")
                key.Name=name; key.Size=size; key.Position=position
                key.BackgroundColor3=Color3.fromRGB(35,35,42); key.BorderSizePixel=0
                key.Text=displayText or name; key.TextColor3=Color3.fromRGB(220,220,230)
                key.TextSize=(size.X.Offset>70) and 14 or 18; key.Font=Enum.Font.GothamBold
                key.Parent=container
                Instance.new("UICorner",key).CornerRadius=UDim.new(0,6)
                local stroke=Instance.new("UIStroke",key)
                stroke.Color=Color3.fromRGB(60,60,70); stroke.Thickness=2; stroke.Transparency=0.5
                return key
            end
            local ks = UDim2.fromOffset(45,45)
            local W=createKey("W",UDim2.fromOffset(120,10),ks)
            local A=createKey("A",UDim2.fromOffset(65,65),ks)
            local S=createKey("S",UDim2.fromOffset(120,65),ks)
            local D=createKey("D",UDim2.fromOffset(175,65),ks)
            local CL=createKey("CapsLock",UDim2.fromOffset(5,65),UDim2.fromOffset(50,45),"CAPS"); CL.TextSize=12
            local SH=createKey("LeftShift",UDim2.fromOffset(5,120),UDim2.fromOffset(50,45),"SHIFT"); SH.TextSize=12
            local SL=createKey("Slash",UDim2.fromOffset(175,10),UDim2.fromOffset(45,45),"/")
            local SP=createKey("Space",UDim2.fromOffset(65,120),UDim2.fromOffset(210,45),""); SP.TextSize=14
            return {W=W,A=A,S=S,D=D,LeftShift=SH,RightShift=SH,Space=SP,CapsLock=CL,Slash=SL}
        end,
        size = UDim2.fromOffset(320,200),
        updateColors = function(keyFrame, state)
            if state == "writing" then
                keyFrame.BackgroundColor3 = Color3.fromRGB(200,180,80)
            elseif state == "pressed" then
                keyFrame.BackgroundColor3 = Color3.fromRGB(80,200,120)
            else
                keyFrame.BackgroundColor3 = Color3.fromRGB(35,35,42)
            end
        end
    },
}
local currentTheme = "Default"

KeyboardOverlay = addCheckbox(ctrlSec, {
    Label = "Keyboard Overlay", Default = false,
    Callback = function(self)
        local enabled = self.Value
        if enabled then
            getgenv().KeyboardOverlayEnabled = true
            if not getgenv().KeyboardOverlayGui then
                local overlayGui = Instance.new("ScreenGui")
                overlayGui.Name="KeyboardOverlay"; overlayGui.ZIndexBehavior=Enum.ZIndexBehavior.Sibling
                overlayGui.ResetOnSpawn=false; overlayGui.DisplayOrder=9999; overlayGui.Parent=Player.PlayerGui
                local container = Instance.new("Frame")
                container.Name="Container"; container.Size=KeyboardOverlayThemes[currentTheme].size
                container.Position=UDim2.new(0,20,1,-container.Size.Y.Offset-20)
                container.BackgroundTransparency=1; container.BorderSizePixel=0; container.Parent=overlayGui
                local keys = KeyboardOverlayThemes[currentTheme].create(container)
                getgenv().KeyboardOverlayGui = overlayGui
                getgenv().KeyboardOverlayContainer = container
                getgenv().KeyboardOverlayKeys = keys
            else getgenv().KeyboardOverlayGui.Enabled = true end
        else
            getgenv().KeyboardOverlayEnabled = false
            if getgenv().KeyboardOverlayGui then getgenv().KeyboardOverlayGui.Enabled = false end
        end
    end,
})

KeyboardThemeCombo = addCombo(ctrlSec, {
    Text = "Overlay Theme", Placeholder = "Default",
    GetItems = function() return {"Default"} end,
    Callback = function(_, sel)
        if sel and KeyboardOverlayThemes[sel] then
            currentTheme = sel; ConsoleMessage("Keyboard theme changed to: "..sel)
        end
    end,
})

DisableParticles = addCheckbox(ctrlSec, {
    Label = "Disable Particle Emitters", Default = false,
    Callback = function(self)
        for _, obj in pairs(workspace:GetDescendants()) do
            if obj:IsA("ParticleEmitter") then obj.Enabled = not self.Value end
        end
    end,
})

DisableLighting = addCheckbox(ctrlSec, {
    Label = "Disable Lighting Effects", Default = false,
    Callback = function(self)
        local Lighting = game:GetService("Lighting")
        if self.Value then
            if not getgenv().OriginalLightingSettings then
                getgenv().OriginalLightingSettings = {
                    Ambient=Lighting.Ambient, Brightness=Lighting.Brightness,
                    GlobalShadows=Lighting.GlobalShadows, ClockTime=Lighting.ClockTime,
                }
            end
            Lighting.Ambient=Color3.fromRGB(255,255,255); Lighting.Brightness=2
            Lighting.GlobalShadows=false; Lighting.ClockTime=14
            for _, obj in pairs(Lighting:GetChildren()) do
                if obj:IsA("BloomEffect") or obj:IsA("BlurEffect") or obj:IsA("ColorCorrectionEffect")
                    or obj:IsA("SunRaysEffect") or obj:IsA("DepthOfFieldEffect") then
                    obj.Enabled = false
                end
            end
        else
            if getgenv().OriginalLightingSettings then
                for k, v in pairs(getgenv().OriginalLightingSettings) do Lighting[k] = v end
            end
            for _, obj in pairs(Lighting:GetChildren()) do
                if obj:IsA("BloomEffect") or obj:IsA("BlurEffect") or obj:IsA("ColorCorrectionEffect")
                    or obj:IsA("SunRaysEffect") or obj:IsA("DepthOfFieldEffect") then
                    obj.Enabled = true
                end
            end
        end
    end,
})

MotionBlurToggle = addCheckbox(ctrlSec, {
    Label = "Motion Blur", Default = false,
    Callback = function(self)
        local Lighting = game:GetService("Lighting")
        if self.Value then
            if not Lighting:FindFirstChild("TasabilityMotionBlur") then
                local blur = Instance.new("BlurEffect"); blur.Name="TasabilityMotionBlur"; blur.Size=3; blur.Parent=Lighting
            end
        else
            local blur = Lighting:FindFirstChild("TasabilityMotionBlur")
            if blur then blur:Destroy() end
        end
    end,
})

movecameraonfroze = addCheckbox(ctrlSec, {Label = "Move camera while frozen", Default = false})

-- Read row
local ReadRow = addRow(ctrlSec)
ReadRow:Button({Text = "Read", Callback = function() ReadButton_MouseButton1Click() end})
Readkeybind = ReadRow:Keybind({Label = "keybind", Value = Enum.KeyCode.Z})

-- Abort row
local AbortRow = addRow(ctrlSec)
AbortRow:Button({Text = "Abort", Callback = function() StopReading(true) end})
Abortkeybind = AbortRow:Keybind({Label = "keybind", Value = Enum.KeyCode.L})

Hideuikeybind              = addKeybind(ctrlSec, {Label = "Hide UI",                  Value = Enum.KeyCode.U})
Recordkeybind              = addKeybind(ctrlSec, {Label = "Record / Freeze",           Value = Enum.KeyCode.E})
Goforwardkeybind           = addKeybind(ctrlSec, {Label = "Go forward",               Value = Enum.KeyCode.T})
Gobackwardskeybind         = addKeybind(ctrlSec, {Label = "Go backwards",             Value = Enum.KeyCode.Q})
Frameadvanceforwardkeybind = addKeybind(ctrlSec, {Label = "Frame advance forward",    Value = Enum.KeyCode.G})
Frameadvancebackwardskeybind = addKeybind(ctrlSec, {Label = "Frame advance backward", Value = Enum.KeyCode.F})
Savekeybind                = addKeybind(ctrlSec, {Label = "Save to file",             Value = Enum.KeyCode.P})

-- Rejoin
addButton(ctrlSec, "Rejoin", function()
    ConsoleMessage("Rejoining...")
    SaveToFile()
    task.wait(0.5)
    if #game.Players:GetPlayers() <= 1 then
        game.Players.LocalPlayer:Kick("\nRejoining...")
        task.wait()
        game:GetService("TeleportService"):Teleport(game.PlaceId, game.Players.LocalPlayer)
    else
        game:GetService("TeleportService"):TeleportToPlaceInstance(game.PlaceId, game.JobId, game.Players.LocalPlayer)
    end
end)

-- FPS textbox
FPSTextbox = addTextbox(ctrlSec, {
    Label = "FPS Cap", Value = tostring(FPS), Placeholder = "Enter FPS...",
    Callback = function(_, value)
        local newFPS = tonumber(value)
        if newFPS and newFPS > 0 and newFPS <= 1000 then
            FPS = newFPS
            if setfpscap then
                setfpscap(FPS)
            end
            ConsoleMessage("FPS set to "..tostring(FPS))
        end
    end,
})

TASRecordingFPSTextbox = addTextbox(ctrlSec, {
    Label = "TAS Recording FPS", Value = tostring(TASRecordingFPS), Placeholder = "Enter recording FPS...",
    Callback = function(_, value)
        local newFPS = tonumber(value)
        if newFPS and newFPS > 0 and newFPS <= 1000 then
            TASRecordingFPS = newFPS
            ConsoleMessage("TAS Recording FPS set to "..tostring(TASRecordingFPS).." (actual sampling rate)")
        end
    end,
})

addButton(ctrlSec, "Reset Recording", function()
    ResetCurrentRecording()
end)

-- Teleport
TeleportTextbox = addTextbox(ctrlSec, {Label = "Teleport PlaceId", Placeholder = "Enter PlaceId..."})
addButton(ctrlSec, "Teleport", function()
    local placeId = tonumber(TeleportTextbox.Value)
    if placeId and placeId > 0 then
        ConsoleMessage("Teleporting to: "..tostring(placeId))
        SaveToFile(); task.wait(0.5)
        pcall(function() game:GetService("TeleportService"):Teleport(placeId, game.Players.LocalPlayer) end)
    else ConsoleMessage("Invalid PlaceId") end
end)

-- ── FILE MANAGEMENT SECTION ──────────────────────────────────────────────────
local fileSec = addSection(controlsPage, "file management")

addButton(fileSec, "Save to File", function() SaveToFile() end)

addButton(fileSec, "Create File", function()
    local popup = makePopup("Create file")
    popup:Textbox({Text = "File name", Placeholder = "name...", Callback = function(_, name)
        if #name > 0 then
            writefile(FolderPath.."./".."name"..".tas", "")
            ReplayTable = {}
            ReplaySaveState.Version = ReplaySaveState.Version + 1
            ReplaySaveState.Encoded = nil
            ReplaySaveState.EncodedVersion = -1
            ReplayPath = FolderPath.."./"..name..".tas"
        end
    end})
    popup:Button({Text = "Done", Callback = function() popup:ClosePopup() end})
end)

addButton(fileSec, "Load File", function()
    local popup = makePopup("Load file")
    popup:Combo({Text = "Select file", Placeholder = "select...",
        GetItems = function() return listfiles(FolderPath) end,
        Callback = function(_, path)
            if not path then return end
            ConsoleMessage("Loading: "..path)
            ReplayPath = path
            if path ~= LastLoadedPath or ReplayNeedsReload then
                local fc = readfile(path)
                if #fc > #ReplayFileBeginning then
                    ReplayTable = ReplayDecode(fc)
                    ReplaySaveState.Version = ReplaySaveState.Version + 1
                    ReplaySaveState.Encoded = (type(fc) == "string" and fc:sub(1, 4) == "TAS5") and fc or nil
                    ReplaySaveState.EncodedVersion = ReplaySaveState.Encoded and ReplaySaveState.Version or -1
                    ReplayNeedsReload = false; LastLoadedPath = path
                    ConsoleMessage("Decoded and cached replay")
                else
                    ReplayTable = {}
                    ReplaySaveState.Version = ReplaySaveState.Version + 1
                    ReplaySaveState.Encoded = nil
                    ReplaySaveState.EncodedVersion = -1
                    ReplayNeedsReload = false; LastLoadedPath = path
                    ConsoleMessage("File is empty")
                end
            else ConsoleMessage("Using cached replay") end
        end,
    })
    popup:Button({Text = "Done", Callback = function() popup:ClosePopup() end})
end)

addButton(fileSec, "Delete File", function()
    local popup = makePopup("Delete file")
    local filePick = popup:Combo({Text = "Select file", Placeholder = "select...",
        GetItems = function() return listfiles(FolderPath) end,
    })
    popup:Button({Text = "Delete", Callback = function()
        popup:ClosePopup()
        if filePick.Value and #filePick.Value > 0 then delfile(filePick.Value) end
    end})
end)

-- ── PHYSICS SECTION ──────────────────────────────────────────────────────────
local physSec = addSection(physicsPage, "physics modifiers")

WalkSpeedTextbox = addTextbox(physSec, {Label = "WalkSpeed", Value = "16", Placeholder = "16",
    Callback = function(_, v)
        local n = tonumber(v)
        if n and Character and Character:FindFirstChild("Humanoid") then
            Character.Humanoid.WalkSpeed = n; DefaultWalkSpeed = n
        end
    end})
JumpPowerTextbox = addTextbox(physSec, {Label = "JumpPower", Value = "50", Placeholder = "50",
    Callback = function(_, v)
        local n = tonumber(v)
        if n and Character and Character:FindFirstChild("Humanoid") then
            Character.Humanoid.JumpPower = n; DefaultJumpPower = n
        end
    end})
GravityTextbox = addTextbox(physSec, {Label = "Gravity", Value = "196.2", Placeholder = "196.2",
    Callback = function(_, v)
        local n = tonumber(v)
        if n then DefaultGravity = n; if not Reading and not Frozen then workspace.Gravity = n end end
    end})
FrictionTextbox = addTextbox(physSec, {Label = "Friction", Value = "0.3", Placeholder = "0.3",
    Callback = function(_, v)
        local n = tonumber(v)
        if n and Character and Character:FindFirstChild("HumanoidRootPart") then
            local hrp = Character.HumanoidRootPart
            local cur = hrp.CustomPhysicalProperties
            hrp.CustomPhysicalProperties = PhysicalProperties.new(cur and cur.Density or 0.7, n, cur and cur.Elasticity or 0.5, 1, 1)
        end
    end})
DensityTextbox = addTextbox(physSec, {Label = "Density", Value = "0.7", Placeholder = "0.7",
    Callback = function(_, v)
        local n = tonumber(v)
        if n and Character and Character:FindFirstChild("HumanoidRootPart") then
            local hrp = Character.HumanoidRootPart
            local cur = hrp.CustomPhysicalProperties
            hrp.CustomPhysicalProperties = PhysicalProperties.new(n, cur and cur.Friction or 0.3, cur and cur.Elasticity or 0.5, 1, 1)
        end
    end})

addButton(physSec, "Apply Physics", function()
    local ws = tonumber(WalkSpeedTextbox.Value)
    local jp = tonumber(JumpPowerTextbox.Value)
    local grav = tonumber(GravityTextbox.Value)
    local fric = tonumber(FrictionTextbox.Value)
    local den = tonumber(DensityTextbox.Value)
    if Character then
        local hum = Character:FindFirstChild("Humanoid")
        local hrp = Character:FindFirstChild("HumanoidRootPart")
        if hum then
            if ws then hum.WalkSpeed = ws; DefaultWalkSpeed = ws end
            if jp then hum.JumpPower = jp; DefaultJumpPower = jp end
        end
        if grav then DefaultGravity = grav; if not Reading and not Frozen then workspace.Gravity = grav end end
        if hrp and fric and den then
            hrp.CustomPhysicalProperties = PhysicalProperties.new(den, fric, 0.5, 1, 1)
        end
    end
    ConsoleMessage("Physics applied")
end)

addButton(physSec, "Reset Physics", function()
    if Character then
        local hum = Character:FindFirstChild("Humanoid")
        local hrp = Character:FindFirstChild("HumanoidRootPart")
        if hum then hum.WalkSpeed=16; hum.JumpPower=50; DefaultWalkSpeed=16; DefaultJumpPower=50 end
        workspace.Gravity=196.2; DefaultGravity=196.2
        if hrp then hrp.CustomPhysicalProperties = PhysicalProperties.new(0.7, 0.3, 0.5, 1, 1) end
    end
    WalkSpeedTextbox:SetValue("16"); JumpPowerTextbox:SetValue("50")
    GravityTextbox:SetValue("196.2"); FrictionTextbox:SetValue("0.3"); DensityTextbox:SetValue("0.7")
    ConsoleMessage("Physics reset")
end)

-- ── VISUALS SECTION ──────────────────────────────────────────────────────────
local visSec = addSection(visualsPage, "visuals")

addCheckbox(visSec, {Label = "Stats HUD", Default = false, Callback = function(self)
    StatsHudEnabled = self.Value
    if StatsHudEnabled then createStatsHud() else destroyStatsHud() end
end})
addCheckbox(visSec, {Label = "Trajectory Tracer", Default = false, Callback = function(self)
    TracerEnabled = self.Value
    if not TracerEnabled then clearTracerLines() end
end})
addTextbox(visSec, {Label = "Tracer Lookahead (s)", Value = tostring(TRACER_LOOKAHEAD),
    Callback = function(_, v)
        local n = tonumber(v)
        if n and n > 0 and n <= 5 then TRACER_LOOKAHEAD = n end
    end})
addTextbox(visSec, {Label = "Tracer Steps", Value = tostring(TRACER_STEPS),
    Callback = function(_, v)
        local n = tonumber(v)
        if n and n > 0 and n <= 100 then TRACER_STEPS = math.floor(n); clearTracerLines() end
    end})

-- ── CONSOLE TAB ──────────────────────────────────────────────────────────────
local consoleTabFrame = mk("Frame", {
    Size=UDim2.fromScale(1,1), BackgroundColor3=Theme.bg_deep,
    BorderSizePixel=0, Visible=false, Parent=ContentFrame,
})
applyTheme(consoleTabFrame, "BackgroundColor3", "bg_deep")
tabPages["console"] = consoleTabFrame

local _console, _consoleInput = makeConsole(consoleTabFrame)
console = _console
ConsoleInput = _consoleInput

-- ── SETTINGS TAB ─────────────────────────────────────────────────────────────
-- Theme section
local themeSec = addSection(settingsPage, "theme")

addCombo(themeSec, {
    Text = "Theme Preset", Placeholder = "Midnight Blue",
    GetItems = function()
        local names = {}
        for k in pairs(ThemePresets) do table.insert(names, k) end
        table.sort(names)
        return names
    end,
    Callback = function(_, presetName)
        if presetName then setThemePreset(presetName); ConsoleMessage("Theme set to: "..presetName) end
    end,
})

addLabel(themeSec, "Customize accent color below:")

addTextbox(themeSec, {
    Label = "Accent Hex", Value = "#64AFFF", Placeholder = "#64AFFF",
    Callback = function(_, v)
        local ok, col = pcall(function() return Color3.fromHex(v) end)
        if ok and col then
            Theme.accent = col
            Theme.accent_dim = Color3.fromRGB(
                math.floor(col.R*255*0.30), math.floor(col.G*255*0.30), math.floor(col.B*255*0.30))
            Theme.accent_glow = Color3.fromRGB(
                math.floor(col.R*255*0.80), math.floor(col.G*255*0.80), math.floor(col.B*255*0.80))
            refreshAllTheme()
            ConsoleMessage("Accent set to: "..v)
        end
    end,
})

-- File settings section
local fileSettingsSec = addSection(settingsPage, "replay file")

addLabel(fileSettingsSec, "Current replay file path:")
local replayPathLabel = addLabel(fileSettingsSec, ReplayPath or "N/A")

addCombo(fileSettingsSec, {
    Text = "Select File", Placeholder = "pick a replay...",
    GetItems = function()
        local ok, files = pcall(function() return listfiles(FolderPath) end)
        return ok and files or {}
    end,
    Callback = function(_, path)
        if not path then return end
        ReplayPath = path; replayPathLabel.Text = path
        ReplayNeedsReload = true
        ConsoleMessage("Replay file set to: "..path)
    end,
})

addButton(fileSettingsSec, "Open Folder (copy path)", function()
    if setclipboard then setclipboard(FolderPath); ConsoleMessage("Copied folder path to clipboard") end
end)

-- Window settings section
local windowSec = addSection(settingsPage, "window")

addTextbox(windowSec, {
    Label = "Window Width", Value = "700", Placeholder = "700",
    Callback = function(_, v)
        local n = tonumber(v)
        if n and n >= 400 and n <= 1200 then
            MainFrame.Size = UDim2.fromOffset(n, MainFrame.Size.Y.Offset)
        end
    end,
})
addTextbox(windowSec, {
    Label = "Window Height", Value = "500", Placeholder = "500",
    Callback = function(_, v)
        local n = tonumber(v)
        if n and n >= 300 and n <= 900 then
            MainFrame.Size = UDim2.fromOffset(MainFrame.Size.X.Offset, n)
        end
    end,
})

-- ── Window shim ──────────────────────────────────────────────────────────────
Window = {}
function Window:ToggleVisibility()
    MainFrame.Visible = not MainFrame.Visible
end

-- ── Current file auto-update ─────────────────────────────────────────────────
task.spawn(function()
    repeat task.wait() until type(ReplayPath) == "string"
    local function getFileName(path)
        local parts = string.split(path, "\\")
        return parts[#parts] or path
    end
    CurrentFile.Text = "Current File: "..getFileName(ReplayPath)
    local old = ReplayPath
    while task.wait() do
        if ReplayPath ~= old then
            CurrentFile.Text = "Current File: "..getFileName(ReplayPath)
            old = ReplayPath
        end
    end
end)

-- ══════════════════════════════════════════════════════════════════════════════
--  GUI FUNCTIONS
-- ══════════════════════════════════════════════════════════════════════════════

local SetColorCodeFrame
local GetColorCodeFrame
do
    ConsoleMessage = function(...)
        setthreadidentity(8)
        console:AppendText(...)
    end

    ConsoleMessage("Tasability loading...")

    SetColorCodeFrame = function(Name)
        ColorCodeFrame.TextColor3 = ColorCodes[Name] or ColorCodes.None
        ColorCodeFrame.Text = "Status: "..(ColorCodes[Name] and Name or "None")
    end

    GetColorCodeFrame = function()
        return string.sub(ColorCodeFrame.Text, 9, #ColorCodeFrame.Text)
    end
end

do -- Anticheat bypasses
	do -- standard anti kick
		--// Variables
		
		local Players = game:GetService("Players")
		local OldNameCall = nil

		--// Anti Kick Hook
		local plr = game.Players.LocalPlayer
		OldNameCall = hookmetamethod(game, "__namecall", function(Self, ...)
			local NameCallMethod = getnamecallmethod()

			if not checkcaller() and Self == plr and NameCallMethod == "Kick" then
				if getgenv().SendNotifications == true then
					game:GetService("StarterGui"):SetCore("SendNotification", {
						Title = "Almost Kicked",
						Text = tostring(({...})[1]),
						Icon = "rbxassetid://6238540373",
						Duration = 3,
					})
				end
				
				return nil
			end
			
			return OldNameCall(Self, ...)
		end)
	end
	pcall(function() -- Practice anticheat bypass
		game.ReplicatedStorage.Remotes.Send:Destroy()
	end)
	pcall(function() -- Slad anticheat bypass
		local sendremote = game.ReplicatedStorage.DefaultChatSystemChatEvents.ChannelNameColorUpdated
		local oldspawn
		oldspawn = hookfunction(getrenv().spawn, function(...)
			if not checkcaller() and (tostring(getcallingscript()) == "Animate" or tostring(getcallingscript()) == "RbxAnimateScript") then
				return oldspawn(function()
					
				end)
			end
			return oldspawn(...)
		end)
		sendremote:Destroy()
	end)

	-- ADONIS BYPASS 

g = getinfo or debug.getinfo
d = false
h = {}

x, y = nil, nil

setthreadidentity(2)

for i, v in getgc(true) do
    if typeof(v) == "table" then
        local a = rawget(v, "Detected")
        local b = rawget(v, "Kill")
    
        if typeof(a) == "function" and not x then
            x = a
            
            local o; o = hookfunction(x, function(c, f, n)
                if c ~= "_" then
                    if d then
                        warn(`Adonis AntiCheat flagged\nMethod: {c}\nInfo: {f}`)
                    end
                end
                
                return true
            end)

            table.insert(h, x)
        end

        if rawget(v, "Variables") and rawget(v, "Process") and typeof(b) == "function" and not y then
            y = b
            local o; o = hookfunction(y, function(f)
                if d then
                    warn(`Adonis AntiCheat tried to kill (fallback): {f}`)
                end
            end)

            table.insert(h, y)
        end
    end
end

o = nil; o = hookfunction(getrenv().debug.info, newcclosure(function(...)
    local a, f = ...

    if x and a == x then
        if d then
            warn(`zins adonis bypassed`)
        end

        return coroutine.yield(coroutine.running())
    end
    
    return o(...)
end))

setthreadidentity(7)

end



-- Animation Functions
StopAllAnimations = nil -- StopAllAnimations() -> nil
Reanimate = nil -- Reanimate(Character) -> nil

GetAnimationFunctionFromId = nil -- GetAnimationFunctionFromId(Id) -> function
onDied = nil -- onDied() -> nil
onRunning = nil -- onRunning(Speed) -> nil
onJumping = nil -- onJumping() -> nil
onClimbing = nil -- onClimbing(Speed) -> nil
onGettingUp = nil -- onGettingUp() -> nil
onFreeFall = nil -- onFreeFall() -> nil
onFallingDown = nil -- onFallingDown() -> nil
onSeated = nil -- onSeated() -> nil
onPlatformStanding = nil -- onPlatformStanding() -> nil
onSwimming = nil -- onSwimming() -> nil

PlayAnimation = nil -- PlayAnimation() -> nil
setAnimationSpeed = nil -- setAnimationSpeed() -> nil

do
	StopAllAnimations = function()
		for _,v in pairs(Humanoid:GetPlayingAnimationTracks()) do 
			v:Stop()
		end
	end
	
	GetAnimationFunctionFromId = function(Id)
		return ({
			[1] = OnDied;
			[2] = onRunning;
			[3] = onJumping;
			[4] = onClimbing;
			[5] = onGettingUp;
			[6] = onFreeFall;
			[7] = onFallingDown;
			[8] = onSeated;
			[9] = onPlatformStanding;
			[10] = onSwimming;
		})[Id]
	end

	Reanimate = function(Character)
		local animateFound = false
		
	
		if not Character:FindFirstChild("Humanoid") then
			Character:WaitForChild("Humanoid", 5)
		end
		
	
		if Character:WaitForChild("Animate", 3) then
			for _, Animate in ipairs(Character:GetDescendants()) do
				if Animate:IsA("LocalScript") and Animate.Name == "Animate" then
					animateFound = true
					for _,Connection in pairs(getconnections(Animate.Changed)) do
						Connection:Disconnect()
					end
					if BypassAntiExploit then
						Animate.Disabled = true
						if setparentinternal then
							setparentinternal(Animate, game.Lighting)
						else
							ConsoleMessage("Your exploit does not support setparentinternal, expect animation glitches")
						end
					else
						Animate:Destroy()
					end
					ConsoleMessage("Animate script found and disabled")
					break
				end
			end
		end
		
	
		if not animateFound then
			ConsoleMessage("[WARNING] Animate script not found - animations will be handled manually")
		end
		
		StopAllAnimations()
		
		do -- Animate script replacement
			local Figure = Character
			local Torso = Figure:WaitForChild("Torso")
			local RightShoulder = Torso:WaitForChild("Right Shoulder")
			local LeftShoulder = Torso:WaitForChild("Left Shoulder")
			local RightHip = Torso:WaitForChild("Right Hip")
			local LeftHip = Torso:WaitForChild("Left Hip")
			local Neck = Torso:WaitForChild("Neck")
			local Humanoid = Figure:WaitForChild("Humanoid")

			local currentAnim = ""
			local currentAnimInstance = nil
			local currentAnimTrack = nil
			local currentAnimKeyframeHandler = nil
			local animTable = {}
			local animNames = { 
				idle = 	{	
							{ id = "http://www.roblox.com/asset/?id=180435571", weight = 8 },
							{ id = "http://www.roblox.com/asset/?id=180435792", weight = 1 }
						},
				walk = 	{ 	
							{ id = "http://www.roblox.com/asset/?id=180426354", weight = 10 } 
						}, 
				run = 	{
							{ id = "run.xml", weight = 10 } 
						}, 
				jump = 	{
							{ id = "http://www.roblox.com/asset/?id=125750702", weight = 12 } 
						}, 
				fall = 	{
							{ id = "http://www.roblox.com/asset/?id=180436148", weight = 9 } 
						}, 
				climb = {
							{ id = "http://www.roblox.com/asset/?id=180436334", weight = 10 } 
						}, 
				sit = 	{
							{ id = "http://www.roblox.com/asset/?id=178130996", weight = 10 } 
						},	
				toolnone = {
							{ id = "http://www.roblox.com/asset/?id=182393478", weight = 10 } 
						},
				toolslash = {
							{ id = "http://www.roblox.com/asset/?id=129967390", weight = 10 } 
						},
				toollunge = {
							{ id = "http://www.roblox.com/asset/?id=129967478", weight = 10 } 
						},
				wave = {
							{ id = "http://www.roblox.com/asset/?id=128777973", weight = 10 } 
						},
				point = {
							{ id = "http://www.roblox.com/asset/?id=128853357", weight = 10 } 
						},
				dance1 = {
							{ id = "http://www.roblox.com/asset/?id=182435998", weight = 10 }, 
							{ id = "http://www.roblox.com/asset/?id=182491037", weight = 10 }, 
							{ id = "http://www.roblox.com/asset/?id=182491065", weight = 10 } 
						},
				dance2 = {
							{ id = "http://www.roblox.com/asset/?id=182436842", weight = 10 }, 
							{ id = "http://www.roblox.com/asset/?id=182491248", weight = 10 }, 
							{ id = "http://www.roblox.com/asset/?id=182491277", weight = 10 } 
						},
				dance3 = {
							{ id = "http://www.roblox.com/asset/?id=182436935", weight = 10 }, 
							{ id = "http://www.roblox.com/asset/?id=182491368", weight = 10 }, 
							{ id = "http://www.roblox.com/asset/?id=182491423", weight = 10 } 
						},
				laugh = {
							{ id = "http://www.roblox.com/asset/?id=129423131", weight = 10 } 
						},
				cheer = {
							{ id = "http://www.roblox.com/asset/?id=129423030", weight = 10 } 
						},
			}
			local dances = {"dance1", "dance2", "dance3"}

			local emoteNames = { wave = false, point = false, dance1 = true, dance2 = true, dance3 = true, laugh = false, cheer = false}

			function configureAnimationSet(name, fileList)
				if (animTable[name] ~= nil) then
					for _, connection in pairs(animTable[name].connections) do
						connection:disconnect()
					end
				end
				animTable[name] = {}
				animTable[name].count = 0
				animTable[name].totalWeight = 0	
				animTable[name].connections = {}

				if (animTable[name].count <= 0) then
					for idx, anim in pairs(fileList) do
						animTable[name][idx] = {}
						animTable[name][idx].anim = Instance.new("Animation")
						animTable[name][idx].anim.Name = name
						animTable[name][idx].anim.AnimationId = anim.id
						animTable[name][idx].weight = anim.weight
						animTable[name].count = animTable[name].count + 1
						animTable[name].totalWeight = animTable[name].totalWeight + anim.weight
					end
				end
			end

			local animator = Humanoid and Humanoid:FindFirstChildOfClass("Animator") or nil
			if animator then
				local animTracks = animator:GetPlayingAnimationTracks()
				for i,track in ipairs(animTracks) do
					track:Stop(0)
					track:Destroy()
				end
			end

			for name, fileList in pairs(animNames) do 
				configureAnimationSet(name, fileList)
			end	

			local toolAnim = "None"
			local toolAnimTime = 0
			local jumpAnimTime = 0
			local jumpAnimDuration = 0.3
			local toolTransitionTime = 0.1
			local fallTransitionTime = 0.3
			local jumpMaxLimbVelocity = 0.75

			function stopAllAnimations()
				local oldAnim = currentAnim
				if (emoteNames[oldAnim] ~= nil and emoteNames[oldAnim] == false) then
					oldAnim = "idle"
				end
				currentAnim = ""
				currentAnimInstance = nil
				if (currentAnimKeyframeHandler ~= nil) then
					currentAnimKeyframeHandler:disconnect()
				end
				if (currentAnimTrack ~= nil) then
					currentAnimTrack:Stop()
					currentAnimTrack:Destroy()
					currentAnimTrack = nil
				end
				return oldAnim
			end

			setAnimationSpeed = function(speed)
				if speed ~= currentAnimSpeed then
					currentAnimSpeed = speed
					currentAnimTrack:AdjustSpeed(currentAnimSpeed)
				end
			end

			function keyFrameReachedFunc(frameName)
				if (frameName == "End") then
					local repeatAnim = currentAnim
					if (emoteNames[repeatAnim] ~= nil and emoteNames[repeatAnim] == false) then
						repeatAnim = "idle"
					end
					local animSpeed = currentAnimSpeed
					playAnimation(repeatAnim, 0.0, Humanoid)
					setAnimationSpeed(animSpeed)
				end
			end

			playAnimation = function(animName, transitionTime, humanoid, bypassAnimateDisabled) 
				pcall(function()
					if AnimateDisabled and not bypassAnimateDisabled then
						return
					end
					
					local lastAnimation = AnimationQueue[#AnimationQueue]
					if not lastAnimation or lastAnimation[1] ~= animName or lastAnimation[2] ~= transitionTime then
						table.insert(AnimationQueue,{animName,transitionTime})
					end
					
					local roll = math.random(1, animTable[animName].totalWeight) 
					local origRoll = roll
					local idx = 1
					while (roll > animTable[animName][idx].weight) do
						roll = roll - animTable[animName][idx].weight
						idx = idx + 1
					end
					local anim = animTable[animName][idx].anim

					if (anim ~= currentAnimInstance) then
						if (currentAnimTrack ~= nil) then
							currentAnimTrack:Stop(transitionTime)
							currentAnimTrack:Destroy()
						end
						currentAnimSpeed = 1.0
						currentAnimTrack = humanoid:LoadAnimation(anim)
						currentAnimTrack.Priority = Enum.AnimationPriority.Core
						currentAnimTrack:Play(transitionTime)
						currentAnim = animName
						currentAnimInstance = anim
						if (currentAnimKeyframeHandler ~= nil) then
							currentAnimKeyframeHandler:disconnect()
						end
						currentAnimKeyframeHandler = currentAnimTrack.KeyframeReached:connect(keyFrameReachedFunc)
					end
				end)
			end

			local toolAnimName = ""
			local toolAnimTrack = nil
			local toolAnimInstance = nil
			local currentToolAnimKeyframeHandler = nil

			function toolKeyFrameReachedFunc(frameName)
				if (frameName == "End") then
					playToolAnimation(toolAnimName, 0.0, Humanoid)
				end
			end

			function playToolAnimation(animName, transitionTime, humanoid, priority)	 
				local roll = math.random(1, animTable[animName].totalWeight) 
				local origRoll = roll
				local idx = 1
				while (roll > animTable[animName][idx].weight) do
					roll = roll - animTable[animName][idx].weight
					idx = idx + 1
				end
				local anim = animTable[animName][idx].anim
				if (toolAnimInstance ~= anim) then
					if (toolAnimTrack ~= nil) then
						toolAnimTrack:Stop()
						toolAnimTrack:Destroy()
						transitionTime = 0
					end
					toolAnimTrack = humanoid:LoadAnimation(anim)
					if priority then
						toolAnimTrack.Priority = priority
					end
					toolAnimTrack:Play(transitionTime)
					toolAnimName = animName
					toolAnimInstance = anim
					currentToolAnimKeyframeHandler = toolAnimTrack.KeyframeReached:connect(toolKeyFrameReachedFunc)
				end
			end

			function stopToolAnimations()
				local oldAnim = toolAnimName
				if (currentToolAnimKeyframeHandler ~= nil) then
					currentToolAnimKeyframeHandler:disconnect()
				end
				toolAnimName = ""
				toolAnimInstance = nil
				if (toolAnimTrack ~= nil) then
					toolAnimTrack:Stop()
					toolAnimTrack:Destroy()
					toolAnimTrack = nil
				end
				return oldAnim
			end

			onRunning = function(speed)
				if speed > 0.01 then
					playAnimation("walk", 0.1, Humanoid)
					if currentAnimInstance and currentAnimInstance.AnimationId == "http://www.roblox.com/asset/?id=180426354" then
						setAnimationSpeed(speed / 14.5)
					end
					pose = "Running"
				else
					if emoteNames[currentAnim] == nil then
						playAnimation("idle", 0.1, Humanoid)
						pose = "Standing"
					end
				end
			end

			onDied = function()
				pose = "Dead"
			end

			onJumping = function()
				playAnimation("jump", 0.1, Humanoid)
				jumpAnimTime = jumpAnimDuration
				pose = "Jumping"
			end

			onClimbing = function(speed)
				playAnimation("climb", 0.1, Humanoid)
				setAnimationSpeed(speed / 12.0)
				pose = "Climbing"
			end

			onGettingUp = function()
				pose = "GettingUp"
			end

			onFreeFall = function()
				if (jumpAnimTime <= 0) then
					playAnimation("fall", fallTransitionTime, Humanoid)
				end
				pose = "FreeFall"
			end

			onFallingDown = function()
				pose = "FallingDown"
			end

			onSeated = function()
				pose = "Seated"
			end

			onPlatformStanding = function()
				pose = "PlatformStanding"
			end

			onSwimming = function(speed)
				if speed > 0 then
					pose = "Running"
				else
					pose = "Standing"
				end
			end

			function getTool()	
				for _, kid in ipairs(Figure:GetChildren()) do
					if kid.className == "Tool" then return kid end
				end
				return nil
			end

			function getToolAnim(tool)
				for _, c in ipairs(tool:GetChildren()) do
					if c.Name == "toolanim" and c.className == "StringValue" then
						return c
					end
				end
				return nil
			end

			function animateTool()
				if (toolAnim == "None") then
					playToolAnimation("toolnone", toolTransitionTime, Humanoid, Enum.AnimationPriority.Idle)
					return
				end
				if (toolAnim == "Slash") then
					playToolAnimation("toolslash", 0, Humanoid, Enum.AnimationPriority.Action)
					return
				end
				if (toolAnim == "Lunge") then
					playToolAnimation("toollunge", 0, Humanoid, Enum.AnimationPriority.Action)
					return
				end
			end

			function moveSit()
				RightShoulder.MaxVelocity = 0.15
				LeftShoulder.MaxVelocity = 0.15
				RightShoulder:SetDesiredAngle(3.14 /2)
				LeftShoulder:SetDesiredAngle(-3.14 /2)
				RightHip:SetDesiredAngle(3.14 /2)
				LeftHip:SetDesiredAngle(-3.14 /2)
			end

			local lastTick = 0

			function move(time)
				if AnimateDisabled then
					return
				end
				
				local amplitude = 1
				local frequency = 1
				local deltaTime = time - lastTick
				lastTick = time
				local climbFudge = 0
				local setAngles = false

				if (jumpAnimTime > 0) then
					jumpAnimTime = jumpAnimTime - deltaTime
				end

				if (pose == "FreeFall" and jumpAnimTime <= 0) then
					playAnimation("fall", fallTransitionTime, Humanoid)
				elseif (pose == "Seated") then
					playAnimation("sit", 0.5, Humanoid)
					return
				elseif (pose == "Running") then
					playAnimation("walk", 0.1, Humanoid)
				elseif (pose == "Dead" or pose == "GettingUp" or pose == "FallingDown" or pose == "Seated" or pose == "PlatformStanding") then
					stopAllAnimations()
					amplitude = 0.1
					frequency = 1
					setAngles = true
				end

				if (setAngles) then
					local desiredAngle = amplitude * math.sin(time * frequency)
					RightShoulder:SetDesiredAngle(desiredAngle + climbFudge)
					LeftShoulder:SetDesiredAngle(desiredAngle - climbFudge)
					RightHip:SetDesiredAngle(-desiredAngle)
					LeftHip:SetDesiredAngle(-desiredAngle)
				end

				local tool = getTool()
				if tool and tool:FindFirstChild("Handle") then
					local animStringValueObject = getToolAnim(tool)
					if animStringValueObject then
						toolAnim = animStringValueObject.Value
						animStringValueObject.Parent = nil
						toolAnimTime = time + .3
					end
					if time > toolAnimTime then
						toolAnimTime = 0
						toolAnim = "None"
					end
					animateTool()		
				else
					stopToolAnimations()
					toolAnim = "None"
					toolAnimInstance = nil
					toolAnimTime = 0
				end
			end

			Humanoid.Died:connect(function(...)
				if AnimateDisabled then
					return
				end
				onDied(...)
			end)
			Humanoid.Running:connect(function(Speed)
				if AnimateDisabled then
					return
				end
				onRunning(Speed)
			end)
			Humanoid.Jumping:connect(onJumping)
			Humanoid.Climbing:connect(function(Speed)
				if AnimateDisabled then
					return
				end
				onClimbing(Speed)
			end)
			Humanoid.GettingUp:connect(function(...)
				if AnimateDisabled then
					return
				end
				onGettingUp(...)
			end)
			Humanoid.FreeFalling:connect(function(...)
				if AnimateDisabled then
					return
				end
				onFreeFall(...)
			end)
			Humanoid.FallingDown:connect(function(...)
				if AnimateDisabled then
					return
				end
				onFallingDown(...)
			end)
			Humanoid.Seated:connect(function(...)
				if AnimateDisabled then
					return
				end
				onSeated(...)
			end)
			Humanoid.PlatformStanding:connect(function(...)
				if AnimateDisabled then
					return
				end
				onPlatformStanding(...)
			end)
			Humanoid.Swimming:connect(function(...)
				if AnimateDisabled then
					return
				end
				onSwimming(...)
			end)

			game:GetService("Players").LocalPlayer.Chatted:connect(function(msg)
				local emote = ""
				if msg == "/e dance" then
					emote = dances[math.random(1, #dances)]
				elseif (string.sub(msg, 1, 3) == "/e ") then
					emote = string.sub(msg, 4)
				elseif (string.sub(msg, 1, 7) == "/emote ") then
					emote = string.sub(msg, 8)
				end
				
				if (pose == "Standing" and emoteNames[emote] ~= nil) then
					playAnimation(emote, 0.1, Humanoid)
				end
			end)

			playAnimation("idle", 0.1, Humanoid)
			pose = "Standing"

			spawn(function()
				while Figure.Parent ~= nil do
					local _, time = wait(0.1)
					move(time)
				end
			end)
		end 
	end 
end 

-- Camera/Input Functions
GetZoom = nil -- GetZoom() -> number
SetZoom = nil -- SetZoom(Zoom) -> nil

GetShiftLockEnabled = nil -- GetShiftLockEnabled() -> bool
SetShiftLockEnabled = nil -- SetShiftLockEnabled(Enabled) -> nil

SetCameraCFrame = nil -- SetCameraCFrame(NewCFrame) -> nil

BlockInputs = nil -- BlockInputs() -> nil
UnblockInputs = nil -- UnlockInputs() -> nil

SetCursorIcon = nil -- SetCursorIcon(Icon) -> nil
SetCursorSize = nil -- SetCursorSize(Size) -> nil
SetCursor = nil -- SetCursorIcon(CursorName) -> nil

do
	-- Load mouse lock action
	VirtualInputManager:SendKeyEvent(true, 304, false, workspace)
	wait()
	VirtualInputManager:SendKeyEvent(true, 304, false, workspace)
	wait()
	
	local ZoomControllers = {}
	
	do -- Get ZoomControllers from getgc
		for _,Table in pairs(getgc(true)) do
			if type(Table) == "table" then
				pcall(function()
					if type(Table.SetCameraToSubjectDistance) == "function"
					and type(Table.GetCameraToSubjectDistance) == "function"
					and Table.FIRST_PERSON_DISTANCE_THRESHOLD
					and Table.lastCameraTransform then
						table.insert(ZoomControllers,Table)
					end
				end)
			end
		end
		ConsoleMessage(tostring(#ZoomControllers).." ZoomController"..(#ZoomControllers == 1 and "" or "s"))
	end
	GetZoom = function()
		for _,ZoomController in pairs(ZoomControllers) do
			local Zoom = ZoomController:GetCameraToSubjectDistance()
			if Zoom and Zoom ~= 12.5 then
				return Zoom
			end
		end
		return 12.5
	end
	local function SmoothSetZoom(zoom)
	TargetZoom = zoom
end

SetZoom = function(Zoom)
	for _,ZoomController in pairs(ZoomControllers) do
		pcall(function()
			ZoomController:SetCameraToSubjectDistance(Zoom)
		end)
	end
end

	
	GetShiftLockEnabled = function()
		return ShiftLockEnabled
	end

	local cachedMouseLockController = nil
	local function getMouseLockController()
		if cachedMouseLockController and cachedMouseLockController.DoMouseLockSwitch then
			return cachedMouseLockController
		end
		
		for _, obj in getgc(true) do 
			if type(obj) == "table" and rawget(obj, "activeMouseLockController") then 
				cachedMouseLockController = obj.activeMouseLockController
				return cachedMouseLockController
			end
		end
		return nil
	end

	function shiftLock(active)
		local mouseLockController = getMouseLockController()
		if not mouseLockController then return end
		
		local isLocked = mouseLockController:GetIsMouseLocked()
		if (active and not isLocked) or (not active and isLocked) then
			mouseLockController:DoMouseLockSwitch("MouseLockSwitchAction", Enum.UserInputState.Begin, game)
		end
	end

	SetShiftLockEnabled = function(Enabled)
		if ShiftLockEnabled ~= Enabled then
			ShiftLockEnabled = Enabled
			if Enabled then
				SetCursor("MouseLockedCursor")
			else
				SetCursor("ArrowFarCursor")
			end
			shiftLock(Enabled)
		end
	end
		
	SetCameraCFrame = function(NewCFrame)
		CameraCFrame = NewCFrame
		workspace.CurrentCamera.CFrame = NewCFrame
	end
	
	local BlockGui = Instance.new("ScreenGui")
	local BlockFrame = Instance.new("TextButton")
	BlockFrame.Text = ""
	BlockFrame.BackgroundTransparency = 1
	BlockFrame.Size = UDim2.fromScale(1,1)
	BlockFrame.Selectable = false
	BlockFrame.Selected = false
	BlockFrame.Parent = BlockGui
	BlockGui.Enabled = false
	BlockGui.Parent = GUIParent
	BlockInputs = function()
		BlockGui.Enabled = true
	end
	UnblockInputs = function()
		BlockGui.Enabled = false
	end
	
	CursorHolder = Instance.new("ScreenGui")
    CursorHolder.Name = "TasabilityCursor"
    CursorHolder.ZIndexBehavior = Enum.ZIndexBehavior.Global  
    CursorHolder.IgnoreGuiInset = true
    CursorHolder.ResetOnSpawn = false
    CursorHolder.DisplayOrder = 999999  
    CursorHolder.Parent = game:GetService("CoreGui")  
	
	Cursor.Name = "Cursor"
	Cursor.BackgroundTransparency = 1
	Cursor.ZIndex = 10000
	Cursor.Parent = CursorHolder
	
	Resolution = workspace.CurrentCamera.ViewportSize
	
	SetCursor = function(CursorName)
		local CursorData = Cursors[CursorName]
		if CursorData then
			CursorIcon = CursorData.Icon
			CursorSize = CursorData.Size
			CursorOffset = CursorData.Offset
		end
	end
	
	-- Initialize cursor
	SetCursor("ArrowFarCursor")
end



-- AHK Functions
IsInstalled = nil -- IsInstalled() -> bool
SendSignal = nil -- SendSignal(Signal) -> nil
do
	IsInstalled = function()
		return isfolder(AHKConnectionFolderPath)
	end
	SendSignal = function(Signal)
		if IsInstalled() then
			writefile(AHKConnectionRequestPath,Signal)
		else
			ConsoleMessage("AHK folder not found")
		end
	end
end


CO = {}
do
    local CO_EPSILON        = 0.001
    local CO_ATTRIBUTE_NAME = "TAS_ObjectId"

    local objectRegistry = {}
    local idByObject     = {}
    local lastCFrames    = {}
    local nextId         = 1
    local scanComplete   = false
    local watchConn      = nil

    local function isBlacklisted(part)
        if Character and part:IsDescendantOf(Character) then return true end
        for _, plr in ipairs(game.Players:GetPlayers()) do
            if plr.Character and part:IsDescendantOf(plr.Character) then return true end
        end
        return false
    end

    local function registerPart(part)
        if idByObject[part] then return end
        if not part:IsA("BasePart") then return end
        if isBlacklisted(part) then return end

        local existingId = part:GetAttribute(CO_ATTRIBUTE_NAME)
        local id
        if existingId and not objectRegistry[existingId] then
            id = existingId
        else
            id = nextId
            nextId = nextId + 1
        end

        part:SetAttribute(CO_ATTRIBUTE_NAME, id)
        objectRegistry[id] = part
        idByObject[part]   = id
        lastCFrames[id]    = part.CFrame
    end

    local function scanWorkspace()
        for _, desc in ipairs(workspace:GetDescendants()) do
            if desc:IsA("BasePart") and not desc.Anchored and not isBlacklisted(desc) then
                registerPart(desc)
            end
        end
        scanComplete = true
        ConsoleMessage("[CO] Scanned " .. tostring(nextId - 1) .. " moving parts")
    end

    local function startWatching()
        if watchConn then watchConn:Disconnect() end
        watchConn = workspace.DescendantAdded:Connect(function(desc)
            if desc:IsA("BasePart") and not desc.Anchored and not isBlacklisted(desc) then
                registerPart(desc)
            end
        end)
    end

    function CO.Init()
        objectRegistry = {}
        idByObject     = {}
        lastCFrames    = {}
        nextId         = 1
        scanComplete   = false
        scanWorkspace()
        startWatching()
        RunService.Heartbeat:Wait()
        ConsoleMessage("[CO] Init done, recording world objects")
    end

    function CO.RecordFrame()
        if not scanComplete then return {} end
        local delta = {}
        for id, part in pairs(objectRegistry) do
            if part and part.Parent then
                local cf   = part.CFrame
                local prev = lastCFrames[id]
                local moved = false
                if prev then
                    local rel = prev:ToObjectSpace(cf)
                    local pos = rel.Position
                    if  math.abs(pos.X)                > CO_EPSILON
                     or math.abs(pos.Y)                > CO_EPSILON
                     or math.abs(pos.Z)                > CO_EPSILON
                     or math.abs(rel.XVector.X - 1)   > CO_EPSILON
                    then
                        moved = true
                    end
                else
                    moved = true
                end
                if moved then
                    delta[tostring(id)] = RoundTable({cf:GetComponents()}, RoundDigits)
                    lastCFrames[id]     = cf
                end
            end
        end
        return delta
    end

    
    CO._coRate = 15
    CO._lerpTargets = {}
    CO._lastCoTime = nil
    CO._coDataWarned = false
    function CO.ApplyFrame(delta)
        if not delta then
            if not CO._coDataWarned then
                CO._coDataWarned = true
                ConsoleMessage("[CO] WARNING: No CO data in replay. Re-record to enable spinner sync.")
            end
            return
        end
        CO._coDataWarned = false

        for idStr, components in pairs(delta) do
            CO._lerpTargets[idStr] = components
        end

        local now = tick()
        local dt = CO._lastCoTime and math.min(now - CO._lastCoTime, 0.1) or (1/60)
        CO._lastCoTime = now
        local alpha = 1 - math.exp(-CO._coRate * dt)

        for idStr, target in pairs(CO._lerpTargets) do
            local id   = tonumber(idStr)
            local part = objectRegistry[id]
            if part and part.Parent then
                part.CFrame = part.CFrame:Lerp(FastTableToCFrame(target), alpha)
            end
        end
    end

    function CO.AnchorAll()
        for id, part in pairs(objectRegistry) do
            if part and part.Parent then
                part.Anchored = true
            end
        end
        ConsoleMessage("[CO] All tracked parts anchored")
    end

    function CO.RestoreAnchors()
        for id, part in pairs(objectRegistry) do
            if part and part.Parent then
                part.Anchored = false
            end
        end
        ConsoleMessage("[CO] All tracked parts unanchored")
    end
    function CO.RebuildFromAttributes()
        objectRegistry = {}
        idByObject     = {}
        lastCFrames    = {}
        local highest  = 0
        for _, desc in ipairs(workspace:GetDescendants()) do
            if desc:IsA("BasePart") then
                local id = desc:GetAttribute(CO_ATTRIBUTE_NAME)
                if id then
                    objectRegistry[id] = desc
                    idByObject[desc]   = id
                    lastCFrames[id]    = desc.CFrame
                    if id >= highest then highest = id + 1 end
                end
            end
        end
        nextId = highest
        scanComplete = true
        startWatching()
        ConsoleMessage("[CO] Rebuilt registry: " .. tostring(highest - 1) .. " parts")
    end

	function CO.GetFullStateAtFrame(frameIndex, replayTable)
        frameIndex = math.max(0, math.floor(frameIndex or 0))
        local cache = CO._FullStateCache
        if not cache or cache.replay ~= replayTable or frameIndex < cache.frame then
            cache = {state = {}, frame = 0, replay = replayTable}
            CO._FullStateCache = cache
        end
        local state = cache.state
        local startFrame = cache.frame + 1
        for i = startFrame, frameIndex do
            local frame = replayTable[i]
            if type(frame) == "table" and frame[13] then
                for idStr, components in pairs(frame[13]) do
                    state[idStr] = components
                end
            end
        end
        cache.state = state
        cache.frame = frameIndex
        return state
    end

    function CO.InvalidateStateCache()
        CO._FullStateCache = nil
    end

    function CO.ApplyFullState(state)
        for idStr, components in pairs(state) do
            local id   = tonumber(idStr)
            local part = objectRegistry[id]
            if part and part.Parent then
                part.CFrame = FastTableToCFrame(components)
            end
        end
    end

    function CO.Stop()
        if watchConn then
            watchConn:Disconnect()
            watchConn = nil
        end
        CO._lerpTargets = {}
        CO._lastCoTime = nil
        scanComplete = false
    end
end

Freeze = nil


-- Replay Functions
ReplayEncode = nil -- ReplayEncode(Table) -> string
RecordReplay = nil -- RecordReplay() -> nil [Event]
StartRecording = nil -- StartRecording() -> nil
StopRecording = nil -- StopRecording() -> nil
SaveRecording = nil -- SaveRecording() -> nil
DiscardRecording = nil -- DiscardRecording() -> nil

StartReading = nil -- StartReading() -> nil

GetCheckpoint = nil -- GetCheckpoint(CheckpointNumber?) -> number
SetCheckpoint = nil -- SetCheckpoint(FrameIndex?) -> nil

GotoFrame = nil -- GotoFrame(Index) -> nil
ResetCurrentRecording = nil -- ResetCurrentRecording() -> nil
do
	GetReplayFile = function()
    if not isfolder(string.split(FolderPath,"/")[1]) then
        makefolder(string.split(FolderPath,"/")[1])
    end
    if not isfolder(FolderPath) then
        makefolder(FolderPath)
    end
    if not isfile(ReplayPath) then
        local emptyRaw = "TAS4" .. string.char(1, 0, 0, 0, 0, 0)
        local emptyReplay = "TAS5" .. string.char(1, 0) .. string.char(#emptyRaw) .. emptyRaw
        writefile(ReplayPath,emptyReplay)
        return emptyReplay
    end
    return readfile(ReplayPath)
    end

	local TAS4Codec = (function()
	local TAS4_MAGIC = "TAS4"
	local TAS4_VERSION = 1
	local TAS4_FLOAT = "<d"

	local function tas4PackU(n)
		n = math.max(0, math.floor(tonumber(n) or 0))
		local out = {}
		repeat
			local b = n % 128
			n = math.floor(n / 128)
			if n > 0 then b = b + 128 end
			out[#out + 1] = string.char(b)
		until n == 0
		return table.concat(out)
	end

	local function tas4ReadU(data, pos)
		local n, shift = 0, 0
		while pos <= #data do
			local b = string.byte(data, pos)
			pos = pos + 1
			n = n + (b % 128) * (2 ^ shift)
			if b < 128 then return n, pos end
			shift = shift + 7
			if shift > 49 then error("TAS4 varint too large") end
		end
		error("TAS4 truncated varint")
	end

	local function tas4PackString(str)
		str = tostring(str or "")
		return tas4PackU(#str) .. str
	end

	local function tas4ReadString(data, pos)
		local len
		len, pos = tas4ReadU(data, pos)
		local last = pos + len - 1
		if last > #data then error("TAS4 truncated string") end
		return data:sub(pos, last), last + 1
	end

	local function tas4PackDouble(n)
		return string.pack(TAS4_FLOAT, tonumber(n) or 0)
	end

	local function tas4ReadDouble(data, pos)
		local value, nextPos = string.unpack(TAS4_FLOAT, data, pos)
		return value, nextPos
	end

	-- Exact IEEE-754 delta: stores XOR of the 64-bit representation.
	local function tas4PackDoubleDelta(value, previous)
		local raw = string.pack(TAS4_FLOAT, tonumber(value) or 0)
		local lo, hi = string.unpack("<I4I4", raw)
		local plo, phi = 0, 0
		if previous ~= nil then
			local praw = string.pack(TAS4_FLOAT, tonumber(previous) or 0)
			plo, phi = string.unpack("<I4I4", praw)
		end
		return tas4PackU(bit32.bxor(lo, plo)) .. tas4PackU(bit32.bxor(hi, phi))
	end

	local function tas4ReadDoubleDelta(data, pos, previous)
		local dlo, dhi
		dlo, pos = tas4ReadU(data, pos)
		dhi, pos = tas4ReadU(data, pos)
		local plo, phi = 0, 0
		if previous ~= nil then
			local praw = string.pack(TAS4_FLOAT, tonumber(previous) or 0)
			plo, phi = string.unpack("<I4I4", praw)
		end
		local raw = string.pack("<I4I4", bit32.bxor(dlo, plo), bit32.bxor(dhi, phi))
		local value = string.unpack(TAS4_FLOAT, raw)
		return value, pos
	end

	local function tas4CollectString(dict, list, value)
		value = tostring(value or "")
		local id = dict[value]
		if not id then
			id = #list + 1
			dict[value] = id
			list[id] = value
		end
		return id
	end

	local function tas4PackSparse(values, previous, count)
		local mask = 0
		for i = 1, count do
			local cur = values[i]
			if not previous or cur ~= previous[i] then
				mask = mask + 2 ^ (i - 1)
			end
		end
		local out = {tas4PackU(mask)}
		for i = 1, count do
			if math.floor(mask / (2 ^ (i - 1))) % 2 == 1 then
				out[#out + 1] = tas4PackDoubleDelta(values[i], previous and previous[i] or nil)
			end
		end
		return table.concat(out), values
	end

	local function tas4ReadSparse(data, pos, previous, count)
		local mask
		mask, pos = tas4ReadU(data, pos)
		local values = {}
		for i = 1, count do
			local bit = math.floor(mask / (2 ^ (i - 1))) % 2
			if bit == 1 then
				values[i], pos = tas4ReadDoubleDelta(data, pos, previous and previous[i] or nil)
			elseif previous then
				values[i] = previous[i]
			else
				error("TAS4 sparse field missing initial component")
			end
		end
		return values, pos
	end

	local function tas4BuildInputDictionary(tableOfFrames)
		local dict, list = {}, {}
		for i = 1, #tableOfFrames do
			local frame = tableOfFrames[i]
			if type(frame) == "table" and type(frame[12]) == "table" then
				local events = frame[12]
				for pass = 1, 2 do
					local src = events[pass]
					if type(src) == "table" then
						for j = 1, #src do
							tas4CollectString(dict, list, src[j])
						end
					end
				end
			end
		end
		return dict, list
	end

	local function tas4SameValue(a, b)
		if a == b then return true end
		if type(a) ~= "table" or type(b) ~= "table" then return false end
		if #a ~= #b then return false end
		for i = 1, #a do
			if not tas4SameValue(a[i], b[i]) then return false end
		end
		return true
	end

	local function tas4FramesSame(a, b)
		if type(a) ~= "table" or type(b) ~= "table" then return a == b end
		for i = 1, 13 do
			if not tas4SameValue(a[i], b[i]) then return false end
		end
		return true
	end

	local encode = function(Table)
		local frameCount = #Table
		ConsoleMessage("TAS4 encoding "..tostring(frameCount).." frames")
		local StartTick = tick()

		local animDict, animList = {}, {}
		local poseDict, poseList = {}, {}
		local inputDict, inputList = tas4BuildInputDictionary(Table)

		for i = 1, frameCount do
			local frame = Table[i]
			if type(frame) == "table" then
				if type(frame[2]) == "table" then
					for j = 1, #frame[2] do
						local a = frame[2][j]
						if type(a) == "table" then tas4CollectString(animDict, animList, a[1]) end
					end
				end
				if frame[9] ~= nil then tas4CollectString(poseDict, poseList, frame[9]) end
			end
		end

		local out = {TAS4_MAGIC, string.char(TAS4_VERSION)}
		local replayFPS = tonumber(RecordingReplayFPS or ActiveReplayFPS or TASRecordingFPS) or TASRecordingFPS
		out[#out + 1] = tas4PackU(replayFPS)
		out[#out + 1] = tas4PackU(frameCount)

		out[#out + 1] = tas4PackU(#animList)
		for i = 1, #animList do out[#out + 1] = tas4PackString(animList[i]) end
		out[#out + 1] = tas4PackU(#poseList)
		for i = 1, #poseList do out[#out + 1] = tas4PackString(poseList[i]) end
		out[#out + 1] = tas4PackU(#inputList)
		for i = 1, #inputList do out[#out + 1] = tas4PackString(inputList[i]) end

		local prevCFrame1, prevCFrame7, prevV3_5, prevV3_6, prevV2_11
		local prevN3, prevN8
		local prevObjects = {}

		local function packEvents(events)
			if type(events) ~= "table" then
				return tas4PackU(0)
			end
			local outEvents = {tas4PackU(#events)}
			for i = 1, #events do
				local id = inputDict[tostring(events[i])]
				outEvents[#outEvents + 1] = tas4PackU(id or 0)
			end
			return table.concat(outEvents)
		end

		for i = 1, frameCount do
			local frame = Table[i]
			local previousFrame = Table[i - 1]
			if i > 1 and type(frame) == "table" and type(previousFrame) == "table" and tas4FramesSame(frame, previousFrame) then
				out[#out + 1] = string.char(3)
			elseif frame == 0 then
				out[#out + 1] = string.char(0)
			elseif frame == 1 then
				out[#out + 1] = string.char(1)
			elseif type(frame) == "table" then
				out[#out + 1] = string.char(2)

				local packed
			packed, prevCFrame1 = tas4PackSparse(frame[1], prevCFrame1, 12); out[#out + 1] = packed

				local anims = frame[2] or {}
				out[#out + 1] = tas4PackU(#anims)
				for j = 1, #anims do
					local a = anims[j]
					out[#out + 1] = tas4PackU(animDict[tostring(a[1])] or 0)
					out[#out + 1] = tas4PackDouble(a[2] or 0)
				end

			local n3 = frame[3] or 0
			out[#out + 1] = string.char(n3 == prevN3 and 0 or 1)
			if n3 ~= prevN3 then out[#out + 1] = tas4PackDoubleDelta(n3, prevN3); prevN3 = n3 end
			out[#out + 1] = tas4PackU(frame[4] or 0)
			packed, prevV3_5 = tas4PackSparse(frame[5], prevV3_5, 3); out[#out + 1] = packed
			packed, prevV3_6 = tas4PackSparse(frame[6], prevV3_6, 3); out[#out + 1] = packed
			packed, prevCFrame7 = tas4PackSparse(frame[7], prevCFrame7, 12); out[#out + 1] = packed
			local n8 = frame[8] or 0
			out[#out + 1] = string.char(n8 == prevN8 and 0 or 1)
			if n8 ~= prevN8 then out[#out + 1] = tas4PackDoubleDelta(n8, prevN8); prevN8 = n8 end
			out[#out + 1] = tas4PackU(poseDict[tostring(frame[9] or "")] or 0)
			out[#out + 1] = string.char((frame[10] == 1) and 1 or 0)
			packed, prevV2_11 = tas4PackSparse(frame[11], prevV2_11, 2); out[#out + 1] = packed

			local events = frame[12] or {}
			out[#out + 1] = packEvents(events[1])
			out[#out + 1] = packEvents(events[2])

			local objects = frame[13] or {}
			local objectIds = {}
			for idStr in pairs(objects) do objectIds[#objectIds + 1] = tonumber(idStr) or 0 end
			table.sort(objectIds)
			out[#out + 1] = tas4PackU(#objectIds)
			local lastId = 0
			for j = 1, #objectIds do
				local id = objectIds[j]
				out[#out + 1] = tas4PackU(math.max(0, id - lastId)); lastId = id
				local key = tostring(id)
				local components = objects[key] or objects[id]
				local previous = prevObjects[key]
				local same = previous and #previous == 12
				if same then
					for k = 1, 12 do if components[k] ~= previous[k] then same = false; break end end
				end
				if same then
					out[#out + 1] = string.char(0)
				else
					out[#out + 1] = string.char(1)
					local objectPacked
					objectPacked, prevObjects[key] = tas4PackSparse(components, previous, 12)
					out[#out + 1] = objectPacked
				end
			end
		else
				error("TAS4 cannot encode invalid frame at index "..tostring(i))
			end
		end

		local Encoded = table.concat(out)
		ConsoleMessage("TAS4 encoded "..tostring(#Encoded).." bytes in "..RoundNumber(tick()-StartTick,2).." seconds")
		return Encoded
	end

	local function tas4Decode(data)
		local pos = 6
		local version = string.byte(data, 5)
		if version ~= TAS4_VERSION then error("unsupported TAS4 version "..tostring(version)) end
		local replayFPS, frameCount
		replayFPS, pos = tas4ReadU(data, pos)
		frameCount, pos = tas4ReadU(data, pos)

		local function readDict()
			local count; count, pos = tas4ReadU(data, pos)
			local list = {}
			for i = 1, count do list[i], pos = tas4ReadString(data, pos) end
			return list
		end
		local animList = readDict()
		local poseList = readDict()
		local inputList = readDict()

		local Replay = {}
		local prevCFrame1, prevCFrame7, prevV3_5, prevV3_6, prevV2_11
		local prevN3, prevN8
		local prevObjects = {}

		local function readEvents()
			local count; count, pos = tas4ReadU(data, pos)
			local events = {}
			for i = 1, count do
				local id; id, pos = tas4ReadU(data, pos)
				events[i] = inputList[id] or ""
			end
			return events
		end

		for i = 1, frameCount do
			local tag = string.byte(data, pos); pos = pos + 1
			if tag == 0 then
				Replay[i] = 0
			elseif tag == 1 then
				Replay[i] = 1
			elseif tag == 3 then
				local previous = Replay[i - 1]
				if type(previous) ~= "table" then error("TAS4 repeat frame without previous table at "..tostring(i)) end
				local function clone(v)
					if type(v) ~= "table" then return v end
					local c = {}
					for j = 1, #v do c[j] = clone(v[j]) end
					return c
				end
				Replay[i] = clone(previous)
			elseif tag == 2 then
				local Frame = {}
				Frame[1], pos = tas4ReadSparse(data, pos, prevCFrame1, 12); prevCFrame1 = Frame[1]
				local animCount; animCount, pos = tas4ReadU(data, pos)
				Frame[2] = {}
				for j = 1, animCount do
					local id; id, pos = tas4ReadU(data, pos)
					local transition; transition, pos = tas4ReadDouble(data, pos)
					Frame[2][j] = {animList[id] or "", transition}
				end
				local changed = string.byte(data, pos); pos = pos + 1
				if changed == 1 then Frame[3], pos = tas4ReadDoubleDelta(data, pos, prevN3); prevN3 = Frame[3] else Frame[3] = prevN3 end
				if Frame[3] == nil then Frame[3] = 0; prevN3 = 0 end
				Frame[4], pos = tas4ReadU(data, pos)
				Frame[5], pos = tas4ReadSparse(data, pos, prevV3_5, 3); prevV3_5 = Frame[5]
				Frame[6], pos = tas4ReadSparse(data, pos, prevV3_6, 3); prevV3_6 = Frame[6]
				Frame[7], pos = tas4ReadSparse(data, pos, prevCFrame7, 12); prevCFrame7 = Frame[7]
				changed = string.byte(data, pos); pos = pos + 1
				if changed == 1 then Frame[8], pos = tas4ReadDoubleDelta(data, pos, prevN8); prevN8 = Frame[8] else Frame[8] = prevN8 end
				if Frame[8] == nil then Frame[8] = 0; prevN8 = 0 end
				local poseId; poseId, pos = tas4ReadU(data, pos); Frame[9] = poseList[poseId] or ""
				local flags = string.byte(data, pos); pos = pos + 1; Frame[10] = (flags % 2 == 1) and 1 or 0
				Frame[11], pos = tas4ReadSparse(data, pos, prevV2_11, 2); prevV2_11 = Frame[11]
				Frame[12] = {readEvents(), readEvents()}

				local objectCount; objectCount, pos = tas4ReadU(data, pos)
				Frame[13] = {}
				local lastId = 0
				for j = 1, objectCount do
					local deltaId; deltaId, pos = tas4ReadU(data, pos)
					local id = lastId + deltaId; lastId = id
					local key = tostring(id)
					local mode = string.byte(data, pos); pos = pos + 1
					if mode == 0 then
						local previous = prevObjects[key]
						if not previous then error("TAS4 object repeat without previous state for "..key) end
						Frame[13][key] = previous
					else
						local components
						components, pos = tas4ReadSparse(data, pos, prevObjects[key], 12)
						prevObjects[key] = components
						Frame[13][key] = components
					end
				end
				Replay[i] = Frame
			else
				error("TAS4 unknown frame tag "..tostring(tag))
			end
		end
		return Replay, replayFPS
	end

	local function tas5Compress(raw)
		-- TAS5 = TAS4 payload + optional native Zstd wrapper.
		-- This is intentionally save/load-only; recording and playback still use Frames.
		local ok, service, compressed
		ok, service = pcall(function() return game:GetService("EncodingService") end)
		if ok and service and type(buffer) == "table" and Enum and Enum.CompressionAlgorithm and Enum.CompressionAlgorithm.Zstd then
			local compressedOk
			compressedOk, compressed = pcall(function()
				local input = buffer.fromstring(raw)
				local out = service:CompressBuffer(input, Enum.CompressionAlgorithm.Zstd, math.max(1, math.min(22, math.floor(tonumber(TASCompressionLevel) or 3))))
				return buffer.tostring(out)
			end)
			if compressedOk and type(compressed) == "string" and #compressed < #raw then
				return "TAS5" .. string.char(TAS4_VERSION, 1) .. tas4PackU(#raw) .. compressed, true
			end
		end
		-- Fallback: keep the exact TAS4 stream without compression.
		return "TAS5" .. string.char(TAS4_VERSION, 0) .. tas4PackU(#raw) .. raw, false
	end

	local function tas5Decompress(data)
		if data:sub(1, 4) ~= "TAS5" then error("TAS5 invalid magic") end
		local version = string.byte(data, 5)
		local flags = string.byte(data, 6)
		if version ~= TAS4_VERSION then error("unsupported TAS5 version "..tostring(version)) end
		local rawSize, pos = tas4ReadU(data, 7)
		local payload = data:sub(pos)
		if flags == 0 then
			if #payload ~= rawSize then error("TAS5 raw payload size mismatch") end
			return payload
		end
		if flags ~= 1 then error("unsupported TAS5 compression flags "..tostring(flags)) end
		local ok, service, raw
		ok, service = pcall(function() return game:GetService("EncodingService") end)
		if not ok or not service or type(buffer) ~= "table" or not Enum or not Enum.CompressionAlgorithm or not Enum.CompressionAlgorithm.Zstd then
			error("TAS5 Zstd decoder unavailable")
		end
		ok, raw = pcall(function()
			local input = buffer.fromstring(payload)
			local out = service:DecompressBuffer(input, Enum.CompressionAlgorithm.Zstd)
			return buffer.tostring(out)
		end)
		if not ok or type(raw) ~= "string" then error("TAS5 Zstd decode failed: "..tostring(raw)) end
		if #raw ~= rawSize then error("TAS5 decompressed size mismatch") end
		return raw
	end

	local decode = function(String)
		if type(String) ~= "string" then
			ConsoleMessage("Replay decode failed: expected string, got "..type(String)); return nil
		end
		if String:sub(1, 4) == "TAS5" then
			ConsoleMessage("Decoding TAS5 "..tostring(#String).." bytes")
			local StartTick = tick()
			local ok, raw = pcall(tas5Decompress, String)
			if not ok then
				ConsoleMessage("TAS5 decompress failed: "..tostring(raw)); return nil
			end
			local ok2, Replay, replayFPS = pcall(tas4Decode, raw)
			if not ok2 then
				ConsoleMessage("TAS5 decode failed: "..tostring(Replay)); return nil
			end
			ConsoleMessage("TAS5 decoded "..tostring(#Replay).." frames in "..RoundNumber(tick()-StartTick,2).." seconds")
			return Replay, replayFPS
		end
		if String:sub(1, 4) == TAS4_MAGIC then
			ConsoleMessage("Decoding TAS4 "..tostring(#String).." bytes")
			local StartTick = tick()
			local ok, Replay, replayFPS = pcall(tas4Decode, String)
			if not ok then
				ConsoleMessage("TAS4 decode failed: "..tostring(Replay)); return nil
			end
			ConsoleMessage("TAS4 decoded "..tostring(#Replay).." frames in "..RoundNumber(tick()-StartTick,2).." seconds")
			return Replay, replayFPS
		end
		String = String:gsub("^\239\187\191", ""):gsub("^%s+", ""):gsub("%s+$", "")
		if String == "" then ConsoleMessage("Nothing to read"); return nil end
		if String:sub(1, 1) ~= "{" then
			ConsoleMessage("Invalid replay file: unknown format"); return nil
		end
		local StartTick = tick()
		local ok, Decoded = pcall(json.decode, String)
		if not ok or type(Decoded) ~= "table" or type(Decoded.Replay) ~= "table" then
			ConsoleMessage("Replay decode failed: invalid legacy JSON/replay data"); return nil
		end
		local replayFPS = tonumber(Decoded.FPS)
		ConsoleMessage("Legacy JSON decoded in "..RoundNumber(tick()-StartTick,2).." seconds")
		return Decoded.Replay, replayFPS
	end
	return {encode = encode, decode = decode, compress = tas5Compress}
	end)()

	ReplayEncode = function(Table)
        -- Save-only cache: if ReplayTable has not changed since the last encode,
        -- reuse the exact encoded bytes instead of rebuilding TAS4 + Zstd.
        if Table == ReplayTable and ReplaySaveState.Encoded and ReplaySaveState.EncodedVersion == ReplaySaveState.Version then
            ConsoleMessage("TAS5 reused cached encoding: "..tostring(#ReplaySaveState.Encoded).." bytes")
            return ReplaySaveState.Encoded
        end
		local raw = TAS4Codec.encode(Table)
		local encoded = TAS4Codec.compress(raw)
        if Table == ReplayTable then
            ReplaySaveState.Encoded = encoded
            ReplaySaveState.EncodedVersion = ReplaySaveState.Version
        end
		ConsoleMessage("TAS5 saved: "..tostring(#encoded).." bytes (raw TAS4 "..tostring(#raw)..")")
		return encoded
	end

	ReplayDecode = function(String)
		return TAS4Codec.decode(String)
	end

	RecordReplay = function()
		ConsoleMessage("Waiting for input")
		if Writing then
			ConsoleMessage("Recording stopped")
			StopRecording()
			return
		end
		SetColorCodeFrame("WaitingForInput")
		WaitForInput()
		StartRecording()
		ConsoleMessage("Recording started")
	end
	StartRecording = function()
		if not Reading then
			CO.Init()
			RecordingReplayFPS = math.max(1, tonumber(TASRecordingFPS) or 1)
			RecordingAccumulator = 1 / RecordingReplayFPS -- Capture the first sample immediately.
			InputBeganQueue = {}
			InputEndedQueue = {}
			AnimationQueue = {}
			SetColorCodeFrame("Recording")
			Writing = true
			RecordingFPSCapActive = false
		end
	end
	StopRecording = function()
		if not Reading then
			Writing = false
			RecordingFPSCapActive = false
		end
	end
	ResetCurrentRecording = function()
		-- Reset clears the unsaved recording, in-memory replay frames, and the current replay file.
		ReleaseAllPlaybackKeys()
		if Reading then
			pcall(function() StopReading() end)
		end
		Writing = false
		Frozen = false
		RecordingTable = {}
		ReplayTable = {}
        ReplaySaveState.Version = ReplaySaveState.Version + 1
        ReplaySaveState.Encoded = nil
        ReplaySaveState.EncodedVersion = -1
		ReplayTableIndex = 0
		FreezeFrame = 1
		RecordingReplayFPS = nil
		ActiveReplayFPS = nil
		RecordingFPSCapActive = false
		RecordingAccumulator = 0
		PlaybackSourcePosition = 1
		ReplayNeedsReload = false
		InputBeganQueue = {}
		InputEndedQueue = {}
		AnimationQueue = {}
		HumanoidStateQueue = {}
		PlaybackPressedKeys = {}
		PlaybackAccumulator = 0
		pcall(function() CO.Stop() end)
		-- Clear the currently selected replay file as well, so reset is persistent.
		pcall(function()
			if isfolder(FolderPath) then
				writefile(ReplayPath, ReplayEncode({}))
			end
		end)
		pcall(function()
			if CO.InvalidateStateCache then CO.InvalidateStateCache() end
		end)
		SetColorCodeFrame("Idle")
		ConsoleMessage("Recording and replay frames reset")
	end

	SaveToFile = function()
    local ReplayEncoded = ReplayEncode(ReplayTable)
    writefile(ReplayPath,ReplayEncoded)
    ReplayNeedsReload = false -- We just saved, so ReplayTable is already up to date
    LastLoadedPath = ReplayPath
    ConsoleMessage("Saved to file (cached in memory)")
end
	
	SaveRecording = function()
    if #RecordingTable > 0 then
        local recordingFPS = RecordingReplayFPS or TASRecordingFPS
        ReplaySaveState.Version = ReplaySaveState.Version + 1
        ReplaySaveState.Encoded = nil
        ReplaySaveState.EncodedVersion = -1
        for i = 1, #RecordingTable do
            ReplayTable[#ReplayTable + 1] = RecordingTable[i]
        end
        ReplaySourceFPS = math.max(1, tonumber(recordingFPS) or 1)
        ActiveReplayFPS = ReplaySourceFPS
        if CO.InvalidateStateCache then
            CO.InvalidateStateCache()
        end
        RecordingTable = {}
        ReplayNeedsReload = false -- ReplayTable is already in memory, no need to reload
        ConsoleMessage("Saved recording to memory at "..tostring(ActiveReplayFPS).." FPS")
    end
end
	DiscardRecording = function()
		if #RecordingTable > 0 then
			RecordingTable = {}
			ConsoleMessage("Discarded")
		end
	end
	StartReading = function()
    if not Reading then
        -- Only decode if we need to reload OR if path changed
        if ReplayNeedsReload or ReplayPath ~= LastLoadedPath then
            local fileContent = GetReplayFile()
            local decoded, replayFPS = ReplayDecode(fileContent)
            if decoded then
                ReplayTable = decoded
                ReplaySaveState.Version = ReplaySaveState.Version + 1
                ReplaySaveState.Encoded = (type(fileContent) == "string" and fileContent:sub(1, 4) == "TAS5") and fileContent or nil
                ReplaySaveState.EncodedVersion = ReplaySaveState.Encoded and ReplaySaveState.Version or -1
                ReplaySourceFPS = math.max(1, tonumber(replayFPS or TASRecordingFPS) or 1)
                ActiveReplayFPS = ReplaySourceFPS
                PlaybackAccumulator = 0 -- First saved frame is applied immediately; advance after one full replay interval.
                PlaybackSourcePosition = 1
                ReplayTableIndex = 1
                ReplayNeedsReload = false
                LastLoadedPath = ReplayPath
                ConsoleMessage("Decoded replay from file at "..tostring(ActiveReplayFPS).." FPS")
            else
                ReplayTable = {}
                SetColorCodeFrame("Idle")
                ConsoleMessage("Failed to decode replay")
                return
            end
        else
            ConsoleMessage("Using cached replay (no decode needed)")
        end
        
        if ReplayTable and #ReplayTable > 0 then
            Freeze(false) -- Unfreeze
            AnimateDisabled = true
            workspace.Gravity = 0
            ReplayTableIndex = 1
            ReplaySourceFPS = math.max(1, tonumber(ReplaySourceFPS or RecordingReplayFPS or ActiveReplayFPS or TASRecordingFPS) or 1)
            ActiveReplayFPS = ReplaySourceFPS
            PlaybackAccumulator = 0
            PlaybackSourcePosition = 1
            CO.RebuildFromAttributes()
            CO.AnchorAll() 
            BlockInputs()
            Reading = true
            SetColorCodeFrame("Reading")
            ConsoleMessage("Reading started")
            ConsoleMessage("Length: "..RoundNumber(#ReplayTable/math.max(ReplaySourceFPS, 1)).." seconds (playback "..tostring(ActiveReplayFPS).." FPS)")
        else
            ConsoleMessage("No replay data to read")
            SetColorCodeFrame("Idle")
        end
    else
        ConsoleMessage("You are already reading")
    end
end
	StopReading = function(PreserveCurrentFrame)
        local savedCFrame, savedVelocity, savedRotVelocity
        if Reading and PreserveCurrentFrame and Character and Character:FindFirstChild("HumanoidRootPart") then
            local hrp = Character.HumanoidRootPart
            savedCFrame = hrp.CFrame
            savedVelocity = hrp.Velocity
            savedRotVelocity = hrp.RotVelocity
        end
		Paused = false
		ReleaseAllPlaybackKeys()
		PlaybackAccumulator = 0
		if Reading then
            Reading = false
            -- Stop the playback source without resetting the current frame first.
            -- This lets Abort preserve the exact state the user was looking at.
		    CO.RestoreAnchors()
		    CO.Stop()
			UnblockInputs() -- Enable scrolling and clicks
			Character.Head.CanCollide = true -- Fix character collisions
			Character.Torso.CanCollide = true -- Fix character collisions
			Character.HumanoidRootPart.CanCollide = true -- Fix character collisions
			AnimateDisabled = false -- Enable fake animate script
			Character.Humanoid.JumpPower = DefaultJumpPower
			Character.Humanoid.WalkSpeed = DefaultWalkSpeed
			workspace.Gravity = DefaultGravity
            if PreserveCurrentFrame and savedCFrame and Character:FindFirstChild("HumanoidRootPart") then
                local hrp = Character.HumanoidRootPart
                hrp.CFrame = savedCFrame
                hrp.Velocity = savedVelocity
                hrp.RotVelocity = savedRotVelocity
            end
            PlaybackSourcePosition = math.max(1, ReplayTableIndex or 1)
			SetColorCodeFrame("Idle")
			ConsoleMessage("Reading stopped")
		else
			ConsoleMessage("You are not reading")
		end
	end
end

-- Tasability functions
--local Freeze -- Freeze(NewFrozen) -> nil
do
	Freeze = function(NewFrozen, DoNotRecord)
    if Frozen ~= NewFrozen and not Reading then
        SeekDirection = 0
        if NewFrozen then
            Frozen = true
            StopRecording()
            SaveRecording()
            FreezeFrame = #ReplayTable
            ReleaseAllPlaybackKeys()
			CO.AnchorAll() 
            SetColorCodeFrame("Frozen")
        else
			CO.RestoreAnchors()
            if DoNotRecord then
                Frozen = false
                SetColorCodeFrame("Idle")
            else
                for Index = #ReplayTable, FreezeFrame, -1 do
                    ReplayTable[Index] = nil
                end
                ReplaySaveState.Version = ReplaySaveState.Version + 1
                ReplaySaveState.Encoded = nil
                ReplaySaveState.EncodedVersion = -1
                Frozen = false
                StartRecording()
                SetColorCodeFrame("Recording")
            end
        end
    end
end
end
-- Commands
Commands = {}
do
	Commands["help"] = function(Args)
		if Args == "help" then
			ConsoleMessage("help <command>: Shows a list of all commands, or a specific command")
		else
			local Command = Args[1]
			if Command then
				Command = string.lower(Command)
				if Commands[Command] then
					Commands[Command]("help")
				else
					ConsoleMessage("Command", Command, "was not found")
				end
			else
				for _,Command in pairs(Commands) do
					Command("help")
				end
			end
		end
	end
	Commands["erase"] = function(Args)
    if Args == "help" then
        ConsoleMessage("erase: Erases all data from the folder",PlaceId)
    else
        writefile(ReplayPath, ReplayEncode({}))
        ReplayTable = {}
        ReplaySaveState.Version = ReplaySaveState.Version + 1
        ReplaySaveState.Encoded = nil
        ReplaySaveState.EncodedVersion = -1
        ReplayNeedsReload = false
        LastLoadedPath = ReplayPath
        return ReplayPath.." has been erased (cache cleared)"
    end
end

	Commands["reset"] = function(Args)
		if Args == "help" then
			ConsoleMessage("reset: Clears the current recording, all replay frames, and the current replay file")
		else
			ResetCurrentRecording()
			return "Current recording and replay frames reset"
		end
	end
	Commands["setsdm"] = function(Args)
		if Args == "help" then
			ConsoleMessage("setsdm <number SeekDirectionMultiplier>: Sets speed multiplier when using R and T while frozen")
		else
			local Number = tonumber(Args[1]) or 1
			if Number then
				local OldValue = SeekDirectionMultiplier
				SeekDirectionMultiplier = Number
				return "SeekDirectionMultiplier has been set from "..tostring(OldValue).." to "..tostring(Number)
			end
		end
	end
	Commands["rejoin"] = function(Args)
		if Args == "help" then
			ConsoleMessage("rejoin <bool SaveReplay>: Sets one of the configs at the top of the script (PlaybackInputs, etc)")
		else
			local SaveReplay = Args[1] and string.lower(Args[1])
			ConsoleMessage("Saving...")
			if SaveReplay == "true" or SaveReplay == "yes" or SaveReplay == "1" or SaveReplay == "save" then
				SaveToFile()
			end
			ConsoleMessage("Rejoining...")
			if #game.Players:GetPlayers() <= 1 then
				game.Players.LocalPlayer:Kick("\nRejoining...")
				wait()
				game:GetService("TeleportService"):Teleport(game.PlaceId, game.Players.LocalPlayer)
			else
				game:GetService("TeleportService"):TeleportToPlaceInstance(game.PlaceId, game.JobId, game.Players.LocalPlayer)
			end
			return "Sent request to rejoin"
		end
	end
	Commands["invite"] = function(Args)
		if Args == "help" then
			ConsoleMessage("invite: Invites you to Tasability Discord")
		else
			request({
				Url = "http://127.0.0.1:6463/rpc?v=1",
				Method = "POST",
				Headers = {
					["Content-Type"] = "application/json",
					["origin"] = "https://discord.com",
				},
				Body = game:GetService("HttpService"):JSONEncode({
					["args"] = {
						["code"] = "Shyfsc2cJ9",
					},
					["cmd"] = "INVITE_BROWSER",
					["nonce"] = "."
				})
			})
			return "Sent invite (if your exploit blocked it the invite is https://discord.gg/Shyfsc2cJ9)"
		end
	end
end

-- Connection Functions
StateChanged = nil
CharacterAdded = nil
InputBegan = nil
RenderStepped = nil
Stepped = nil
CurrentCamera_Changed = nil
do
	StateChanged = function(_,State)
		table.insert(HumanoidStateQueue,State.Value)
	end
	CharacterAdded = function(NewCharacter)
		Humanoid = NewCharacter:WaitForChild("Humanoid")
		Humanoid.StateChanged:Connect(StateChanged)
		RootPart = NewCharacter:WaitForChild("HumanoidRootPart")
		DefaultJumpPower = Humanoid.JumpPower
		DefaultWalkSpeed = Humanoid.WalkSpeed
		Reanimate(NewCharacter)
		Character = NewCharacter
		Humanoid.Died:Connect(function()
			Dead = true
		end)
		Dead = false
	end
	InputBegan = function(Input,GameProcessed)
	if Input.UserInputType == Enum.UserInputType.Keyboard and UserInputService:GetFocusedTextBox() then
		return
	end

	if IgnoreGameProcessed then
		GameProcessed = false
	end
	
	if Input.UserInputType == Enum.UserInputType.MouseButton1 then
		table.insert(InputBeganQueue,"b1")
	elseif Input.UserInputType == Enum.UserInputType.MouseButton2 then
		table.insert(InputBeganQueue,"b2")
	elseif Input.UserInputType == Enum.UserInputType.Keyboard then
		local InputName = string.split(tostring(Input.KeyCode),".")[3]
		if not InputBlacklist[InputName] then
			table.insert(InputBeganQueue,InputName)
		end
	end
	
	if Input.KeyCode == Enum.KeyCode.LeftShift and not Reading and not GameProcessed then
		SetShiftLockEnabled(not ShiftLockEnabled)
	end
	
	if Input.KeyCode == Recordkeybind.Value and not GameProcessed then
		-- Freeze/Unfreeze
		Freeze(not Frozen)
	elseif Input.KeyCode == Gobackwardskeybind.Value and not GameProcessed then
		if not Reading then
			Freeze(true)
			if SeekDirection == 0 then
				SeekDirection = -1*SeekDirectionMultiplier -- Backwards
			end
		end
	elseif Input.KeyCode == Goforwardkeybind.Value and not GameProcessed then
		-- Seek fowards
		if not Reading then
			Freeze(true)
			if SeekDirection == 0 then
				SeekDirection = 1*SeekDirectionMultiplier -- Fowards
			end
		end
	elseif Input.KeyCode == Frameadvancebackwardskeybind.Value and not GameProcessed then
		-- Go 1 frame backwards
		Freeze(true)
		if Frozen and SeekDirection == 0 then
			local NewFreezeFrame = FreezeFrame - 1
			if NewFreezeFrame > 0 and NewFreezeFrame <= #ReplayTable then
				FreezeFrame = NewFreezeFrame
			end
		end
	elseif Input.KeyCode == Frameadvanceforwardkeybind.Value and not GameProcessed then
		-- Go 1 frame fowards
		Freeze(true)
		if Frozen and SeekDirection == 0 then
			local NewFreezeFrame = FreezeFrame + 1
			if NewFreezeFrame > 0 and NewFreezeFrame <= #ReplayTable then
				FreezeFrame = NewFreezeFrame
			end
		end
	elseif Input.KeyCode == Hideuikeybind.Value and not GameProcessed then
		-- Toggle UI
		Window:ToggleVisibility()
	elseif Input.KeyCode == Abortkeybind.Value and not GameProcessed then
		-- Stop reading
		StopReading(true)
	elseif Input.KeyCode == Savekeybind.Value and not GameProcessed then
		-- Save to file
		SaveToFile()
	elseif Input.KeyCode == Frozenkeybind.Value and not GameProcessed then
		-- Frozen to idle
		IdleButton_MouseButton1Click()
	elseif Input.KeyCode == Readkeybind.Value and not GameProcessed then
		ReadButton_MouseButton1Click()
	elseif Input.KeyCode == Pausekeybind.Value and not GameProcessed then
		-- Pause/Resume reading
		if Reading then
			Paused = not Paused
			if Paused then
				ConsoleMessage("Paused")
				SetColorCodeFrame("Frozen") 
			else
				ConsoleMessage("Resumed")
				SetColorCodeFrame("Reading")
			end
		end
	end
end
	InputChanged = function(Input,GameProcessed)
		if Input.UserInputType == Enum.UserInputType.MouseWheel then
			if Input.Position.Z > 0 then
				table.insert(InputBeganQueue,"u")
			else
				table.insert(InputBeganQueue,"d")
			end
		end
	end
	InputEnded = function(Input,GameProcessed)
		if Input.UserInputType == Enum.UserInputType.Keyboard and UserInputService:GetFocusedTextBox() then
			return
		end
		if Input.UserInputType == Enum.UserInputType.MouseButton1 then
			table.insert(InputEndedQueue,"b1")
		elseif Input.UserInputType == Enum.UserInputType.MouseButton2 then
			table.insert(InputEndedQueue,"b2")
		elseif Input.UserInputType == Enum.UserInputType.MouseWheel then
			if Input.Position.Z > 0 then
				table.insert(InputEndedQueue,"u")
			else
				table.insert(InputEndedQueue,"d")
			end
		elseif Input.UserInputType == Enum.UserInputType.Keyboard then
			local InputName = string.split(tostring(Input.KeyCode),".")[3]
			table.insert(InputEndedQueue,InputName)
		end
		
		if Input.KeyCode == Gobackwardskeybind.Value then
			-- Stop seeking backwards
			if SeekDirection == -1*SeekDirectionMultiplier then
				SeekDirection = 0
			end
		elseif Input.KeyCode == Goforwardkeybind.Value then
			-- Stop seeking fowards
			if SeekDirection == 1*SeekDirectionMultiplier then
				SeekDirection = 0
			end
		end
	end
	RenderStepped = function(...)
		for _,Function in pairs(RenderSteppedConnections) do
			Function(...)
		end
	end
	Stepped = function(...)
		for _,Function in pairs(SteppedConnections) do
			Function(...)
		end
	end
	ReadButton_MouseButton1Click = function()
		if ReplayStartTime >= 1 then
			for i = ReplayStartTime,1,-1 do
				ConsoleMessage("Reading in "..tostring(i).." seconds")
				wait(1)
			end
		end
		StartReading()
	end
	IdleButton_MouseButton1Click = function()
		if GetColorCodeFrame() == "Frozen" then
			Freeze(false,true)
		end
	end
    CurrentCamera_Changed = function()
        if Reading then
            workspace.CurrentCamera.CFrame = CameraCFrame
        end
    end
	ConsoleInput.Callback = function(self, value)
		local Input = value
		local InputSplit = string.split(Input," ")
		local Command = Commands[string.lower(InputSplit[1])]
		if Command then
			table.remove(InputSplit,1)
			local ReturnMessage = Command(InputSplit)
			if ReturnMessage then
				ConsoleMessage(ReturnMessage)
			end
		else
			ConsoleMessage("Command",InputSplit[1],"was not found")
		end
		self:Clear()
	end
end

-- RenderStepped/Stepped connections
do
	RenderSteppedConnections.UpdateFreezeFrame = function()
		RecordedFramesLabel.Text = "Frames: "..RoundNumber(FreezeFrame,0)
	end
	RenderSteppedConnections.DrawPathVisuals = function()
    if pathVisualsEnabled then
        drawPathVisuals()
    end
end
	RenderSteppedConnections.SeekDirectionHandler = function()
		if Frozen then
			local NewFreezeFrame = FreezeFrame + SeekDirection
			if NewFreezeFrame < 1 then
				FreezeFrame = 1
			elseif NewFreezeFrame > #ReplayTable then
				FreezeFrame = #ReplayTable
			else
				FreezeFrame = NewFreezeFrame
			end
		end
	end

    local PressedWriting = {}
	
SteppedConnections.UpdateKeyboardOverlay = function()
    if getgenv().KeyboardOverlayEnabled and getgenv().KeyboardOverlayKeys then
        local keys = getgenv().KeyboardOverlayKeys
        local theme = KeyboardOverlayThemes[currentTheme]
        
        -- Determine which key table to use
        local keysToCheck = Writing and PressedWriting or Pressed
        
        for keyName, keyFrame in pairs(keys) do
            local state = "normal"
            
            if keysToCheck[keyName] then
                state = Writing and "writing" or "pressed"
            end
            
            theme.updateColors(keyFrame, state)
        end
    end
end

SteppedConnections.UpdateInputPreview = function()
	for _,Input in pairs(InputBeganQueue) do
		if Input == "u" or Input == "d" then
			return
		end
		Pressed[Input] = true
	end
	for _,Input in pairs(InputEndedQueue) do
		Pressed[Input] = nil
	end
	PressedKeysLabel.Text = "Pressed keys: |"
	for Input,_ in pairs(Pressed) do
		PressedKeysLabel.Text = PressedKeysLabel.Text..Input.."|"
	end
	
	if Writing then
		for _,Input in pairs(InputBeganQueue) do
			if Input == "u" or Input == "d" then
			else
				PressedWriting[Input] = true
			end
		end
		for _,Input in pairs(InputEndedQueue) do
			PressedWriting[Input] = nil
		end
		WritingPressedKeysLabel.Text = "Writing Pressed keys: |"
		for Input,_ in pairs(PressedWriting) do
			WritingPressedKeysLabel.Text = WritingPressedKeysLabel.Text..Input.."|"
            end
		end
	end
end

do -- Connections
	UserInputService.InputBegan:Connect(InputBegan)
	UserInputService.InputChanged:Connect(InputChanged)
	UserInputService.InputEnded:Connect(InputEnded)
	RunService.RenderStepped:Connect(RenderStepped)
	RunService.Stepped:Connect(Stepped)
	Player.CharacterAdded:Connect(CharacterAdded)
end

do -- Setup
	GetReplayFile() -- Create folders and files for Replayability+ if needed
	SetCursor("ArrowFarCursor") -- Add fake cursor - MUST BE BEFORE HIDING REAL CURSOR
	UserInputService.MouseIconEnabled = false -- Remove real cursor
	DefaultGravity = workspace.Gravity -- Set DefaultGravity
	ShiftLockBoundKeys.Value = "" -- Remove shift lock keybinds
	CharacterAdded(Player.Character) -- Set character
	SetColorCodeFrame("Idle") -- Set color code
    if setfpscap then setfpscap(FPS) end
end

function findAnimateScript(character)
    if not character then return nil end
          
    local names = {
        "Animate",
        "AnimationScript",
        "CharacterAnimate",
        "PlayerAnimate"
    }

    for _, name in ipairs(names) do
        local s = character:FindFirstChild(name, true)
        if s and s:IsA("LocalScript") then
            return s
        end
    end

    for _, obj in ipairs(character:GetDescendants()) do
        if obj:IsA("LocalScript") then
            for _, sub in ipairs(obj:GetChildren()) do
                local n = sub.Name:lower()
                if n == "idle" or n == "walk" or n == "run" or n == "jump" or n == "fall" then
                    return obj
                end
            end
        end
    end

    return nil
end



 

spawn(function() -- Reading Loop

	local frameCache = {}
	local lastVelocity = Vector3.new()
	local idleFrameCount = 0
	local idle_threshold = 3 
	
	while true do
		local deltaTime = RunService.Heartbeat:Wait()

		if Reading then
			if Paused then
				continue
			end

			local playbackFPS = math.max(1, tonumber(ActiveReplayFPS or ReplaySourceFPS or TASRecordingFPS) or 1)
			local playbackInterval = 1 / playbackFPS
			PlaybackAccumulator = PlaybackAccumulator + (tonumber(deltaTime) or 0)

			-- Keep the current saved state applied on every heartbeat. Only the source
			-- frame advances at the replay FPS, preventing physics-contact jitter.
			local advanceFrame = false
			if PlaybackAccumulator + 1e-9 >= playbackInterval then
				PlaybackAccumulator = PlaybackAccumulator - playbackInterval
				if PlaybackAccumulator < 0 then PlaybackAccumulator = 0 end
				advanceFrame = true
			end

			local Frame = ReplayTable[ReplayTableIndex]
			
			if Frame == 0 then
				Humanoid:ChangeState(15)
				for _,Descendant in pairs(Character:GetDescendants()) do
					if Descendant:IsA("BasePart") then
						Descendant:Destroy()
					end
				end
				repeat wait() until not Dead
				RunService.Heartbeat:Wait()
				ReplayTableIndex = ReplayTableIndex + 1
				idleFrameCount = 0
				continue
			elseif Frame == 1 then
				Humanoid:ChangeState(15)
				workspace.Gravity = DefaultGravity
				repeat wait() until not Dead
				RunService.Heartbeat:Wait()
				ReplayTableIndex = ReplayTableIndex + 1
				idleFrameCount = 0
				continue
			end
			
			if not Frame or typeof(Frame) == "string" then
				StopReading()
				continue
			end
			
			local animateScript = findAnimateScript(Character)
			if animateScript then
				animateScript.Disabled = true
			end

			AnimateDisabled = true
			workspace.Gravity = 0
			Character.Humanoid.JumpPower = 0
			Character.Humanoid.WalkSpeed = 0
			
			if not Character:FindFirstChild("HumanoidRootPart") then
				RunService.Heartbeat:Wait()
				continue
			end
			
			local HRP = Character.HumanoidRootPart
			
			for _,v in pairs(Character:GetChildren()) do
				if v:IsA("BasePart") then
					v.CanCollide = true 
				end
			end
			
			Humanoid.PlatformStand = true
			
			
			local cache = frameCache[ReplayTableIndex]
			if not cache then
				cache = {
					hrpCFrame = FastTableToCFrame(Frame[1]),
					camCFrame = FastTableToCFrame(Frame[7]),
					hrpVel = FastTableToVector3(Frame[5]),
					hrpRotVel = FastTableToVector3(Frame[6]),
					mouseLocation = FastTableToVector2(Frame[11]),
					animations = Frame[2],
					animSpeed = Frame[3],
					humanoidState = Frame[4],
					zoom = Frame[8],
					animPose = Frame[9],
					shiftLock = (Frame[10] == 1),
					inputBegan = Frame[12][1],
					inputEnded = Frame[12][2]
				}
				frameCache[ReplayTableIndex] = cache
			end
			
			
			local currentVelocity = cache.hrpVel
			local velocityMagnitude = currentVelocity.Magnitude
			local isOnGround = cache.humanoidState == 8 or cache.humanoidState == 0 or cache.humanoidState == 2
			local isClimbing = cache.humanoidState == 12
			local isSeated = cache.humanoidState == 13
			
			
			local isStationary = velocityMagnitude < 0.1
			
			if isStationary and isOnGround and not isClimbing and not isSeated then
				idleFrameCount = idleFrameCount + 1
			else
				idleFrameCount = 0
			end
			
			local shouldForceIdle = idleFrameCount >= idle_threshold and isOnGround and not isClimbing and not isSeated
			
			if advanceFrame then
				pose = cache.animPose
				Humanoid:ChangeState(cache.humanoidState)
		
				if shouldForceIdle then
				
					local hasWalkOrRun = false
					for _, Arguments in pairs(cache.animations) do
						local animName = Arguments[1]
						if animName == "walk" or animName == "run" then
							hasWalkOrRun = true
							break
						end
					end
				
					if hasWalkOrRun then
						playAnimation("idle", 0.1, Humanoid, true)
						pcall(setAnimationSpeed, 1.0)
					else
						-- Play normal animations
						for _, Arguments in pairs(cache.animations) do
							local animName = Arguments[1]
							local transitionTime = Arguments[2]
							playAnimation(animName, transitionTime, Humanoid, true)
						end
						pcall(setAnimationSpeed, cache.animSpeed)
					end
				else
					-- Animation playbacks
					for _, Arguments in pairs(cache.animations) do
						local animName = Arguments[1]
						local transitionTime = Arguments[2]
						playAnimation(animName, transitionTime, Humanoid, true)
					end
					pcall(setAnimationSpeed, cache.animSpeed)
				end
			
				SetCameraCFrame(cache.camCFrame)
				SetZoom(cache.zoom)
			
				if cache.shiftLock ~= GetShiftLockEnabled() then
					SetShiftLockEnabled(cache.shiftLock)
				end
			
				if PlaybackMouseLocation and not cache.shiftLock and cache.zoom > 0.52 then
					mousemoveabs(cache.mouseLocation.X, cache.mouseLocation.Y)
				else
					local CurrentResolution = workspace.CurrentCamera.ViewportSize
					local CurrentGuiInset = GuiService:GetGuiInset()
					mousemoveabs(
						(CurrentResolution.X / 2) - CurrentGuiInset.X,
						(CurrentResolution.Y / 2) - CurrentGuiInset.Y
					)
				end
			
			end

			if advanceFrame and PlaybackInputs then
				local Signal = {}
				for _, Input in pairs(cache.inputBegan) do
					if not InputBlacklist[Input] then
						local Code = InputCodes[Input]
						if Code then
							keypress(Code)
							PlaybackPressedKeys[Input] = Code
						elseif Input == "b1" then
							mouse1press()
							PlaybackPressedKeys["b1"] = "b1"
						elseif Input == "b2" then
							mouse2press()
							PlaybackPressedKeys["b2"] = "b2"
						elseif Input == "u" or Input == "d" then
							table.insert(Signal, Input)
						end
					end
				end
				for _, Input in pairs(cache.inputEnded) do
					if not InputBlacklist[Input] then
						local Code = InputCodes[Input]
						if Code then
							keyrelease(Code)
							PlaybackPressedKeys[Input] = nil
						elseif Input == "b1" then
							mouse1release()
							PlaybackPressedKeys["b1"] = nil
						elseif Input == "b2" then
							mouse2release()
							PlaybackPressedKeys["b2"] = nil
						end
					end
				end
				if #Signal > 0 then
					SendSignal(table.concat(Signal, ","))
				end
			end
			
			HRP.CFrame = cache.hrpCFrame
			HRP.Velocity = cache.hrpVel
			HRP.RotVelocity = cache.hrpRotVel
			CO.ApplyFrame(Frame[13])
			
			lastVelocity = currentVelocity
			
			if advanceFrame then
				ReplayTableIndex = ReplayTableIndex + 1

				if ReplayTableIndex > 100 then
					frameCache[ReplayTableIndex - 100] = nil
				end
			end
		else
			workspace.Gravity = DefaultGravity
			pcall(function()
				if Character and Character:FindFirstChild("Humanoid") then
					Character.Humanoid.PlatformStand = false
				end
			end)
			frameCache = {}
			lastVelocity = Vector3.new()
			idleFrameCount = 0
			PlaybackPressedKeys = {}
		end
	end
end)


-- Clear input queues
RunService.Heartbeat:Connect(function()
	if not Writing then
		InputBeganQueue = {}
		InputEndedQueue = {}
	end
end)

spawn(function() -- Check if connected
    while true do
        task.wait(2)
        if not Reading then
			local Installed = IsInstalled()
			if Installed then
				ConnectedLabel.Text = "AHK folder found"
				ConnectedLabel.TextColor3 = Color3.new(0,0.8,0)
			else
				ConnectedLabel.Text = "AHK folder not found"
				ConnectedLabel.TextColor3 = Color3.new(0.8,0,0)
			end
		end
	end
end)

spawn(function() -- Writing
	while true do
		local deltaTime = RunService.RenderStepped:Wait()

		if Writing then
			local sampleFPS = math.max(1, tonumber(RecordingReplayFPS or TASRecordingFPS) or 1)
			local sampleInterval = 1 / sampleFPS
			RecordingAccumulator = RecordingAccumulator + (tonumber(deltaTime) or 0)

			if RecordingAccumulator + 1e-9 >= sampleInterval then
				-- Consume exactly one TAS sample interval. If the client stalls, the next
				-- render step catches up naturally instead of writing duplicate frames.
				RecordingAccumulator = RecordingAccumulator - sampleInterval
				if RecordingAccumulator < 0 then
					RecordingAccumulator = 0
				end

				if (not Character or not Character.Parent) or (not Character:FindFirstChild("HumanoidRootPart")) then
					if type(RecordingTable[#RecordingTable]) == "table" then
						table.insert(RecordingTable,0) -- Voided
					end
				elseif Humanoid.Health == 0 then
					if type(RecordingTable[#RecordingTable]) == "table" then
						table.insert(RecordingTable,1) -- Dead
					end
				else
					local HRP = Character.HumanoidRootPart
					local Frame = {}
					Frame[1] = RoundTable(CFrameToTable(HRP.CFrame),RoundDigits)
					Frame[2] = AnimationQueue
					Frame[3] = RoundNumber(currentAnimSpeed,RoundDigits)
					Frame[4] = Humanoid:GetState().Value
					Frame[5] = RoundTable(Vector3ToTable(HRP.Velocity),RoundDigits)
					Frame[6] = RoundTable(Vector3ToTable(HRP.RotVelocity),RoundDigits)
					Frame[7] = RoundTable(CFrameToTable(workspace.CurrentCamera.CFrame),RoundDigits)
					Frame[8] = RoundNumber(GetZoom(),RoundDigits)
					Frame[9] = pose
					Frame[10] = (GetShiftLockEnabled() and 1) or 0
					Frame[11] = RoundTable(Vector2ToTable(UserInputService:GetMouseLocation()),RoundDigits)
					Frame[12] = {InputBeganQueue,InputEndedQueue}
					Frame[13] = CO.RecordFrame()
					table.insert(RecordingTable,Frame)

					-- Input and animation events are sampled as a batch at the TAS rate,
					-- so events occurring between samples are not lost.
					InputBeganQueue = {}
					InputEndedQueue = {}
					AnimationQueue = {}
				end
			end
		else
			RecordingAccumulator = 0
			InputBeganQueue = {}
			InputEndedQueue = {}
			AnimationQueue = {}
		end

		RunSpeed = 0
		ClimbSpeed = 0
		HumanoidStateQueue = {}
	end
end)

spawn(function() -- Update cursor
	
	local maxWait = 0
	repeat 
		task.wait(0.1)
		maxWait = maxWait + 0.1
		if maxWait > 5 then
			break
		end
	until CursorHolder and Cursor and CursorIcon
	
	SetCursor("ArrowFarCursor")

	Cursor.Image = CursorIcon
	Cursor.Size = CursorSize
	Cursor.Visible = true
	Cursor.BackgroundTransparency = 1
	Cursor.ZIndex = 10000

	
	local frameCount = 0
	while task.wait() do
		frameCount = frameCount + 1
		
		pcall(function()
			Cursor.Image = CursorIcon
			Cursor.Size = CursorSize
			Cursor.Visible = true
			
			local MouseLocation = UserInputService:GetMouseLocation()
			local ViewportSize = workspace.CurrentCamera.ViewportSize

			local cursorWidth = CursorSize.X.Offset
			local cursorHeight = CursorSize.Y.Offset
			local centerOffsetX = -cursorWidth / 2
			local centerOffsetY = -cursorHeight / 2
			
			if ShiftLockEnabled then
				Cursor.Position = UDim2.fromOffset(
					(ViewportSize.X / 2) + centerOffsetX,
					(ViewportSize.Y / 2) + centerOffsetY
				)
			else
				Cursor.Position = UDim2.fromOffset(
					MouseLocation.X + centerOffsetX,
					MouseLocation.Y + centerOffsetY
				)
			end
			
			if frameCount % 60 == 0 then
			end
		end)
	end
end)

--[[local oldConsoleMessage
oldConsoleMessage = hookfunction(ConsoleMessage,function(...)
	if checkcaller() then
		return oldConsoleMessage(...)
	end
end)]]

function ProcessFreezeFrame(RoundedFreezeFrame)
    local Frame = ReplayTable[RoundedFreezeFrame]
    if type(Frame) ~= "table" then return end

    local AnimatePose, Animation

    for Index = RoundedFreezeFrame, 1, -1 do
        if AnimatePose and Animation then break end
        local F = ReplayTable[Index]
        if type(F) == "table" then
            AnimatePose = F[9]
            Animation = F[2][#F[2]]
        end
    end

    local CurrentPressedKeys = {}
    for Index = RoundedFreezeFrame - math.max(FrameBacktrackCount, 0), RoundedFreezeFrame do
        local F = ReplayTable[Index]
        if F and type(F) == "table" then
            local BeganInputs, EndedInputs = unpack(F[12])
            for _, Key in pairs(BeganInputs) do
                if Key ~= "u" and Key ~= "d" then
                    CurrentPressedKeys[Key] = true
                end
            end
            for _, Key in pairs(EndedInputs) do
                CurrentPressedKeys[Key] = nil
            end
        end
    end

    WritingPressedKeysLabel.Text = "Writing Pressed keys: |"
    for Input, _ in pairs(CurrentPressedKeys) do
        WritingPressedKeysLabel.Text = WritingPressedKeysLabel.Text .. Input .. "|"
    end

    local HumanoidRootPartCFrame     = TableToCFrame(Frame[1])
    local AnimationSpeed             = Frame[3]
    local HumanoidState              = Frame[4]
    local HumanoidRootPartVelocity   = TableToVector3(Frame[5])
    local HumanoidRootPartRotVelocity = TableToVector3(Frame[6])
    local FrameCameraCFrame          = TableToCFrame(Frame[7])
    local Zoom                       = Frame[8]
    local FrameShiftLock             = (Frame[10] == 1)
    local MouseLocation              = TableToVector2(Frame[11])

    if Animation then
        if Animation[1] == "walk" then
            if Humanoid.FloorMaterial ~= Enum.Material.Air and Humanoid:GetState().Value ~= 3 then
                playAnimation("walk", Animation[2], Humanoid, true)
            end
        else
            playAnimation(Animation[1], Animation[2], Humanoid, true)
        end
    end
    pcall(setAnimationSpeed, AnimationSpeed)
    pose = AnimatePose

    Humanoid:ChangeState(HumanoidState)
    Character.HumanoidRootPart.Velocity = HumanoidRootPartVelocity
    Character.HumanoidRootPart.RotVelocity = HumanoidRootPartRotVelocity
    Character.HumanoidRootPart.CFrame = HumanoidRootPartCFrame

    if not movecameraonfroze.Value then
        workspace.CurrentCamera.CFrame = FrameCameraCFrame
        SetZoom(Zoom)
        if FrameShiftLock ~= GetShiftLockEnabled() then
            SetShiftLockEnabled(FrameShiftLock)
        end
    end
    if PlaybackMouseLocation then
        mousemoveabs(MouseLocation.X, MouseLocation.Y)
    end

 if #ReplayTable > 0 then
        local coState = CO.GetFullStateAtFrame(RoundedFreezeFrame, ReplayTable)
        CO.ApplyFullState(coState)
    end
end

spawn(function() -- Handling freezing
    while true do
        if Frozen then
            Character.HumanoidRootPart.Anchored = true
            if FreezeFrame > 0 and FreezeFrame <= #ReplayTable then
                local RoundedFreezeFrame = RoundNumber(FreezeFrame, 0)
                ConsoleMessage(FreezeFrame, RoundedFreezeFrame)
                ProcessFreezeFrame(RoundedFreezeFrame)
            end
        else
            pcall(function()
                Character.HumanoidRootPart.Anchored = false
            end)
        end
        RunService.RenderStepped:Wait()
    end
end)

do -- Set checkpoint
    ConsoleMessage("Loading from file...")
    local fileContent = GetReplayFile()
    local initialReplay, initialReplayFPS = ReplayDecode(fileContent)
    ReplayTable = initialReplay
    ReplaySaveState.Version = ReplaySaveState.Version + 1
    ReplaySaveState.Encoded = (type(fileContent) == "string" and fileContent:sub(1, 4) == "TAS5") and fileContent or nil
    ReplaySaveState.EncodedVersion = ReplaySaveState.Encoded and ReplaySaveState.Version or -1
    ReplaySourceFPS = math.max(1, tonumber(initialReplayFPS or TASRecordingFPS) or 1)
    ActiveReplayFPS = math.max(1, tonumber(ReplaySourceFPS or TASRecordingFPS) or 1)
    if not ReplayTable then
        ReplayTable = {}
        ConsoleMessage("There is no replay folder for",PlaceId)
    else
        ReplayNeedsReload = false
        LastLoadedPath = ReplayPath
        ConsoleMessage("Initial replay loaded and cached")
    end
end

ConsoleMessage("Tasability",Version,"loaded in",RoundNumber(tick()-ExecutionTick,2),"seconds")
ConsoleMessage("Type help to see all commands")
