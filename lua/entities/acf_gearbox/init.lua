AddCSLuaFile("cl_init.lua")
AddCSLuaFile("shared.lua")

include("shared.lua")

--===============================================================================================--
-- Local Funcs and Vars
--===============================================================================================--

local TimerCreate = timer.Create
local TimerExists = timer.Exists

local function CheckLoopedGearbox(This, Target)
	local Queued = { [Target] = true }
	local Checked = {}
	local Entity

	while next(Queued) do
		Entity = next(Queued)

		if Entity == This then
			return true
		end

		Checked[Entity] = true
		Queued[Entity]  = nil

		for Gearbox in pairs(Entity.GearboxOut) do
			if not Checked[Gearbox] then
				Queued[Gearbox] = true
			end
		end
	end

	return false
end

local function GenerateLinkTable(Entity, Target)
	local InPos = Target.In or Vector()
	local InPosWorld = Target:LocalToWorld(InPos)
	local OutPos, Side

	if Entity:WorldToLocal(InPosWorld).y < 0 then
		OutPos = Entity.OutL
		Side = 0
	else
		OutPos = Entity.OutR
		Side = 1
	end

	local OutPosWorld = Entity:LocalToWorld(OutPos)
	local DrvAngle = (OutPosWorld - InPosWorld):GetNormalized():Dot((Entity:GetRight() * OutPos.y):GetNormalized())

	if DrvAngle < 0.7 then return end

	local Rope

	if Entity.Owner:GetInfoNum("ACF_MobilityRopeLinks", 1) ~= 0 then
		Rope = constraint.CreateKeyframeRope(OutPosWorld, 1, "cable/cable2", nil, Entity, OutPos, 0, Target, InPos, 0)
	end

	local Phys = Target:GetPhysicsObject()
	local Axis = Phys:WorldToLocalVector(Entity:GetRight())
	local Inertia = (Axis * Phys:GetInertia()):Length()

	return {
		Side = Side,
		Axis = Axis,
		Inertia = Inertia,
		Rope = Rope,
		RopeLen = (OutPosWorld - InPosWorld):Length(),
		Output = OutPos,
		ReqTq = 0,
		Vel = 0
	}
end

local function LinkWheel(Gearbox, Wheel)
	if Gearbox.Wheels[Wheel] then return false, "This wheel is already linked to this gearbox!" end

	local Link = GenerateLinkTable(Gearbox, Wheel)

	if not Link then return false, "Cannot link due to excessive driveshaft angle!" end

	Gearbox.Wheels[Wheel] = Link

	Wheel:CallOnRemove("ACF_GearboxUnlink" .. Gearbox:EntIndex(), function()
		if IsValid(Gearbox) then
			Gearbox:Unlink(Wheel)
		end
	end)

	return true, "Wheel linked successfully!"
end

local function LinkGearbox(Gearbox, Target)
	if Gearbox.GearboxOut[Target] then return false, "These gearboxes are already linked to each other!" end
	if Target.GearboxIn[Gearbox] then return false, "These gearboxes are already linked to each other!" end
	if CheckLoopedGearbox(Gearbox, Target) then return false, "You cannot link gearboxes in a loop!" end

	local Link = GenerateLinkTable(Gearbox, Target)

	if not Link then return false, "Cannot link due to excessive driveshaft angle!" end

	Gearbox.GearboxOut[Target] = Link
	Target.GearboxIn[Gearbox]  = true

	return true, "Gearbox linked successfully!"
end

ACF.RegisterClassLink("acf_gearbox", "prop_physics", LinkWheel)
ACF.RegisterClassLink("acf_gearbox", "acf_gearbox", LinkGearbox)
ACF.RegisterClassLink("acf_gearbox", "tire", LinkWheel)

local function UnlinkWheel(Gearbox, Wheel)
	if Gearbox.Wheels[Wheel] then
		local Link = Gearbox.Wheels[Wheel]

		if IsValid(Link.Rope) then
			Link.Rope:Remove()
		end

		Gearbox.Wheels[Wheel] = nil

		Wheel:RemoveCallOnRemove("ACF_GearboxUnlink" .. Gearbox:EntIndex())

		return true, "Wheel unlinked successfully!"
	end

	return false, "This wheel is not linked to this gearbox!"
end

