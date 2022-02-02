local ACF   = ACF
local Types = ACF.DamageTypes

-- Things to do:
-- Create a different branch for this, it's gonna take a while
-- Create a flowchart to get an idea all the stuff ACF has to do in order to deal damage
-- Figure out how to make blast damage work
-- Change the way entities set their health, needs to be based on volume

function Types.DoSimpleDamage(Diameter, Penetration, Thickness)
    local Depth  = math.min(Penetration, Thickness or math.huge)
    local Damage = math.pi * Diameter * Diameter * Depth

    return {
        Damage   = Damage,
        Overkill = math.max(0, Penetration - Depth),
        Loss     = Depth / Penetration,
		Kill     = false
    }
end

function Types.DoPiercingDamage(Diameter, Penetration, Thickness, Angle)
	local Factor    = Thickness / Diameter -- Slope factor
	local Effective = Thickness / math.abs(math.cos(math.rad(Angle)) ^ Factor)
	local Result = {
		Damage   = math.pi * Diameter * Diameter, -- Amount of volume removed from the entity, not counting height yet
		Overkill = true,
		Loss     = true,
		Kill     = false
	}

	if Penetration > Effective then
		Result.Damage   = Result.Damage * Effective
		Result.Overkill = Penetration - Effective
		Result.Loss     = Effective / Penetration
	else
		Result.Damage   = Result.Damage * Penetration
		Result.Overkill = 0
		Result.Loss     = 1
	end

	return Result
end

-- NOTE: Give it penetration maybe?
-- I believe this should only simulate the stress applied by the blast to an entity
-- We could just call the other two functions above if we want to give it fragment penetration

-- NOTE: How would this work with players and vehicles?
function Types.DoBlastDamage(Energy, SurfaceArea, Volume)
    local Ratio = SurfaceArea / Volume
    local EnergyPerArea = Energy / SurfaceArea * Ratio

    return {
        Damage   = EnergyPerArea,
		Overkill = 0, -- TODO: Calculate this if we want to give it penetration
        Loss     = 1, -- TODO: Calculate this if we want to give it penetration
		Kill     = false
    }
end

do -- NOTE: Leaving it here in the meantime, move to damage.lua later
	-- Reference: https://github.com/Stooberton/ACF-3/blame/80001aa80cfe2ff53bdb20b3e1774ba532a164ce/lua/acf/server/damage.lua#L126-L261
	local TraceData = { start = true, endpos = true, mask = MASK_SOLID, filter = true }

	local function GetRandomPos(Entity, IsChar)
		if IsChar then
			local Min, Max = Entity:OBBMins() * 0.65, Entity:OBBMaxs() * 0.65 -- Scale down the "hitbox" since most of the character is in the middle
			local Rand =  Vector(math.Rand(Min.x, Max.x), math.Rand(Min.y, Max.y), math.Rand(Min.z, Max.z))

			return Entity:LocalToWorld(Rand)
		else
			local Mesh = Entity:GetPhysicsObject():GetMesh()

			if not Mesh then -- Is Make-Sphericaled
				local Min, Max = Entity:OBBMins(), Entity:OBBMaxs()
				local Rand = Vector(math.Rand(Min.x, Max.x), math.Rand(Min.y, Max.y), math.Rand(Min.z, Max.z))

				return Entity:LocalToWorld(Rand:GetNormalized() * math.Rand(1, Entity:BoundingRadius() * 0.5)) -- Attempt to a random point in the sphere
			else
				local Rand = math.random(3, #Mesh / 3) * 3
				local P    = Vector()

				for I = Rand - 2, Rand do P = P + Mesh[I].pos end

				return Entity:LocalToWorld(P / 3) -- Attempt to hit a point on a face of the mesh
			end
		end
	end

	function ACF.CreateExplosion(Position, FillerMass, FragMass, Inflictor, Weapon, Filter)
		if not istable(Filter) then Filter = {} end

		local Power  = FillerMass * ACF.HEPower --Power in KiloJoules of the filler mass of TNT
		local Radius = FillerMass ^ 0.33 * 8 * 39.37 -- Scaling law found on the net, based on 1PSI overpressure from 1 kg of TNT at 15m
		local Amp    = math.min(Power * 0.0005, 50)
		local Ents   = ents.FindInSphere(Position, Radius)
		local Retry  = true

		util.ScreenShake(Position, Amp, Amp, Amp * 0.06667, Radius * 10)

		TraceData.start  = Position
		TraceData.filter = Filter

		while Retry and Power > 0 then
			Retry = false

			local Spent = 0
			local Found = {}

			for I = 1, #Ents do
				local Entity = Ents[I]

				if Found[Entity] then continue end

				local Type   = ACF.Check(Entity)
				local IsChar = Type == "Squishy"

				if not Type or Entity.Exploding or (IsChar and Entity:Health() <= 0) then
					Filter[#Filter + 1] = Entity

					Ents[I] = nil

					continue
				end

				local Target = GetRandomPos(Entity, IsChar)
				local Displ  = Target - Position



			end
		end
	end
end