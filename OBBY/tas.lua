-- f1 - record/stop | f2 - play - pause
-- LocalScript в StarterPlayerScripts
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local VirtualInputManager = game:GetService("VirtualInputManager")

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

local PlayerModule = require(player.PlayerScripts:WaitForChild("PlayerModule"))
local controls = PlayerModule:GetControls()
local cameraModule = PlayerModule:GetCameras()

local TAS = {
    recording   = false,
    playing     = false,
    frames      = {},
    elapsedTime = 0,
    TICK        = 1 / 60,
}

local alignAttachment: Attachment? = nil
local alignOrientation: AlignOrientation? = nil

local function getComponents()
    local char = player.Character
    if not char then return nil, nil, nil end
    local hum = char:FindFirstChildOfClass("Humanoid")
    local hrp = char:FindFirstChild("HumanoidRootPart")
    return char, hum, hrp
end

local function setupAlignConstraint(hrp)
    if alignOrientation then alignOrientation:Destroy() end
    if alignAttachment then alignAttachment:Destroy() end

    alignAttachment = Instance.new("Attachment")
    alignAttachment.Name = "TAS_AlignAttachment"
    alignAttachment.Parent = hrp

    alignOrientation = Instance.new("AlignOrientation")
    alignOrientation.Name = "TAS_AlignOrientation"
    alignOrientation.Mode = Enum.OrientationAlignmentMode.OneAttachment
    alignOrientation.RigidityEnabled = true
    alignOrientation.Attachment0 = alignAttachment
    alignOrientation.Parent = hrp
end

local function removeAlignConstraint()
    if alignOrientation then alignOrientation:Destroy() alignOrientation = nil end
    if alignAttachment then alignAttachment:Destroy() alignAttachment = nil end
end

local function resetRootJoint(hrp)
    local rootJoint = hrp:FindFirstChild("RootJoint")
    if rootJoint then
        rootJoint.C0 = CFrame.new(0, 0, 0) * CFrame.Angles(-math.pi/2, 0, math.pi)
        rootJoint.Transform = CFrame.identity
    end
end

local function setCameraControllersEnabled(enabled)
    if not cameraModule then return end

    local mlc = cameraModule.activeMouseLockController
    if mlc then
        pcall(function()
            if enabled then
                if mlc.OnSelected then mlc:OnSelected() end
            else
                if mlc.OnDeselected then mlc:OnDeselected() end
            end
        end)
    end

    local tc = cameraModule.activeTransparencyController
    if tc then
        pcall(function()
            if tc.SetEnabled then
                tc:SetEnabled(enabled)
            elseif tc.Enable then
                tc:Enable(enabled)
            end
        end)
    end
end

local function stopPlayback()
    TAS.playing = false
    local char, hum, hrp = getComponents()
    if hrp then
        hrp.Anchored = false
    end

    controls:Enable()
    if hum then 
        hum.AutoRotate = true
        hum.PlatformStand = false
    end
    
    camera.CameraType = Enum.CameraType.Custom
    setCameraControllersEnabled(true)
    removeAlignConstraint()

    print("[HappaTAS] ■ playback ended")
end