local function UnlinkGearbox(Gearbox, Target)
	if Gearbox.GearboxOut[Target] or Target.GearboxIn[Gearbox] then
		local Link = Gearbox.GearboxOut[Target]

		if IsValid(Link.Rope) then
			Link.Rope:Remove()
		end

		Gearbox.GearboxOut[Target] = nil
		Target.GearboxIn[Gearbox]  = nil

		return true, "Gearbox unlinked successfully!"
	end

	return false, "That gearboxes are not linked to each other!"
end

ACF.RegisterClassUnlink("acf_gearbox", "prop_physics", UnlinkWheel)
ACF.RegisterClassUnlink("acf_gearbox", "acf_gearbox", UnlinkGearbox)
ACF.RegisterClassUnlink("acf_gearbox", "tire", UnlinkWheel)

local CheckLegal  = ACF_CheckLegal
local ClassLink   = ACF.GetClassLink
local ClassUnlink = ACF.GetClassUnlink
local Gearboxes   = ACF.Classes.Gearboxes
local Inputs      = ACF.GetInputActions("acf_gearbox")
local Clamp       = math.Clamp
local HookRun     = hook.Run

local function CheckRopes(Entity, Target)
	if not next(Entity[Target]) then return end

	for Ent, Link in pairs(Entity[Target]) do
		local OutPos = Entity:LocalToWorld(Link.Output)
		local InPos = Ent.In and Ent:LocalToWorld(Ent.In) or Ent:GetPos()

		-- make sure it is not stretched too far
		if OutPos:Distance(InPos) > Link.RopeLen * 1.5 then
			Entity:Unlink(Ent)
			continue
		end

		-- make sure the angle is not excessive
		local DrvAngle = (OutPos - InPos):GetNormalized():Dot((Entity:GetRight() * Link.Output.y):GetNormalized())

		if DrvAngle < 0.7 then
			Entity:Unlink(Ent)
		end
	end
end

local function CalcWheel(Entity, Link, Wheel, SelfWorld)
	local WheelPhys = Wheel:GetPhysicsObject()
	local VelDiff = WheelPhys:LocalToWorldVector(WheelPhys:GetAngleVelocity()) - SelfWorld
	local BaseRPM = VelDiff:Dot(WheelPhys:LocalToWorldVector(Link.Axis))

	Link.Vel = BaseRPM

	if Entity.GearRatio == 0 then return 0 end

	-- Reported BaseRPM is in angle per second and in the wrong direction, so we convert and add the gearratio
	return BaseRPM / Entity.GearRatio / -6
end

local function ActWheel(Link, Wheel, Torque, Brake, DeltaTime)
	local Phys = Wheel:GetPhysicsObject()
	local TorqueAxis = Phys:LocalToWorldVector(Link.Axis)
	local BrakeMult = 0

	if Brake > 0 then
		BrakeMult = Link.Vel * Link.Inertia * Brake / 5
	end

	Phys:ApplyTorqueCenter(TorqueAxis * Clamp(math.deg(-Torque * 1.5 - BrakeMult) * DeltaTime, -500000, 500000))
end

--===============================================================================================--

