-- Local Vars -----------------------------------
local ACF        = ACF
local HookRun    = hook.Run
local ACF_HEPUSH = CreateConVar("acf_hepush", 1, FCVAR_NONE, "Whether or not HE pushes on entities", 0, 1)

do -- Player syncronization
	util.AddNetworkString("ACF_RenderDamage")

	hook.Add("ACF_OnPlayerLoaded", "ACF Render Damage", function(ply)
		local Table = {}

		for _, v in pairs(ents.GetAll()) do
			if v.ACF and v.ACF.PrHealth then
				table.insert(Table, {
					ID = v:EntIndex(),
					Health = v.ACF.Health,
					MaxHealth = v.ACF.MaxHealth
				})
			end
		end

		if next(Table) then
			net.Start("ACF_RenderDamage")
				net.WriteTable(Table)
			net.Send(ply)
		end
	end)
end

do -- KE Shove
	function ACF.KEShove(Target, Pos, Vec, KE)
		if HookRun("ACF_KEShove", Target, Pos, Vec, KE) == false then return end

		local Ancestor = ACF_GetAncestor(Target)
		local Phys = Ancestor:GetPhysicsObject()

		if IsValid(Phys) then
			if not Ancestor.acflastupdatemass or Ancestor.acflastupdatemass + 2 < ACF.CurTime then
				ACF_CalcMassRatio(Ancestor)
			end

			local Ratio = Ancestor.acfphystotal / Ancestor.acftotal
			local LocalPos = Ancestor:WorldToLocal(Pos) * Ratio

			Phys:ApplyForceOffset(Vec:GetNormalized() * KE * Ratio, Ancestor:LocalToWorld(LocalPos))
		end
	end
end