local function stopRecording()
    TAS.recording = false
    print("[HappaTAS] ■ record ended | frames: ", #TAS.frames)
end

RunService:BindToRenderStep("TAS_RenderSync", Enum.RenderPriority.Last.Value, function()
    if not TAS.playing or #TAS.frames == 0 then return end
    
    local frameIdx = math.clamp(math.floor(TAS.elapsedTime / TAS.TICK) + 1, 1, #TAS.frames)
    local frame = TAS.frames[frameIdx]
    
    if frame then
        local char, hum, hrp = getComponents()
        if hrp then
            hrp.CFrame = frame.rootCF
            resetRootJoint(hrp)
        end
        if frame.camCF then
            camera.CFrame = frame.camCF
        end
    end
end)

RunService.PreSimulation:Connect(function()
    if not TAS.playing or #TAS.frames == 0 then return end

    local char, hum, hrp = getComponents()
    if not char or not hum or not hrp then return end

    local frameIdx = math.clamp(math.floor(TAS.elapsedTime / TAS.TICK) + 1, 1, #TAS.frames)
    local frame = TAS.frames[frameIdx]

    if frame then
        if alignOrientation then
            alignOrientation.CFrame = frame.rootCF
        end

        hrp.CFrame = frame.rootCF
        hrp.AssemblyAngularVelocity = Vector3.zero
        resetRootJoint(hrp)
        hum:Move(frame.moveVec, true)
    end
end)

local wheelDelta = 0
UserInputService.InputChanged:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseWheel then
        wheelDelta = input.Position.Z
    end
end)

local lastState = nil
local lastFrameIdx = 0

RunService.PostSimulation:Connect(function(dt)
    local char, hum, hrp = getComponents()
    if not char or not hum or not hrp then return end

    if TAS.recording then
        TAS.elapsedTime += dt
        local targetFrame = math.floor(TAS.elapsedTime / TAS.TICK) + 1

        if targetFrame > #TAS.frames then
            table.insert(TAS.frames, {
                rootCF     = hrp.CFrame,
                linVel     = hrp.AssemblyLinearVelocity,
                angVel     = hrp.AssemblyAngularVelocity,
                moveVec    = controls:GetMoveVector(),
                state      = hum:GetState(),
                camCF      = camera.CFrame,
                wheelDelta = wheelDelta,
            })
            wheelDelta = 0
        end
    end

    if TAS.playing then
        if #TAS.frames == 0 then
            stopPlayback()
            return
        end

        TAS.elapsedTime += dt
        local frameIdx = math.clamp(math.floor(TAS.elapsedTime / TAS.TICK) + 1, 1, #TAS.frames)

        if frameIdx > #TAS.frames or TAS.elapsedTime / TAS.TICK >= #TAS.frames then
            stopPlayback()
            return
        end

        local frame = TAS.frames[frameIdx]
        if frame then
            hrp.AssemblyLinearVelocity = frame.linVel

            if frame.state ~= lastState then
                hum:ChangeState(frame.state)
                lastState = frame.state
            end

            if frameIdx ~= lastFrameIdx then
                if frame.wheelDelta and frame.wheelDelta ~= 0 then
                    VirtualInputManager:SendMouseWheelEvent(0, 0, frame.wheelDelta > 0, game)
                end
                lastFrameIdx = frameIdx
            end
        end
    end
end)

local function startRecording()
    if TAS.playing then stopPlayback() end
    TAS.frames = {}
    TAS.recording = true
    TAS.elapsedTime = 0
    print("[HappaTAS] ● record begin")
end

local function startPlayback()
    if TAS.recording then stopRecording() end
    if #TAS.frames == 0 then warn("[HappaTAS] no recorded frames") return end
    
    local char, hum, hrp = getComponents()
    if not char or not hrp or not hum then return end

    if hrp then
        hrp.Anchored = true
    end

    TAS.playing = true
    TAS.elapsedTime = 0

    controls:Disable()
    hum.AutoRotate = false
    hum.PlatformStand = true
    
    UserInputService.MouseBehavior = Enum.MouseBehavior.Default
    camera.CameraType = Enum.CameraType.Scriptable

    setCameraControllersEnabled(false)
    setupAlignConstraint(hrp)

    print("[HappaTAS] ▶ playback begin")
end

UserInputService.InputBegan:Connect(function(input, gpe)
    if gpe then return end
    if input.KeyCode == Enum.KeyCode.F1 then
        if not TAS.recording then startRecording() else stopRecording() end
    elseif input.KeyCode == Enum.KeyCode.F2 then
        if not TAS.playing then startPlayback() else stopPlayback() end
    end
end)