do -- Spawn and Update functions
	local function CheckNumber(Value)
		if not Value then return end -- nil or false, both are not numbers

		return tonumber(Value)
	end

	local function VerifyData(Data)
		if not Data.Gearbox then
			Data.Gearbox = Data.Id or "2Gear-T-S"
		end

		local Class = ACF.GetClassGroup(Gearboxes, Data.Gearbox)

		if not Class then
			Data.Gearbox = "2Gear-T-S"

			Class = ACF.GetClassGroup(Gearboxes, "2Gear-T-S")
		end

		do -- Gears table verification
			local Gears = Data.Gears

			if not istable(Gears) then
				Gears = { [0] = 0 }

				Data.Gears = Gears
			else
				Gears[0] = 0
			end

			for I = 1, Class.Gears.Max do
				local Gear = CheckNumber(Gears[I])

				if not Gear then
					Gear = CheckNumber(Data["Gear" .. I]) or I * 0.1

					Data["Gear" .. I] = nil
				end

				Gears[I] = Clamp(Gear, -1, 1)
			end
		end

		do -- Final drive verification
			local Final = CheckNumber(Data.FinalDrive)

			if not Final then
				Final = CheckNumber(Data.Gear0) or 1

				Data.Gear0 = nil
			end

			Data.FinalDrive = Clamp(Final, -1, 1)
		end

		do -- External verifications
			if Class.VerifyData then
				Class.VerifyData(Data, Class)
			end

			HookRun("ACF_VerifyData", "acf_gearbox", Data, Class)
		end
	end

	local function CreateInputs(Entity, Data, Class, Gearbox)
		local List = { "Gear", "Gear Up", "Gear Down" }

		if Class.SetupInputs then
			Class.SetupInputs(List, Entity, Data, Class, Gearbox)
		end

		HookRun("ACF_OnSetupInputs", "acf_gearbox", List, Entity, Data, Class, Gearbox)

		if Entity.Inputs then
			Entity.Inputs = WireLib.AdjustInputs(Entity, List)
		else
			Entity.Inputs = WireLib.CreateInputs(Entity, List)
		end
	end

	local function CreateOutputs(Entity, Data, Class, Gearbox)
		local List = { "Current Gear", "Ratio", "Entity [ENTITY]" }

		if Class.SetupOutputs then
			Class.SetupOutputs(List, Entity, Data, Class, Gearbox)
		end

		HookRun("ACF_OnSetupOutputs", "acf_gearbox", List, Entity, Data, Class, Gearbox)

		if Entity.Outputs then
			Entity.Outputs = WireLib.AdjustOutputs(Entity, List)
		else
			Entity.Outputs = WireLib.CreateOutputs(Entity, List)
		end
	end

	local function UpdateGearbox(Entity, Data, Class, Gearbox)
		Entity:SetModel(Gearbox.Model)

		Entity:PhysicsInit(SOLID_VPHYSICS)
		Entity:SetMoveType(MOVETYPE_VPHYSICS)

		-- Storing all the relevant information on the entity for duping
		for _, V in ipairs(Entity.DataStore) do
			Entity[V] = Data[V]
		end

		Entity.Name       = Gearbox.Name
		Entity.ShortName  = Gearbox.ID
		Entity.EntType    = Class.Name
		Entity.ClassData  = Class
		Entity.SwitchTime = Gearbox.Switch
		Entity.MaxTorque  = Gearbox.MaxTorque
		Entity.MinGear    = Class.Gears.Min
		Entity.MaxGear    = Class.Gears.Max
		Entity.GearCount  = Entity.MaxGear
		Entity.LClutch    = Entity.MaxTorque
		Entity.RClutch    = Entity.MaxTorque
		Entity.In         = Entity:WorldToLocal(Entity:GetAttachment(Entity:LookupAttachment("input")).Pos)
		Entity.OutL       = Entity:WorldToLocal(Entity:GetAttachment(Entity:LookupAttachment("driveshaftL")).Pos)
		Entity.OutR       = Entity:WorldToLocal(Entity:GetAttachment(Entity:LookupAttachment("driveshaftR")).Pos)
		Entity.HitBoxes   = ACF.HitBoxes[Gearbox.Model]

		CreateInputs(Entity, Data, Class, Gearbox)
		CreateOutputs(Entity, Data, Class, Gearbox)

		WireLib.TriggerOutput(Entity, "Entity", Entity)

		Entity:SetNWString("WireName", "ACF " .. Entity.Name)

		ACF_Activate(Entity, true)

		Entity.ACF.LegalMass = Gearbox.Mass
		Entity.ACF.Model     = Gearbox.Model

		local Phys = Entity:GetPhysicsObject()
		if IsValid(Phys) then Phys:SetMass(Gearbox.Mass) end

		Entity:ChangeGear(1)
	end

	-- Some information may still be passed from the menu tool
	-- We don't want to save it on the entity if it's not needed
	local function CleanupData(Class, Gearbox, _, _, GearboxData)
		if Class ~= "acf_gearbox" then return end

		if not Gearbox.Automatic then
			Gearbox.Reverse = nil
		end

		if not Gearbox.CVT then
			Gearbox.MinRPM = nil
			Gearbox.MaxRPM = nil
		end

		if GearboxData.DualClutch then
			Gearbox:SetBodygroup(1, 1)
		end
	end

	hook.Add("ACF_OnEntitySpawn", "ACF Cleanup Gearbox Data", CleanupData)
	hook.Add("ACF_OnEntityUpdate", "ACF Cleanup Gearbox Data", CleanupData)
	hook.Add("ACF_OnSetupInputs", "ACF Cleanup Gearbox Data", function(Class, List, _, _, _, GearboxData)
		if Class ~= "acf_gearbox" then return end

		local Count = #List

		if GearboxData.DualClutch then
			List[Count + 1] = "Left Clutch"
			List[Count + 2] = "Right Clutch"
			List[Count + 3] = "Left Brake"
			List[Count + 4] = "Right Brake"
		else
			List[Count + 1] = "Clutch"
			List[Count + 2] = "Brake"
		end
	end)
	hook.Add("ACF_OnEntityLast", "ACF Cleanup Gearbox Data", function(Class, Gearbox)
		if Class ~= "acf_gearbox" then return end

		Gearbox:SetBodygroup(1, 0)
	end)

	-------------------------------------------------------------------------------

	function MakeACF_Gearbox(Player, Pos, Angle, Data)
		VerifyData(Data)

		local Class = ACF.GetClassGroup(Gearboxes, Data.Gearbox)
		local GearboxData = Class.Lookup[Data.Gearbox]
		local Limit = Class.LimitConVar.Name

		if not Player:CheckLimit(Limit) then return end

		local Gearbox = ents.Create("acf_gearbox")

		if not IsValid(Gearbox) then return end

		Gearbox:SetPlayer(Player)
		Gearbox:SetAngles(Angle)
		Gearbox:SetPos(Pos)
		Gearbox:Spawn()

		Player:AddCleanup("acfmenu", Gearbox)
		Player:AddCount(Limit, Gearbox)

		Gearbox.Owner			= Player -- MUST be stored on ent for PP
		Gearbox.Engines			= {}
		Gearbox.Wheels			= {} -- a "Link" has these components: Ent, Side, Axis, Rope, RopeLen, Output, ReqTq, Vel
		Gearbox.GearboxIn		= {}
		Gearbox.GearboxOut		= {}
		Gearbox.TotalReqTq		= 0
		Gearbox.TorqueOutput	= 0
		Gearbox.LBrake			= 0
		Gearbox.RBrake			= 0
		Gearbox.ChangeFinished	= 0
		Gearbox.InGear			= false
		Gearbox.LastActive		= 0
		Gearbox.DataStore		= ACF.GetEntityArguments("acf_gearbox")

		UpdateGearbox(Gearbox, Data, Class, GearboxData)

		if Class.OnSpawn then
			Class.OnSpawn(Gearbox, Data, Class, GearboxData)
		end

		HookRun("ACF_OnEntitySpawn", "acf_gearbox", Gearbox, Data, Class, GearboxData)

		Gearbox:UpdateOverlay(true)

		do -- Mass entity mod removal
			local EntMods = Data and Data.EntityMods

			if EntMods and EntMods.mass then
				EntMods.mass = nil
			end
		end

		CheckLegal(Gearbox)

		timer.Create("ACF Gearbox Clock " .. Gearbox:EntIndex(), 3, 0, function()
			if IsValid(Gearbox) then
				CheckRopes(Gearbox, "GearboxOut")
				CheckRopes(Gearbox, "Wheels")
			else
				timer.Remove("ACF Engine Clock " .. Gearbox:EntIndex())
			end
		end)

		return Gearbox
	end

	ACF.RegisterEntityClass("acf_gearbox", MakeACF_Gearbox, "Gearbox", "Gears", "FinalDrive", "ShiftPoints", "Reverse", "MinRPM", "MaxRPM")
	ACF.RegisterLinkSource("acf_gearbox", "GearboxIn")
	ACF.RegisterLinkSource("acf_gearbox", "GearboxOut")
	ACF.RegisterLinkSource("acf_gearbox", "Engines")
	ACF.RegisterLinkSource("acf_gearbox", "Wheels")

	------------------- Updating ---------------------

	function ENT:Update(Data)
		VerifyData(Data)

		local Class       = ACF.GetClassGroup(Gearboxes, Data.Gearbox)
		local GearboxData = Class.Lookup[Data.Gearbox]
		local OldClass    = self.ClassData
		local Feedback     = ""

		if OldClass.OnLast then
			OldClass.OnLast(self, OldClass)
		end

		HookRun("ACF_OnEntityLast", "acf_gearbox", self, OldClass)

		ACF.SaveEntity(self)

		UpdateGearbox(self, Data, Class, GearboxData)

		ACF.RestoreEntity(self)

		if Class.OnUpdate then
			Class.OnUpdate(self, Data, Class, GearboxData)
		end

		HookRun("ACF_OnEntityUpdate", "acf_gearbox", self, Data, Class, GearboxData)

		if next(self.Engines) then
			local Count, Total = 0, 0

			for Engine in pairs(self.Engines) do
				self:Unlink(Engine)

				local Result = self:Link(Engine)

				if not Result then Count = Count + 1 end

				Total = Total + 1
			end

			if Count == Total then
				Feedback = Feedback .. "\nUnlinked all engines due to excessive driveshaft angle."
			elseif Count > 0 then
				local Text = Feedback .. "\nUnlinked %s out of %s engines due to excessive driveshaft angle."

				Feedback = Text:format(Count, Total)
			end
		end

		if next(self.Wheels) then
			local Count, Total = 0, 0

			for Wheel in pairs(self.Wheels) do
				self:Unlink(Wheel)

				local Result = self:Link(Wheel)

				if not Result then Count = Count + 1 end

				Total = Total + 1
			end

			if Count == Total then
				Feedback = Feedback .. "\nUnlinked all wheels due to excessive driveshaft angle."
			elseif Count > 0 then
				local Text = Feedback .. "\nUnlinked %s out of %s wheels due to excessive driveshaft angle."

				Feedback = Text:format(Count, Total)
			end
		end

		if next(self.GearboxIn) or next(self.GearboxOut) then
			local Count, Total = 0, 0

			for Gearbox in pairs(self.GearboxIn) do
				Gearbox:Unlink(self)

				local Result = Gearbox:Link(self)

				if not Result then Count = Count + 1 end

				Total = Total + 1
			end

			for Gearbox in pairs(self.GearboxOut) do
				self:Unlink(Gearbox)

				local Result = self:Link(Gearbox)

				if not Result then Count = Count + 1 end

				Total = Total + 1
			end

			if Count == Total then
				Feedback = Feedback .. "\nUnlinked all gearboxes due to excessive driveshaft angle."
			elseif Count > 0 then
				local Text = Feedback .. "\nUnlinked %s out of %s gearboxes due to excessive driveshaft angle."

				Feedback = Text:format(Count, Total)
			end
		end

		self:UpdateOverlay(true)

		net.Start("ACF_UpdateEntity")
			net.WriteEntity(self)
		net.Broadcast()

		return true, "Gearbox updated successfully!" .. Feedback
	end
