local BLAST = {}
local meta  = {
    __index = BLAST
}

function ACF.explosive(filler)
    local exp = {}

    exp.__index = BLAST
    exp.pos     = Vector(0, 0, 0)
    exp.power   = filler * ACF.HEPower -- Power in KJ
    exp.radius  = filler ^ 0.33 * 8 * 39.37
    exp.radius2 = exp.radius ^ 2
    exp.area    = 4 * 3.1415 * (exp.radius * 2.54) ^ 2 -- Blast surface area
    exp.dmg     = filler * 0.5
    exp.pen     = filler / 1

    exp.lookupFilter = {}
    exp.rawFilter    = {}

    print("Blast damage: " .. exp.dmg)
    print("Blast penetration: " .. exp.pen)

    return setmetatable(exp, meta)
end

function BLAST:setPos(pos)
    self.pos = pos
end

function BLAST:setFilter(filter)
    -- sets the filter for a blast
    -- updates the lookup filter for use when finding targets

    self.rawFilter    = filter
    self.lookupFilter = {}

    for _, ent in ipairs(filter) do
        self.lookupFilter[ent] = true
    end
end

function BLAST:filter(ent)
    self.rawFilter[#self.rawFilter + 1] = ent
    self.lookupFilter[ent]              = true
end

local DEBUG_TIME   = 15
local COLOR_YELLOW = Color(255, 255, 0, 255)
local COLOR_RED    = Color(255, 0, 0, 255)
local COLOR_ORANGE = Color(255, 128, 0, 255)

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

local traceRes  = {}
local traceData = { output = traceRes }
local traces

local function traceLine()
    traces = traces + 1
    return util.TraceLine(traceData)
end

local function entsAlongRay(from, to)
    local ents  = {}
    local count = 0

    traceData.start  = from
    traceData.endpos = to
    traceData.filter = function(ent)
        count = count + 1
        ents[count] = ent
        debugoverlay.Text(ent:GetPos(), count, DEBUG_TIME)
        debugColor(ent, HSVToColor(count / 15 * 360, 1, 1))
        return false
    end

    traceLine()

    return ents
end

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
            local rand = math.Rand(0, modelArea)
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

function BLAST:findTargets()
    debugoverlay.Cross(self.pos, 5, DEBUG_TIME, COLOR_YELLOW, true)

    local bogies  = ents.FindInSphere(self.pos, self.radius)
    local targets = {}

    for _, ent in ipairs(bogies) do
        if self.lookupFilter[ent] then continue end
        if not ACF.Check(ent) then continue end

        local testPos = getRandomPos(ent)
        local tab     = targets

        debugoverlay.Cross(testPos, 5, DEBUG_TIME, COLOR_ORANGE, true)

        for _, ent in ipairs(entsAlongRay(self.pos, testPos)) do
            if self.lookupFilter[ent] then continue end
            if not ACF.Check(ent) then continue end

            tab[ent] = {}

            tab = tab[ent]
        end
    end

    self.targets = targets
    self.damage  = {}
end

function BLAST:calcDamage(ent)
    local distance   = ent:NearestPoint(self.pos):DistToSqr(self.pos)
    local feathering = (1 - distance / self.radius2) ^ 2

    return self.dmg * feathering, self.pen * feathering
end

function BLAST:damageTargets(targets, penOverride)
    for ent, occ in pairs(targets or self.targets) do
        local dmg, pen = self:calcDamage(ent)

        self.damage[ent] = math.max(self.damage[ent] or 0, dmg)

        if (penOverride or pen) > ent.ACF.Armour then
            print("Penetrated!", ent, ent:GetModel())
            --debugoverlay.Text(ent:GetPos(), "Penetrated!", DEBUG_TIME)
            --debugColor(ent, COLOR_RED)

            local reducePen = pen - ent.ACF.Armour

            self:damageTargets(occ, reducePen)
        else
            --debugColor(ent, COLOR_YELLOW)
        end
    end
end

function BLAST:applyDamage()
    for ent in pairs(self.damage) do

    end
end

function BLAST:playEffects()

end

function BLAST:detonate()
    traces = 0
    debugoverlay.Cross(self.pos, self.radius, 5, Color(255, 0, 0), true)
    debugoverlay.Sphere(self.pos, self.radius, 5, Color(255, 0, 0, 1), true)

    self:findTargets()

    print("Visible targets: " .. table.Count(self.targets))
    print("Traces fired: " .. traces)

    self:damageTargets()
    self:applyDamage()
    self:playEffects()
end