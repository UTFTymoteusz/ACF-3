local ACF     = ACF
local HookRun = hook.Run

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
	local TraceData = { start = true, endpos = true, filter = true, mask = MASK_SOLID }
	local Bullet = {
		IsFrag   = true, -- We need to let people know this isn't a regular bullet somehow
		Owner    = true,
		Gun      = true,
		Caliber  = true,
		Energy   = true,
		PenArea  = true,
		ProjArea = true,
	}

	local function GetRandomPos(Entity, IsChar)
		if IsChar then
			local Mins, Maxs = Entity:OBBMins() * 0.65, Entity:OBBMaxs() * 0.65 -- Scale down the "hitbox" since most of the character is in the middle
			local Rand		 = Vector(math.Rand(Mins[1], Maxs[1]), math.Rand(Mins[2], Maxs[2]), math.Rand(Mins[3], Maxs[3]))

			return Entity:LocalToWorld(Rand)
		else
			local Mesh = Entity:GetPhysicsObject():GetMesh()

			if not Mesh then -- Using spherical collisions
				local Mins, Maxs = Entity:OBBMins(), Entity:OBBMaxs()
				local Rand		 = Vector(math.Rand(Mins[1], Maxs[1]), math.Rand(Mins[2], Maxs[2]), math.Rand(Mins[3], Maxs[3]))

				return Entity:LocalToWorld(Rand:GetNormalized() * math.Rand(1, Entity:BoundingRadius() * 0.5)) -- Attempt to a random point in the sphere
			else
				local Rand = math.random(3, #Mesh / 3) * 3
				local P    = Vector(0, 0, 0)

				for I = Rand - 2, Rand do P = P + Mesh[I].pos end

				return Entity:LocalToWorld(P / 3) -- Attempt to hit a point on a face of the mesh
			end
		end
	end

	function ACF.HE(Origin, FillerMass, CaseMass, Inflictor, Filter, Gun)
		do -- Set up trace data
			Filter = Filter or {}

			TraceData.filter = Filter
			TraceData.start  = Origin
		end

		local Blast = ACF.ConvertHE(FillerMass, CaseMass)

		local TotalPower  = Blast.TotalPower
		local BlastRadius = Blast.BlastRadius
		local BlastArea   = Blast.BlastArea
		local BlastRatio  = Blast.BlastRatio
		local FragCount   = Blast.FragCount
		local FragMass    = Blast.FragMass
		local FragArea    = Blast.FragArea
		local FragVel     = Blast.FragVel

		local Damage     = {} -- Entities to be damaged
		local Damaged	 = {} -- Already damaged entities that are filtered out from searches
		local Ents 		 = ents.FindInSphere(Origin, BlastRadius)
		local Loop 		 = true -- Whether to more props to damage whenever a prop dies

		local Amp = math.min(TotalPower / 2000, 50)
		util.ScreenShake(Origin, Amp, Amp, Amp / 15, BlastRadius * 10)

		debugoverlay.Cross(Origin, 15, 15, Color( 255, 255, 255 ), true)
		debugoverlay.Sphere(Origin, BlastRadius, 15, Color( 255, 100, 0, 5))

		-- We only need to set these once
		Bullet.Owner = Inflictor
		Bullet.Gun   = Gun

		while Loop and TotalPower > 0 do
			Loop = false

			for I = #Ents, 1, -1 do -- Find entities to deal damage to
				local Ent = Ents[I]

				if not ACF.Check(Ent) then -- Entity is not valid to ACF

					table.remove(Ents, I) -- Remove from list

					if IsValid(Ent) then
						Filter[#Filter + 1] = Ent -- Filter from traces
					end

					continue
				end

				if Damaged[Ent] then continue end -- A trace sent towards another prop already hit this one instead, no need to check if we can see it

				if Ent.Exploding then -- Detonate explody things immediately if they're already cooking off
					table.remove(Ents, I)
					Filter[#Filter + 1] = Ent

					--Ent:Detonate()
					continue
				end

				local IsChar = Ent:IsPlayer() or Ent:IsNPC()
				if IsChar and Ent:Health() <= 0 then
					table.remove(Ents, I)
					Filter[#Filter + 1] = Ent -- Shouldn't need to filter a dead player but we'll do it just in case

					continue
				end

				local Target = GetRandomPos(Ent, IsChar) -- Try to hit a random spot on the entity
				local Displ	 = Target - Origin

				TraceData.endpos = Origin + Displ:GetNormalized() * (Displ:Length() + 24)

				local TraceRes = ACF.TraceF(TraceData)

				if TraceRes.HitNonWorld then
					Ent = TraceRes.Entity

					if ACF.Check(Ent) then
						if not Ent.Exploding and not Damaged[Ent] then -- Hit an entity that we haven't already damaged yet
							local Mul = IsChar and 0.65 or 1 -- Scale down boxes for players/NPCs because the bounding box is way bigger than they actually are

							debugoverlay.BoxAngles(Ent:GetPos(), Ent:OBBMins() * Mul, Ent:OBBMaxs() * Mul, Ent:GetAngles(), 30, Color(255, 255, 255, 1))

							if Ents[I] == Ent then
								table.remove(Ents, I) -- Removed from future damage searches (but may still block LOS)
							end

							Damaged[Ent] = TraceRes -- This entity can no longer recieve damage from this explosion (also used to pass hitnormal)
							Damage[Ent]  = true
						end
					else -- If check on new ent fails
						debugoverlay.Line(Origin, TraceRes.HitPos, 30, Color(255, 0, 0)) -- Red line for a invalid ent

						table.remove(Ents, I) -- Remove from list

						Filter[#Filter + 1] = Ent -- Filter from traces
					end
				else
					-- Not removed from future damage sweeps so as to provide multiple chances to be hit
					debugoverlay.Line(Origin, TraceRes.HitPos, 30, Color(0, 0, 255)) -- Blue line for a miss
				end
			end

			for Ent in pairs(Damage) do -- Deal damage to the entities we found
				if TotalPower <= 0 then break end

				Damage[Ent] = nil

				local Trace         = Damaged[Ent]
				local Displacement  = Trace.HitPos - Origin
				local Distance	    = Displacement:Length()
				local Sphere 	    = math.max(4 * 3.1415 * (Distance * 2.54) ^ 2, 1) -- Surface Area of the sphere at the range of that prop
				local Area 		    = math.min(Ent.ACF.Area / Sphere, 0.5) * BlastArea -- Project the Area of the prop to the Area of the shadow it projects at the explosion max radius
				local Feathering 	= (1 - math.min(1, Distance / BlastRadius)) ^ ACF.HEFeatherExp
				local AreaFraction 	= Area / BlastArea
				local PowerFraction = TotalPower * AreaFraction -- How much of the total power goes to that prop
				local BlastPower    = PowerFraction * BlastRatio
				local AreaAdjusted 	= (Ent.ACF.Area / ACF.Threshold) * Feathering

				Bullet.Caliber = math.Rand(0.1, 1) -- Random fragment caliber
				Bullet.Flight  = Displacement

				do -- Frag damage
					local FragHit = math.floor(FragCount * AreaFraction)

					if FragHit > 0 then -- A fragment hit
						Bullet.ProjArea = FragArea
						Bullet.PenArea  = FragArea ^ ACF.PenAreaMod
						Bullet.Energy   = ACF_Kinetic(FragVel * (Distance * 0.5 / BlastRadius), FragMass)

						local FragRes = ACF.Damage(Bullet, Trace, FragHit)

						TotalPower = TotalPower - Bullet.Energy.Kinetic * FragCount * FragRes.Loss -- Removing the energy spent towards this prop

						if FragRes.Kill then -- Killed the ent
							Filter[#Filter + 1] = Ent -- Filter just in case
							Loop = true -- Check for new targets since something was killed

							debugoverlay.Line(Origin, Trace.HitPos + VectorRand(2), 30, Color(255, 0, 0), true)

							continue
						else
							if FragRes.Overkill > 0 then -- Fragment penetrated
								Filter[#Filter + 1] = Ent -- Filter out penetrated entity

								debugoverlay.Line(Origin, Trace.HitPos + VectorRand(2), 30, Color(255, 255, 0), true)
								Loop = true -- Check for new targets since something was penetrated
							else
								debugoverlay.Line(Origin, Trace.HitPos + VectorRand(2), 30, Color(255, 255, 255), true)
							end

							if ACF.HEPush then
								local FragPower = PowerFraction - BlastPower

								ACF.KEShove(Ent, Origin, Displacement:GetNormalized(), FragPower * FragRes.Loss)
							end
						end
					end
				end

				do -- Blast damage
					Bullet.ProjArea = AreaAdjusted
					Bullet.PenArea  = AreaAdjusted ^ ACF.PenAreaMod
					Bullet.Energy   = { Penetration = BlastPower ^ ACF.HEBlastPen * AreaAdjusted }

					local BlastRes = ACF.Damage(Bullet, Trace)

					TotalPower = TotalPower - BlastPower * BlastRes.Loss

					if BlastRes.Kill then -- Blast killed something
						Filter[#Filter + 1] = Ent -- Filter out the dead prop

						local Debris = ACF.HEKill(Ent, Displacement:GetNormalized(), BlastPower, Origin) -- Make some debris

						for Fireball in pairs(Debris) do
							if IsValid(Fireball) then Filter[#Filter + 1] = Fireball end -- Filter that out too
						end

						Loop = true -- Check for new targets since something died, maybe we'll find something new
					else
						if BlastRes.Overkill > 0 then -- Blast penetrated
							Filter[#Filter + 1] = Ent
							Loop = true
						end

						if ACF.HEPush then -- Just damaged, not killed, so push on it some
							ACF.KEShove(Ent, Origin, Displacement:GetNormalized(), BlastPower * BlastRes.Loss)
						end
					end
				end
			end
		end
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
		local R = ACF.TraceF(Data)

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

	--local function CalcDamage(Entity, Energy, FrArea, Angle, Mult)
	local function CalcDamage(Bullet, Trace, Multiplier)
		-- TODO: Why are we getting impact angles outside these bounds?
		local Angle          = math.Clamp(ACF_GetHitAngle(Trace.HitNormal, Bullet.Flight), -90, 90)
		local Area           = Bullet.ProjArea * ACF.CheckNumber(Multiplier, 1)
		local BaseArmor      = Trace.Entity.ACF.Armour
		local SlopeFactor    = BaseArmor / (Bullet.Caliber * 10)
		local EffectiveArmor = BaseArmor / math.abs(math.cos(math.rad(Angle)) ^ SlopeFactor)
		local MaxPenetration = Bullet.Energy.Penetration / Bullet.PenArea * ACF.KEtoRHA --RHA Penetration
		local HitRes         = { Damage = true, Overkill = true, Loss = true }

		if Bullet.IsFrag then
			print(MaxPenetration, Multiplier)
		end

		if MaxPenetration > EffectiveArmor then
			HitRes.Damage   = Area -- Inflicted Damage
			HitRes.Overkill = MaxPenetration - BaseArmor -- Remaining penetration
			HitRes.Loss     = BaseArmor / MaxPenetration -- Energy loss in percents
		else
			-- Projectile did not penetrate the armor
			HitRes.Damage   = (MaxPenetration / EffectiveArmor) ^ 2 * Area
			HitRes.Overkill = 0
			HitRes.Loss     = 1
		end

		return HitRes
	end

	local function SquishyDamage(Bullet, Trace, Multiplier)
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
				HitRes = CalcDamage(Bullet, Trace, Multiplier) --This is hard bone, so still sensitive to impact angle
				Damage = HitRes.Damage * 20

				--If we manage to penetrate the skull, then MASSIVE DAMAGE
				if HitRes.Overkill > 0 then
					Target.ACF.Armour = Size * 0.25 * 0.01 --A quarter the bounding radius seems about right for most critters head size
					HitRes = CalcDamage(Bullet, Trace, Multiplier)
					Damage = Damage + HitRes.Damage * 100
				end

				Target.ACF.Armour = Mass * 0.065 --Then to check if we can get out of the other side, 2x skull + 1x brains
				HitRes = CalcDamage(Bullet, Trace, Multiplier)
				Damage = Damage + HitRes.Damage * 20
			elseif Bone == 0 or Bone == 2 or Bone == 3 then
				--This means we hit the torso. We are assuming body armour/tough exoskeleton/zombie don't give fuck here, so it's tough
				Target.ACF.Armour = Mass * 0.08 --Set the armour thickness as a percentage of Squishy weight, this gives us 8mm for a player, about 90mm for an Antlion Guard. Seems about right
				HitRes = CalcDamage(Bullet, Trace, Multiplier) --Armour plate,, so sensitive to impact angle
				Damage = HitRes.Damage * 5

				if HitRes.Overkill > 0 then
					Target.ACF.Armour = Size * 0.5 * 0.02 --Half the bounding radius seems about right for most critters torso size
					HitRes = CalcDamage(Bullet, Trace, Multiplier)
					Damage = Damage + HitRes.Damage * 50 --If we penetrate the armour then we get into the important bits inside, so DAMAGE
				end

				Target.ACF.Armour = Mass * 0.185 --Then to check if we can get out of the other side, 2x armour + 1x guts
				HitRes = CalcDamage(Bullet, Trace, Multiplier)
			elseif Bone == 4 or Bone == 5 then
				--This means we hit an arm or appendage, so ormal damage, no armour
				Target.ACF.Armour = Size * 0.2 * 0.02 --A fitht the bounding radius seems about right for most critters appendages
				HitRes = CalcDamage(Bullet, Trace, Multiplier) --This is flesh, angle doesn't matter
				Damage = HitRes.Damage * 30 --Limbs are somewhat less important
			elseif Bone == 6 or Bone == 7 then
				Target.ACF.Armour = Size * 0.2 * 0.02 --A fitht the bounding radius seems about right for most critters appendages
				HitRes = CalcDamage(Bullet, Trace, Multiplier) --This is flesh, angle doesn't matter
				Damage = HitRes.Damage * 30 --Limbs are somewhat less important
			elseif (Bone == 10) then
				--This means we hit a backpack or something
				Target.ACF.Armour = Size * 0.1 * 0.02 --Arbitrary size, most of the gear carried is pretty small
				HitRes = CalcDamage(Bullet, Trace, Multiplier) --This is random junk, angle doesn't matter
				Damage = HitRes.Damage * 2 --Damage is going to be fright and shrapnel, nothing much
			else --Just in case we hit something not standard
				Target.ACF.Armour = Size * 0.2 * 0.02
				HitRes = CalcDamage(Bullet, Trace, Multiplier)
				Damage = HitRes.Damage * 30
			end
		else --Just in case we hit something not standard
			Target.ACF.Armour = Size * 0.2 * 0.02
			HitRes = CalcDamage(Bullet, Trace, Multiplier)
			Damage = HitRes.Damage * 10
		end

		Entity:TakeDamage(Damage, Inflictor, Gun)

		HitRes.Kill = false

		return HitRes
	end

	local function VehicleDamage(Bullet, Trace, Multiplier)
		local HitRes = CalcDamage(Bullet, Trace, Multiplier)
		local Entity = Trace.Entity
		local Driver = Entity:GetDriver()

		if IsValid(Driver) then
			Trace.HitGroup = math.random(0, 7) -- Hit a random part of the driver

			SquishyDamage(Bullet, Trace, Multiplier) -- Deal direct damage to the driver
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

	local function PropDamage(Bullet, Trace, Multiplier)
		local Entity = Trace.Entity
		local HitRes = CalcDamage(Bullet, Trace, Multiplier)

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

	function ACF.Damage(Bullet, Trace, Multiplier)
		local Entity = Trace.Entity
		local Type   = ACF.Check(Entity)

		if HookRun("ACF_BulletDamage", Bullet, Trace, Multiplier) == false or Type == false then
			return { -- No damage
				Damage = 0,
				Overkill = 0,
				Loss = 0,
				Kill = false
			}
		end

		if Entity.ACF_OnDamage then -- Use special damage function if target entity has one
			return Entity:ACF_OnDamage(Bullet, Trace, Multiplier)
		elseif Type == "Prop" then
			return PropDamage(Bullet, Trace, Multiplier)
		elseif Type == "Vehicle" then
			return VehicleDamage(Bullet, Trace, Multiplier)
		elseif Type == "Squishy" then
			return SquishyDamage(Bullet, Trace, Multiplier)
		end
	end

	ACF_Damage = ACF.Damage
end -----------------------------------------

do -- Remove Props ------------------------------
	util.AddNetworkString("ACF_Debris")

	local ValidDebris = ACF.ValidDebris
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
			local DebrisChance 	= math.Clamp(ACF.ChildDebris / Count, 0, 1)
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