end

--===============================================================================================--
-- Meta Funcs
--===============================================================================================--

function ENT:Enable()
	if self.Automatic then
		self:ChangeDrive(self.OldGear)
	else
		self:ChangeGear(self.OldGear)
	end

	self.OldGear = nil

	self:UpdateOverlay()
end

function ENT:Disable()
	self.OldGear = self.Automatic and self.Drive or self.Gear

	if self.Automatic then
		self:ChangeDrive(0)
	else
		self:ChangeGear(0)
	end

	self:UpdateOverlay()
end

local function Overlay(Ent)
	if Ent.Disabled then
		Ent:SetOverlayText("Disabled: " .. Ent.DisableReason .. "\n" .. Ent.DisableDescription)
	else
		local Text = "Current Gear: " .. Ent.Gear .. "\n\n" .. Ent.Name .. "\n"
		local GearsText = Ent.ClassData.GetGearsText and Ent.ClassData.GetGearsText(Ent)
		local Gears = Ent.Gears

		if GearsText and GearsText ~= "" then
			Text = Text .. GearsText .. "\n"
		else
			for i = 1, Ent.MaxGear do
				Text = Text .. "Gear " .. i .. ": " .. math.Round(Gears[i], 2) .. "\n"
			end
		end

		Text = Text .. "Final Drive: " .. math.Round(Ent.FinalDrive, 2) .. "\n"
		Text = Text .. "Torque Rating: " .. Ent.MaxTorque .. " Nm / " .. math.Round(Ent.MaxTorque * 0.73) .. " ft-lb\n"
		Text = Text .. "Torque Output: " .. math.floor(Ent.TorqueOutput) .. " Nm / " .. math.Round(Ent.TorqueOutput * 0.73) .. " ft-lb"

		Ent:SetOverlayText(Text)
	end