do -- Explosions ----------------------------
	local Bullet = {
		IsFrag   = true, -- We need to let people know this isn't a regular bullet somehow
		Owner    = true,
		Gun      = true,
		Caliber  = true,
		Diameter = true,
		ProjArea = true,
		ProjMass = true,
		Flight   = true,
		Speed    = true,
	}

	function Bullet:GetPenetration()
		return ACF.Penetration(self.Speed, self.ProjMass, self.Diameter * 10)
	end

	local HE do
		-- boom!
		-- deals damage to all entities within the blast radius and in line of sight with the explosion
		-- entities penetrated by the blast are filtered out and those now exposed are also damaged
		-- entities are dealt damage based on their distance from the explosion
		-- damage is not reduced by penetration

		local check     = ACF.Check
		local rand      = math.Rand
		local trace     = util.TraceLine -- TODO: Replace with ACF.Trace (which is causing crashes for some reason)
		local traceRes  = {}
		local traceData = { start = true, endpos = true, mask = MASK_SOLID, filter = true, output = traceRes }

		local COLOR_WHITE  = Color(255, 255, 255)
		local COLOR_RED    = Color(255, 0, 0)
		local COLOR_RED_TRANSPARENT = Color(255, 0, 0, 1)
		local COLOR_DARK   = Color(25, 25, 25, 25) -- hey thats not a real color!
		local COLOR_GREEN  = Color(0, 255, 0)
		local COLOR_GREEN_TRANSPARENT = Color(0, 255, 0, 25)
		local COLOR_YELLOW = Color(255, 255, 0)
		local COLOR_YELLOW_TRANSPARENT = Color(255, 255, 0, 25)

		local DEBUG_TIME = 30
		local traces = 0

		local blast, targets = {}, {} -- tables that will be continually re-used for each HE call

		local function getRandomPos(ent)
			if ent:IsPlayer() or ent:IsNPC() then
				-- TODO: Improve this?
				local point = VectorRand(ent:OBBMins(), ent:OBBMaxs()) * 0.65 -- scaled a bit smaller since most of a player is in the center

				return ent:LocalToWorld(point)
			elseif ent.IsAmmoCrate then
				-- we know ammo crates are cuboids, so this simplifies things
				return ent:LocalToWorld(VectorRand(ent:OBBMins(), ent:OBBMaxs()))
			else
				local mesh = ent:GetPhysicsObject():GetMesh()

				if mesh then
					-- for arbitrary models, pick a random triangle on the surface of a model and trace towards a random position on that triangle
					local modelTris, modelArea = ACF.GetModelTris(ent:GetModel())

					-- pick a weighted (by tri area) random triangle
					-- TODO: upgrade to binary search tree
					local rand = rand(0, modelArea)
					local select

					for k, v in ipairs(modelTris) do
						rand = rand - v.area

						if rand < 0 then
							select = modelTris[k]
							break
						end
					end

					-- pick a random point inside the selected triangle
					local a, b, c = select.points[1], select.points[2], select.points[3]

					local r1, r2 = math.Rand(0, 1), math.Rand(0, 1)
					if r1 + r2 >= 1 then r1, r2 = 1 - r1, 1 - r2 end

					local point = a + r1 * (b - a) + r2 * (c - a)

					--debugoverlay.Cross(ent:LocalToWorld(point), 3, 5, Color(0, 255, 160), true)
					return ent:LocalToWorld(point)
				else -- make-spherical
					-- pick a random point inside sphere
					local point = VectorRand():GetNormalized() * math.Rand(0, ent:BoundingRadius())

					return ent:LocalToWorld(point)
				end
			end
		end

		local canSee do
			-- attempts to acquire line of sight on an entity by tracing towards a random position on the model
			-- returns:
			--		ENTITY: the entity being hit by the trace (nonworld, any valid ACF entity) or false
			--		BOOL: if the entity hit by the trace was the intended target
			--		VECTOR: hit position of the trace

			local attempts = 2
			local padding  = 12 -- distance to trace past intended target

			function canSee(origin, ent)
				for _ = 1, attempts do
					local pos = getRandomPos(ent)

					traceData.endpos = pos + (pos - origin):GetNormalized() * padding

					trace(traceData)
					traces = traces + 1
					local hitEnt = traceRes.HitNonWorld and traceRes.Entity or ent -- not hitting anything counts as hitting the intended target

					if traceRes.HitWorld then continue end -- failed: hit world
					if hitEnt ~= ent then
						if not check(hitEnt) then continue end -- failed: hit bad entity -- perf concern here with ACF.Check being called on the same ents repeatedly
					end

					return hitEnt, hitEnt == ent, traceRes.HitPos
				end

				return false,  hitEnt == ent, traceRes.HitPos
			end
		end

		local function debugColor(ent, color)
			if not GetConVar("developer"):GetBool() then return end

			ent._colorRestore    = ent._colorRestore or ent:GetColor()
			ent._materialRestore = ent._materialRestore or ent:GetMaterial()

			ent:SetColor(color)
			ent:SetMaterial("models/debug/debugwhite")

			timer.Create(ent:EntIndex() .. " debugcolor", DEBUG_TIME, 1, function()
				if IsValid(ent) then
					ent:SetColor(ent._colorRestore)
					ent:SetMaterial(ent._materialRestore)

					ent._materialRestore = nil
					ent._colorRestore    = nil
				end
			end)
		end

		local function getTargets()
			-- finds all entities in a radius around the blast center
			-- filters out acf-invalid entities and dead players/npcs
			-- updates the 'targets' table with a table of entities stored in occluder:{occluded} pairs

			local list   = ents.FindInSphere(blast.pos, blast.radius)
			local out    = {}
			local lookup = {}; for k, v in pairs(blast.filter) do lookup[v] = k end

			for _, testEnt in pairs(list) do
				if lookup[testEnt] then continue end -- already filtered
				if not check(testEnt) or (testEnt:IsPlayer() or testEnt:IsNPC()) and testEnt:Health() <= 0 then
					blast.filter[#blast.filter + 1] = testEnt
					lookup[testEnt] = true
				else
					-- valid target
					-- check to see what's in the way
					local hitEnt, hitIntended, hitPos = canSee(blast.pos, testEnt)

					if hitEnt then
						-- hit a valid entity
						-- hitEnt will always be an entity on the outside of the vehicle directly visible to the explosion
						-- if hitEnt is not the intended target then testEnt is being occluded by hitEnt

						out[hitEnt] = out[hitEnt] or {}

						if not hitIntended then
							out[hitEnt][testEnt] = true
						end
					end
				end
			end

			targets.all     = out
			targets.damaged = {}
		end

		local function damageTargets()
			-- damages all ents visible to the explosion
			-- if an occluder is destroyed or penetrated: filter it from traces and attempt to damage it's occluded entities
			-- if an occluded entity is destroyed or penetrated: filter it, remove from the list of occludded entities, and try again

			for ent, occluded in pairs(targets.all) do
				-- looping over all of the occluders, the entities immediately visible to the explosion
				-- everything can only be damaged once
				if targets.damaged[ent] then continue end
				targets.damaged[ent] = true

				if blast.pen >= ent.ACF.Armour or blast.dmg >= ent.ACF.Health then
					-- target was penetrated or destroyed
					-- filter from future traces then damage the now-visible entities

					traceData.filter[#traceData.filter + 1] = ent

					-- reduce the penetration applied to subsequent targets
					local pen = blast.pen - ent.ACF.Armour
					local dmg = blast.dmg -- ent.ACF.Health
					local rep = true

					-- go through the list of entities that are now visible through the hole just made
					-- the ents aren't necessarily in the order they appear to the explosion and there also may be other entities in the way
					-- so, this section repeats until every entity has been damaged, all penetration power has been used, or no more entities are visible
					while rep and next(occluded) do
						rep = false

						for subEnt in pairs(occluded) do
							if targets.damaged[subEnt] then continue end
							if targets.all[subEnt] then continue end -- skip occluders, they'll have their chance

							local hitEnt, hitIntended, hitPos = canSee(blast.pos, subEnt)

							if hitEnt and not targets.damaged[hitEnt] then
								targets.damaged[hitEnt] = true

								if pen >= hitEnt.ACF.Armour or dmg >= hitEnt.ACF.Health then
									pen = blast.pen - ent.ACF.Armour

									debugColor(hitEnt, COLOR_RED)
									debugoverlay.Line(blast.pos, hitEnt:GetPos(), DEBUG_TIME, COLOR_YELLOW, true)
									--debugoverlay.Text(hitEnt:GetPos(), "Penetrated!", DEBUG_TIME, true)

									if pen > 0 then -- if there is penetration left, keep going
										rep = true

										traceData.filter[#traceData.filter + 1] = hitEnt

										if hitIntended then
											table.remove(occluded, idx)
										end
									else
										-- out of penetration power!
										goto BREAK
									end
								else
									debugColor(hitEnt, COLOR_YELLOW)
									break
								end
							end
						end
					end

					::BREAK::

					debugColor(ent, COLOR_RED)
					debugoverlay.Line(blast.pos, ent:GetPos(), DEBUG_TIME, COLOR_GREEN, true)
					--debugoverlay.Text(ent:GetPos(), "Penetrated!", DEBUG_TIME, true)
				else
					debugColor(ent, COLOR_YELLOW)
				end
			end
		end

		function HE(pos, filler, filter, dmginfo)
			traces = 0
			filter = filter or {}

			blast.pos     = pos
			blast.power   = filler * ACF.HEPower -- Power in KJ
			blast.radius  = filler ^ 0.33 * 8 * 39.37
			blast.radius2 = blast.radius ^ 2
			blast.area    = 4 * 3.1415 * (blast.radius * 2.54) ^ 2 -- Blast surface area
			blast.dmg     = filler * 0.5
			blast.pen     = filler / 1
			blast.filter  = filter

			print("Blast Damage: " .. blast.dmg)
			print("Blast Penetration: " .. blast.pen)

			traceData.filter = filter
			traceData.start  = pos

			local time = SysTime()
			getTargets()
			damageTargets()
			print("Calc time: " .. string.format("%.F", (SysTime() - time) * 1000))

			if hook.Run("acf.damage.screenshake") ~= false then
				local amp = math.min(blast.power / 2000, 50)
				--util.ScreenShake(blast.pos, amp, amp, amp, blast.radius * 10)
			end

			print("Total traces used: " .. traces)
			debugoverlay.Cross(blast.pos, blast.radius, DEBUG_TIME, COLOR_WHITE, true)
			debugoverlay.Sphere(blast.pos, blast.radius, DEBUG_TIME, COLOR_RED_TRANSPARENT, false)
		end

		ACF.HE = HE
	end

	ACF_HE = ACF.HE
end -----------------------------------------

do -- Overpressure --------------------------
	ACF.Squishies = ACF.Squishies or {}

	local Squishies = ACF.Squishies

	-- InVehicle and GetVehicle are only for players, we have NPCs too!
	local function GetVehicle(Entity)
		if not IsValid(Entity) then return end

		local Parent = Entity:GetParent()

		if not Parent:IsVehicle() then return end

		return Parent
	end

	local function CanSee(Target, Data)
		local R = ACF.Trace(Data)

		return R.Entity == Target or not R.Hit or R.Entity == GetVehicle(Target)
	end

	hook.Add("PlayerSpawnedNPC", "ACF Squishies", function(_, Ent)
		Squishies[Ent] = true
	end)

	hook.Add("OnNPCKilled", "ACF Squishies", function(Ent)
		Squishies[Ent] = nil
	end)

	hook.Add("PlayerSpawn", "ACF Squishies", function(Ent)
		Squishies[Ent] = true
	end)

	hook.Add("PostPlayerDeath", "ACF Squishies", function(Ent)
		Squishies[Ent] = nil
	end)

	hook.Add("EntityRemoved", "ACF Squishies", function(Ent)
		Squishies[Ent] = nil
	end)

	function ACF.Overpressure(Origin, Energy, Inflictor, Source, Forward, Angle)
		local Radius = Energy ^ 0.33 * 0.025 * 39.37 -- Radius in meters (Completely arbitrary stuff, scaled to have 120s have a radius of about 20m)
		local Data = { start = Origin, endpos = true, mask = MASK_SHOT }

		if Source then -- Filter out guns
			if Source.BarrelFilter then
				Data.filter = {}

				for K, V in pairs(Source.BarrelFilter) do Data.filter[K] = V end -- Quick copy of gun barrel filter
			else
				Data.filter = { Source }
			end
		end

		util.ScreenShake(Origin, Energy, 1, 0.25, Radius * 3 * 39.37 )

		if Forward and Angle then -- Blast direction and angle are specified
			Angle = math.rad(Angle * 0.5) -- Convert deg to rads

			for V in pairs(Squishies) do
				local Position = V:EyePos()

				if math.acos(Forward:Dot((Position - Origin):GetNormalized())) < Angle then
					local D = Position:Distance(Origin)

					if D / 39.37 <= Radius then

						Data.endpos = Position + VectorRand() * 5

						if CanSee(V, Data) then
							local Damage = Energy * 175000 * (1 / D^3)

							V:TakeDamage(Damage, Inflictor, Source)
						end
					end
				end
			end
		else -- Spherical blast
			for V in pairs(Squishies) do
				local Position = V:EyePos()

				if CanSee(Origin, V) then
					local D = Position:Distance(Origin)

					if D / 39.37 <= Radius then

						Data.endpos = Position + VectorRand() * 5

						if CanSee(V, Data) then
							local Damage = Energy * 150000 * (1 / D^3)

							V:TakeDamage(Damage, Inflictor, Source)
						end
					end
				end
			end
		end
	end
end -----------------------------------------

do -- Deal Damage ---------------------------
	local TimerCreate = timer.Create

	local function CalcDamage(Bullet, Trace, Volume)
		-- TODO: Why are we getting impact angles outside these bounds?
		local Angle   = math.Clamp(ACF_GetHitAngle(Trace.HitNormal, Bullet.Flight), -90, 90)
		local Area    = Bullet.ProjArea
		local HitRes  = {}

		local Caliber        = Bullet.Diameter * 10
		local BaseArmor      = Trace.Entity.ACF.Armour
		local SlopeFactor    = BaseArmor / Caliber
		local EffectiveArmor = BaseArmor / math.abs(math.cos(math.rad(Angle)) ^ SlopeFactor)
		local MaxPenetration = Bullet:GetPenetration() --RHA Penetration

		if MaxPenetration > EffectiveArmor then
			HitRes.Damage   = isnumber(Volume) and Volume or Area -- Inflicted Damage
			HitRes.Overkill = MaxPenetration - EffectiveArmor -- Remaining penetration
			HitRes.Loss     = EffectiveArmor / MaxPenetration -- Energy loss in percents
		else
			-- Projectile did not penetrate the armor
			HitRes.Damage   = isnumber(Volume) and Volume or (MaxPenetration / EffectiveArmor) ^ 2 * Area
			HitRes.Overkill = 0
			HitRes.Loss     = 1
		end

		return HitRes
	end

	local function SquishyDamage(Bullet, Trace, Volume)
		local Entity = Trace.Entity
		local Size   = Entity:BoundingRadius()
		local Mass   = Entity:GetPhysicsObject():GetMass()
		local HitRes = {}
		local Damage = 0

		--We create a dummy table to pass armour values to the calc function
		local Target = {
			ACF = {
				Armour = 0.1
			}
		}

		if Bone then
			--This means we hit the head
			if Bone == 1 then
				Target.ACF.Armour = Mass * 0.02 --Set the skull thickness as a percentage of Squishy weight, this gives us 2mm for a player, about 22mm for an Antlion Guard. Seems about right
				HitRes = CalcDamage(Bullet, Trace, Volume) --This is hard bone, so still sensitive to impact angle
				Damage = HitRes.Damage * 20

				--If we manage to penetrate the skull, then MASSIVE DAMAGE
				if HitRes.Overkill > 0 then
					Target.ACF.Armour = Size * 0.25 * 0.01 --A quarter the bounding radius seems about right for most critters head size
					HitRes = CalcDamage(Bullet, Trace, Volume)
					Damage = Damage + HitRes.Damage * 100
				end

				Target.ACF.Armour = Mass * 0.065 --Then to check if we can get out of the other side, 2x skull + 1x brains
				HitRes = CalcDamage(Bullet, Trace, Volume)
				Damage = Damage + HitRes.Damage * 20
			elseif Bone == 0 or Bone == 2 or Bone == 3 then
				--This means we hit the torso. We are assuming body armour/tough exoskeleton/zombie don't give fuck here, so it's tough
				Target.ACF.Armour = Mass * 0.08 --Set the armour thickness as a percentage of Squishy weight, this gives us 8mm for a player, about 90mm for an Antlion Guard. Seems about right
				HitRes = CalcDamage(Bullet, Trace, Volume) --Armour plate,, so sensitive to impact angle
				Damage = HitRes.Damage * 5

				if HitRes.Overkill > 0 then
					Target.ACF.Armour = Size * 0.5 * 0.02 --Half the bounding radius seems about right for most critters torso size
					HitRes = CalcDamage(Bullet, Trace, Volume)
					Damage = Damage + HitRes.Damage * 50 --If we penetrate the armour then we get into the important bits inside, so DAMAGE
				end

				Target.ACF.Armour = Mass * 0.185 --Then to check if we can get out of the other side, 2x armour + 1x guts
				HitRes = CalcDamage(Bullet, Trace, Volume)
			elseif Bone == 4 or Bone == 5 then
				--This means we hit an arm or appendage, so ormal damage, no armour
				Target.ACF.Armour = Size * 0.2 * 0.02 --A fitht the bounding radius seems about right for most critters appendages
				HitRes = CalcDamage(Bullet, Trace, Volume) --This is flesh, angle doesn't matter
				Damage = HitRes.Damage * 30 --Limbs are somewhat less important
			elseif Bone == 6 or Bone == 7 then
				Target.ACF.Armour = Size * 0.2 * 0.02 --A fitht the bounding radius seems about right for most critters appendages
				HitRes = CalcDamage(Bullet, Trace, Volume) --This is flesh, angle doesn't matter
				Damage = HitRes.Damage * 30 --Limbs are somewhat less important
			elseif (Bone == 10) then
				--This means we hit a backpack or something
				Target.ACF.Armour = Size * 0.1 * 0.02 --Arbitrary size, most of the gear carried is pretty small
				HitRes = CalcDamage(Bullet, Trace, Volume) --This is random junk, angle doesn't matter
				Damage = HitRes.Damage * 2 --Damage is going to be fright and shrapnel, nothing much
			else --Just in case we hit something not standard
				Target.ACF.Armour = Size * 0.2 * 0.02
				HitRes = CalcDamage(Bullet, Trace, Volume)
				Damage = HitRes.Damage * 30
			end
		else --Just in case we hit something not standard
			Target.ACF.Armour = Size * 0.2 * 0.02
			HitRes = CalcDamage(Bullet, Trace, Volume)
			Damage = HitRes.Damage * 10
		end

		Entity:TakeDamage(Damage, Inflictor, Gun)

		HitRes.Kill = false

		return HitRes
	end

	local function VehicleDamage(Bullet, Trace, Volume)
		local HitRes = CalcDamage(Bullet, Trace, Volume)
		local Entity = Trace.Entity
		local Driver = Entity:GetDriver()

		if IsValid(Driver) then
			Trace.HitGroup = math.Rand(0, 7) -- Hit a random part of the driver
			SquishyDamage(Bullet, Trace) -- Deal direct damage to the driver
		end

		HitRes.Kill = false

		if HitRes.Damage >= Entity.ACF.Health then
			HitRes.Kill = true
		else
			Entity.ACF.Health = Entity.ACF.Health - HitRes.Damage
			Entity.ACF.Armour = Entity.ACF.Armour * (0.5 + Entity.ACF.Health / Entity.ACF.MaxHealth / 2) --Simulating the plate weakening after a hit
		end

		return HitRes
	end

	local function PropDamage(Bullet, Trace, Volume)
		local Entity = Trace.Entity
		local HitRes = CalcDamage(Bullet, Trace, Volume)

		HitRes.Kill = false

		if HitRes.Damage >= Entity.ACF.Health then
			HitRes.Kill = true
		else
			Entity.ACF.Health = Entity.ACF.Health - HitRes.Damage
			Entity.ACF.Armour = math.Clamp(Entity.ACF.MaxArmour * (0.5 + Entity.ACF.Health / Entity.ACF.MaxHealth / 2) ^ 1.7, Entity.ACF.MaxArmour * 0.25, Entity.ACF.MaxArmour) --Simulating the plate weakening after a hit

			--math.Clamp( Entity.ACF.Ductility, -0.8, 0.8 )
			if Entity.ACF.PrHealth and Entity.ACF.PrHealth ~= Entity.ACF.Health then
				if not ACF_HealthUpdateList then
					ACF_HealthUpdateList = {}

					-- We should send things slowly to not overload traffic.
					TimerCreate("ACF_HealthUpdateList", 1, 1, function()
						local Table = {}

						for _, v in pairs(ACF_HealthUpdateList) do
							if IsValid(v) then
								table.insert(Table, {
									ID = v:EntIndex(),
									Health = v.ACF.Health,
									MaxHealth = v.ACF.MaxHealth
								})
							end
						end

						net.Start("ACF_RenderDamage")
							net.WriteTable(Table)
						net.Broadcast()

						ACF_HealthUpdateList = nil
					end)
				end

				table.insert(ACF_HealthUpdateList, Entity)
			end

			Entity.ACF.PrHealth = Entity.ACF.Health
		end

		return HitRes
	end

	ACF.PropDamage = PropDamage

	function ACF.Damage(Bullet, Trace, Volume)
		local Entity = Trace.Entity
		local Type   = ACF.Check(Entity)

		if HookRun("ACF_BulletDamage", Bullet, Trace) == false or Type == false then
			return { -- No damage
				Damage = 0,
				Overkill = 0,
				Loss = 0,
				Kill = false
			}
		end

		if Entity.ACF_OnDamage then -- Use special damage function if target entity has one
			return Entity:ACF_OnDamage(Bullet, Trace, Volume)
		elseif Type == "Prop" then
			return PropDamage(Bullet, Trace, Volume)
		elseif Type == "Vehicle" then
			return VehicleDamage(Bullet, Trace, Volume)
		elseif Type == "Squishy" then
			return SquishyDamage(Bullet, Trace, Volume)
		end
	end

	ACF_Damage = ACF.Damage
end -----------------------------------------

do -- Remove Props ------------------------------
	util.AddNetworkString("ACF_Debris")

	local ValidDebris = ACF.ValidDebris
	local ChildDebris = ACF.ChildDebris
	local Queue       = {}

	local function SendQueue()
		for Entity, Data in pairs(Queue) do
			local JSON = util.TableToJSON(Data)

			net.Start("ACF_Debris")
				net.WriteString(JSON)
			net.SendPVS(Data.Position)

			Queue[Entity] = nil
		end
	end

	local function DebrisNetter(Entity, Normal, Power, CanGib, Ignite)
		if not ACF.GetServerBool("CreateDebris") then return end
		if Queue[Entity] then return end

		local Current = Entity:GetColor()
		local New     = Vector(Current.r, Current.g, Current.b) * math.Rand(0.3, 0.6)

		if not next(Queue) then
			timer.Create("ACF_DebrisQueue", 0, 1, SendQueue)
		end

		Queue[Entity] = {
			Position = Entity:GetPos(),
			Angles   = Entity:GetAngles(),
			Material = Entity:GetMaterial(),
			Model    = Entity:GetModel(),
			Color    = Color(New.x, New.y, New.z, Current.a),
			Normal   = Normal,
			Power    = Power,
			CanGib   = CanGib or nil,
			Ignite   = Ignite or nil,
		}
	end

	function ACF.KillChildProps(Entity, BlastPos, Energy)
		local Explosives = {}
		local Children 	 = ACF_GetAllChildren(Entity)
		local Count		 = 0

		-- do an initial processing pass on children, separating out explodey things to handle last
		for Ent in pairs(Children) do
			Ent.ACF_Killed = true -- mark that it's already processed

			if not ValidDebris[Ent:GetClass()] then
				Children[Ent] = nil -- ignoring stuff like holos, wiremod components, etc.
			else
				Ent:SetParent()

				if Ent.IsExplosive and not Ent.Exploding then
					Explosives[Ent] = true
					Children[Ent] 	= nil
				else
					Count = Count + 1
				end
			end
		end

		-- HE kill the children of this ent, instead of disappearing them by removing parent
		if next(Children) then
			local DebrisChance 	= math.Clamp(ChildDebris / Count, 0, 1)
			local Power 		= Energy / math.min(Count,3)

			for Ent in pairs( Children ) do
				if math.random() < DebrisChance then
					ACF.HEKill(Ent, (Ent:GetPos() - BlastPos):GetNormalized(), Power)
				else
					constraint.RemoveAll(Ent)
					Ent:Remove()
				end
			end
		end

		-- explode stuff last, so we don't re-process all that junk again in a new explosion
		if next(Explosives) then
			for Ent in pairs(Explosives) do
				if Ent.Exploding then continue end

				Ent.Exploding = true
				Ent.Inflictor = Entity.Inflictor
				Ent:Detonate()
			end
		end
	end

	function ACF.HEKill(Entity, Normal, Energy, BlastPos) -- blast pos is an optional world-pos input for flinging away children props more realistically
		-- if it hasn't been processed yet, check for children
		if not Entity.ACF_Killed then
			ACF.KillChildProps(Entity, BlastPos or Entity:GetPos(), Energy)
		end

		local Radius = Entity:BoundingRadius()
		local Debris = {}

		DebrisNetter(Entity, Normal, Energy, false, true)

		if ACF.GetServerBool("CreateFireballs") then
			local Fireballs = math.Clamp(Radius * 0.01, 1, math.max(10 * ACF.GetServerNumber("FireballMult", 1), 1))
			local Min, Max = Entity:OBBMins(), Entity:OBBMaxs()
			local Pos = Entity:GetPos()
			local Ang = Entity:GetAngles()

			for _ = 1, Fireballs do -- should we base this on prop volume?
				local Fireball = ents.Create("acf_debris")

				if not IsValid(Fireball) then break end -- we probably hit edict limit, stop looping

				local Lifetime = math.Rand(5, 15)
				local Offset   = ACF.RandomVector(Min, Max)

				Offset:Rotate(Ang)

				Fireball:SetPos(Pos + Offset)
				Fireball:Spawn()
				Fireball:Ignite(Lifetime)

				timer.Simple(Lifetime, function()
					if not IsValid(Fireball) then return end

					Fireball:Remove()
				end)

				local Phys = Fireball:GetPhysicsObject()

				if IsValid(Phys) then
					Phys:ApplyForceOffset(Normal * Energy / Fireballs, Fireball:GetPos() + VectorRand())
				end

				Debris[Fireball] = true
			end
		end

		constraint.RemoveAll(Entity)
		Entity:Remove()

		return Debris
	end

	function ACF.APKill(Entity, Normal, Power)
		ACF.KillChildProps(Entity, Entity:GetPos(), Power) -- kill the children of this ent, instead of disappearing them from removing parent

		DebrisNetter(Entity, Normal, Power, true, false)

		constraint.RemoveAll(Entity)
		Entity:Remove()
	end

	ACF_KillChildProps = ACF.KillChildProps
	ACF_HEKill = ACF.HEKill
	ACF_APKill = ACF.APKill
end