end

function ENT:UpdateOverlay(Instant)
	if Instant then
		return Overlay(self)
	end

	if TimerExists("ACF Overlay Buffer" .. self:EntIndex()) then -- This entity has been updated too recently
		self.OverlayBuffer = true -- Mark it to update when buffer time has expired
	else
		TimerCreate("ACF Overlay Buffer" .. self:EntIndex(), 1, 1, function()
				self.OverlayBuffer = nil
			if IsValid(self) and self.OverlayBuffer then
				self:UpdateOverlay()
			end
		end)
		Overlay(self)

	end
end

-- prevent people from changing bodygroup
function ENT:CanProperty(_, Property)
	return Property ~= "bodygroups"
end

ACF.AddInputAction("acf_gearbox", "Gear", function(Entity, Value)
	if Entity.Automatic then
		Entity:ChangeDrive(Value)
	else
		Entity:ChangeGear(Value)
	end
end)

ACF.AddInputAction("acf_gearbox", "Gear Up", function(Entity, Value)
	if Value == 0 then return end

	if Entity.Automatic then
		Entity:ChangeDrive(Entity.Drive + 1)
	else
		Entity:ChangeGear(Entity.Gear + 1)
	end
end)

ACF.AddInputAction("acf_gearbox", "Gear Down", function(Entity, Value)
	if Value == 0 then return end

	if Entity.Automatic then
		Entity:ChangeDrive(Entity.Drive - 1)
	else
		Entity:ChangeGear(Entity.Gear - 1)
	end
end)

ACF.AddInputAction("acf_gearbox", "Clutch", function(Entity, Value)
	Entity.LClutch = Clamp(1 - Value, 0, 1) * Entity.MaxTorque
	Entity.RClutch = Clamp(1 - Value, 0, 1) * Entity.MaxTorque
end)

ACF.AddInputAction("acf_gearbox", "Left Clutch", function(Entity, Value)
	Entity.LClutch = Clamp(1 - Value, 0, 1) * Entity.MaxTorque
end)

ACF.AddInputAction("acf_gearbox", "Right Clutch", function(Entity, Value)
	Entity.RClutch = Clamp(1 - Value, 0, 1) * Entity.MaxTorque
end)

ACF.AddInputAction("acf_gearbox", "Brake", function(Entity, Value)
	Entity.LBrake = Clamp(Value, 0, 100)
	Entity.RBrake = Clamp(Value, 0, 100)
end)

ACF.AddInputAction("acf_gearbox", "Left Brake", function(Entity, Value)
	Entity.LBrake = Clamp(Value, 0, 100)
end)

ACF.AddInputAction("acf_gearbox", "Right Brake", function(Entity, Value)
	Entity.RBrake = Clamp(Value, 0, 100)
end)

ACF.AddInputAction("acf_gearbox", "CVT Ratio", function(Entity, Value)
	Entity.CVTRatio = Clamp(Value, 0, 1)
end)

ACF.AddInputAction("acf_gearbox", "Steer Rate", function(Entity, Value)
	Entity.SteerRate = Clamp(Value, -1, 1)
end)

ACF.AddInputAction("acf_gearbox", "Hold Gear", function(Entity, Value)
	Entity.Hold = tobool(Value)
end)

ACF.AddInputAction("acf_gearbox", "Shift Speed Scale", function(Entity, Value)
	Entity.ShiftScale = Clamp(Value, 0.1, 1.5)
end)

function ENT:TriggerInput(Name, Value)
	if self.Disabled then return end

	local Action = Inputs[Name]

	if Action then
		Action(self, Value)

		self:UpdateOverlay()
	end
end

-- Handles gearing for automatic gearboxes. 0 = Neutral, 1 = Drive, 2 = Reverse
function ENT:ChangeDrive(Value)
	Value = Clamp(math.floor(Value), 0, 2)

	if self.Drive == Value then return end

	self.Drive = Value

	self:ChangeGear(Value == 2 and self.GearCount or Value)
end

function ENT:ChangeGear(Value)
	Value = Clamp(math.floor(Value), self.MinGear, self.GearCount)

	if self.Gear == Value then return end

	self.Gear           = Value
	self.InGear         = false
	self.GearRatio      = self.Gears[Value] * self.FinalDrive
	self.ChangeFinished = ACF.CurTime + self.SwitchTime

	self:EmitSound("buttons/lever7.wav", 250, 100)

	WireLib.TriggerOutput(self, "Current Gear", Value)
	WireLib.TriggerOutput(self, "Ratio", self.GearRatio)
end

function ENT:Calc(InputRPM, InputInertia)
	if self.Disabled then return 0 end
	if self.LastActive == ACF.CurTime then return self.TorqueOutput end

	if self.ChangeFinished < ACF.CurTime then
		self.InGear = true
	end

	local BoxPhys = self:GetPhysicsObject()
	local SelfWorld = BoxPhys:LocalToWorldVector(BoxPhys:GetAngleVelocity())

	if self.CVT and self.Gear == 1 then
		if self.CVTRatio > 0 then
			self.Gears[1] = Clamp(self.CVTRatio, 0.01, 1)
		else
			self.Gears[1] = Clamp((InputRPM - self.MinRPM) / (self.MaxRPM - self.MinRPM), 0.05, 1)
		end

		self.GearRatio = self.Gears[1] * self.FinalDrive

		WireLib.TriggerOutput(self, "Ratio", self.GearRatio)
	end

	if self.Automatic and self.Drive == 1 and self.InGear then
		local PhysVel = BoxPhys:GetVelocity():Length()

		if not self.Hold and self.Gear ~= self.MaxGear and PhysVel > (self.ShiftPoints[self.Gear] * self.ShiftScale) then
			self:ChangeGear(self.Gear + 1)
		elseif PhysVel < (self.ShiftPoints[self.Gear - 1] * self.ShiftScale) then
			self:ChangeGear(self.Gear - 1)
		end
	end

	self.TotalReqTq = 0
	self.TorqueOutput = 0

	for Ent, Link in pairs(self.GearboxOut) do
		local Clutch = Link.Side == 0 and self.LClutch or self.RClutch

		Link.ReqTq = 0

		if not Ent.Disabled then
			local Inertia = 0

			if self.GearRatio ~= 0 then
				Inertia = InputInertia / self.GearRatio
			end

			Link.ReqTq = math.min(Clutch, math.abs(Ent:Calc(InputRPM * self.GearRatio, Inertia) * self.GearRatio))

			self.TotalReqTq = self.TotalReqTq + math.abs(Link.ReqTq)
		end
	end

	for Wheel, Link in pairs(self.Wheels) do
		local Clutch = Link.Side == 0 and self.LClutch or self.RClutch
		local RPM = CalcWheel(self, Link, Wheel, SelfWorld)

		Link.ReqTq = 0

		if self.GearRatio ~= 0 and ((InputRPM > 0 and RPM < InputRPM) or (InputRPM < 0 and RPM > InputRPM)) then
			if self.DoubleDiff then
				local NTq = math.min(Clutch, (InputRPM - RPM) * InputInertia)
				local Sign = self.SteerRate ~= 0 and self.SteerRate / math.abs(self.SteerRate) or 0
				local DTq, Mult

				if Link.Side == 0 then
					DTq = self.SteerRate * ((InputRPM * (math.abs(self.SteerRate) + 1)) - (RPM * Sign))
					Mult = 1
				else
					DTq = self.SteerRate * ((InputRPM * (math.abs(self.SteerRate) + 1)) + (RPM * Sign))
					Mult = -1
				end

				Link.ReqTq = NTq + Clamp(DTq * InputInertia, -self.MaxTorque, self.MaxTorque) * Mult
			else
				Link.ReqTq = math.min(Clutch, (InputRPM - RPM) * InputInertia)
			end

			self.TotalReqTq = self.TotalReqTq + math.abs(Link.ReqTq)
		end
	end

	self.TorqueOutput = math.min(self.TotalReqTq, self.MaxTorque)

	self:UpdateOverlay()

	return self.TorqueOutput
end

function ENT:Act(Torque, DeltaTime, MassRatio)
	if self.Disabled then return end

	local Loss = Clamp(((1 - 0.4) / 0.5) * ((self.ACF.Health / self.ACF.MaxHealth) - 1) + 1, 0.4, 1) --internal torque loss from damaged
	local Slop = self.Automatic and 0.9 or 1 --internal torque loss from inefficiency
	local ReactTq = 0
	-- Calculate the ratio of total requested torque versus what's avaliable, and then multiply it but the current gearratio
	local AvailTq = 0

	if Torque ~= 0 and self.GearRatio ~= 0 then
		AvailTq = math.min(math.abs(Torque) / self.TotalReqTq, 1) / self.GearRatio * -(-Torque / math.abs(Torque)) * Loss * Slop
	end

	for Ent, Link in pairs(self.GearboxOut) do
		Ent:Act(Link.ReqTq * AvailTq, DeltaTime, MassRatio)
	end

	for Ent, Link in pairs(self.Wheels) do
		local Brake = Link.Side == 0 and self.LBrake or self.RBrake
		local WheelTorque = Link.ReqTq * AvailTq

		ActWheel(Link, Ent, WheelTorque, Brake, DeltaTime)

		ReactTq = ReactTq + WheelTorque
	end

	if ReactTq ~= 0 then
		local BoxPhys = ACF_GetAncestor(self):GetPhysicsObject()

		if IsValid(BoxPhys) then
			BoxPhys:ApplyTorqueCenter(self:GetRight() * Clamp(2 * math.deg(ReactTq * MassRatio) * DeltaTime, -500000, 500000))
		end
	end

	self.LastActive = ACF.CurTime
end

function ENT:Link(Target)
	if not IsValid(Target) then return false, "Attempted to link an invalid entity." end
	if self == Target then return false, "Can't link a gearbox to itself." end

	local Function = ClassLink(self:GetClass(), Target:GetClass())

	if Function then
		return Function(self, Target)
	end

	return false, "Gearboxes can't be linked to '" .. Target:GetClass() .. "'."
end

function ENT:Unlink(Target)
	if not IsValid(Target) then return false, "Attempted to unlink an invalid entity." end
	if self == Target then return false, "Can't unlink a gearbox from itself." end

	local Function = ClassUnlink(self:GetClass(), Target:GetClass())

	if Function then
		return Function(self, Target)
	end

	return false, "Gearboxes can't be unlinked from '" .. Target:GetClass() .. "'."
end

function ENT:PreEntityCopy()
	if next(self.Wheels) then
		local Wheels = {}

		for Ent in pairs(self.Wheels) do
			Wheels[#Wheels + 1] = Ent:EntIndex()
		end

		duplicator.StoreEntityModifier(self, "ACFWheels", Wheels)
	end

	if next(self.GearboxOut) then
		local Entities = {}

		for Ent in pairs(self.GearboxOut) do
			Entities[#Entities + 1] = Ent:EntIndex()
		end

		duplicator.StoreEntityModifier(self, "ACFGearboxes", Entities)
	end

	--Wire dupe info
	self.BaseClass.PreEntityCopy(self)
end

function ENT:PostEntityPaste(Player, Ent, CreatedEntities)
	local EntMods = Ent.EntityMods

	-- Backwards compatibility
	if EntMods.WheelLink then
		local Entities = EntMods.WheelLink.entities

		for _, EntID in ipairs(Entities) do
			self:Link(CreatedEntities[EntID])
		end

		EntMods.WheelLink = nil
	end

	if EntMods.ACFWheels then
		for _, EntID in ipairs(EntMods.ACFWheels) do
			self:Link(CreatedEntities[EntID])
		end

		EntMods.ACFWheels = nil
	end

	if EntMods.ACFGearboxes then
		for _, EntID in ipairs(EntMods.ACFGearboxes) do
			self:Link(CreatedEntities[EntID])
		end

		EntMods.ACFGearboxes = nil
	end

	self.BaseClass.PostEntityPaste(self, Player, Ent, CreatedEntities)
end

function ENT:OnRemove()
	local Class = self.ClassData

	if Class.OnLast then
		Class.OnLast(self, Class)
	end

	HookRun("ACF_OnEntityLast", "acf_gearbox", self, Class)

	for Engine in pairs(self.Engines) do
		self:Unlink(Engine)
	end

	for Wheel in pairs(self.Wheels) do
		self:Unlink(Wheel)
	end

	for Gearbox in pairs(self.GearboxIn) do
		Gearbox:Unlink(self)
	end

	for Gearbox in pairs(self.GearboxOut) do
		self:Unlink(Gearbox)
	end

	timer.Remove("ACF Engine Clock " .. self:EntIndex())

	WireLib.Remove(self)
end
