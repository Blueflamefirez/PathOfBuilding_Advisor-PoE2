-- Classes/AdvisorTab.lua
-- Advisor tab: ranks reachable passive nodes by actual DPS delta and suggests support gems.

local m_floor  = math.floor
local m_min    = math.min
local m_max    = math.max
local t_insert = table.insert
local t_sort   = table.sort
local s_format = string.format

local ICON_SZ    = 20   -- px: target-node icon square
local STONE_SZ   = 14   -- px: stepping-stone icon square
local LEAF_H     = 48   -- px: target-node row height
local STONE_H    = 24   -- px: stepping-stone expanded row height
local STONE_INDT = 14   -- px: left indent for stepping-stone rows

-- Draw a passive tree node icon using the tree's ddsMap atlas.
-- asset = tree:GetAssetByName(node.icon); falls back to a type-coloured square.
local function drawNodeIcon(node, asset, x, y, size)
	if asset and asset.found and asset.handle then
		SetDrawColor(1, 1, 1)
		if asset[1] then
			DrawImage(asset.handle, x, y, size, size, asset[1])
		else
			DrawImage(asset.handle, x, y, size, size)
		end
		return
	end
	-- Fallback: coloured square by node type
	if node.isKeystone then
		SetDrawColor(1.0, 0.82, 0.20, 0.95)
	elseif node.isNotable then
		SetDrawColor(0.50, 0.75, 1.00, 0.90)
	else
		SetDrawColor(0.65, 0.65, 0.70, 0.85)
	end
	DrawImage(nil, x, y, size, size)
	SetDrawColor(1, 1, 1)
end

-- Draw a stepping-stone icon using the atlas; falls back to a coloured square.
local function drawStoneIcon(stone, asset, x, y, size)
	if asset and asset.found and asset.handle then
		SetDrawColor(1, 1, 1)
		if asset[1] then
			DrawImage(asset.handle, x, y, size, size, asset[1])
		else
			DrawImage(asset.handle, x, y, size, size)
		end
		return
	end
	if stone.type == "Socket" then
		SetDrawColor(0.52, 0.22, 0.82, 0.90)
	else
		SetDrawColor(0.25, 0.62, 0.35, 0.90)
	end
	DrawImage(nil, x, y, size, size)
	SetDrawColor(1, 1, 1)
end

local AdvisorTabClass = newClass("AdvisorTab", function(self, build)
	self.build           = build
	self.outputRevision  = -1
	self.nodeList        = {}
	self.mainSkillInfo   = nil
	self.gemSuggestions  = {}
	self.scrollY         = 0
	self.totalContentH   = 0
	self.expandedEntries = {}   -- nodeId → bool; survives redraws
	self.clickableRows   = {}   -- [{x,y,w,h,nodeId}]; rebuilt each Draw
end)

function AdvisorTabClass:RebuildCache()
	local build = self.build
	if build.outputRevision == self.outputRevision then return end
	self.outputRevision = build.outputRevision
	self:_rebuildNodes()
	self:_rebuildSkills()
end

local function constraintsMet(node, specNodes)
	if not node.unlockConstraint then return true end
	for _, reqId in ipairs(node.unlockConstraint.nodes) do
		local req = specNodes[reqId]
		if req and not req.alloc then return false end
	end
	return true
end

local function isSteppingStone(node)
	return node.type == "Socket" or node.isAttribute == true
end

local function isSkippable(node)
	return node.ascendancyName
	    or node.type == "ClassStart"
	    or node.type == "AscendClassStart"
	    or node.type == "Mastery"
	    or node.isBlighted
end

-- BFS from allocated nodes, following stepping-stone chains up to MAX_DEPTH hops.
-- Scores every reachable notable/keystone with a real delta-calc call.
-- Score is normalised per point so a 3-pt +6 % = a 1-pt +2 %.
function AdvisorTabClass:_rebuildNodes()
	local build     = self.build
	local spec      = build.spec
	local calcFunc, calcBase = build.calcsTab:GetMiscCalculator()
	if not calcFunc or not calcBase then
		self.nodeList        = {}
		build.advisorNodeIds = {}
		build.advisorViaIds  = {}
		return
	end

	local MAX_DEPTH = 4
	local scored    = {}
	local visited   = {}
	local queue     = {}
	local qi        = 1

	-- Seed with every unallocated node adjacent to an allocated node.
	for _, node in pairs(spec.nodes) do
		if node.alloc then
			for _, ln in ipairs(node.linked or {}) do
				if not ln.alloc and not visited[ln.id] then
					visited[ln.id] = true
					t_insert(queue, { node = ln, path = {} })
				end
			end
		end
	end

	while qi <= #queue do
		local e    = queue[qi]; qi = qi + 1
		local node = e.node
		local path = e.path

		if isSkippable(node) then
			-- nothing

		elseif isSteppingStone(node) and #path < MAX_DEPTH then
			local newPath = {}
			for _, s in ipairs(path) do newPath[#newPath + 1] = s end
			newPath[#newPath + 1] = node
			for _, ln in ipairs(node.linked or {}) do
				if not ln.alloc and not visited[ln.id] then
					visited[ln.id] = true
					t_insert(queue, { node = ln, path = newPath })
				end
			end

		elseif (node.modKey or "") ~= "" and not isSteppingStone(node)
		       and constraintsMet(node, spec.nodes) then
			local addNodes = { [node] = true }
			for _, s in ipairs(path) do addNodes[s] = true end
			local ok, output = pcall(calcFunc, { addNodes = addNodes })
			if ok and output then
				local off, def = build.calcsTab:CalculateCombinedOffDefStat(output, calcBase)
				off = off or 0; def = def or 0
				local chainLen = #path + 1
				t_insert(scored, {
					node     = node,
					nodeId   = node.id,
					path     = path,
					score    = (off + def * 0.3) / chainLen,
					offence  = off,
					defence  = def,
					chainLen = chainLen,
				})
			end
		end
	end

	t_sort(scored, function(a, b) return a.score > b.score end)

	self.nodeList = {}
	for i = 1, m_min(10, #scored) do
		scored[i].rank   = i
		self.nodeList[i] = scored[i]
	end

	build.advisorNodeIds = {}
	build.advisorViaIds  = {}
	for i, entry in ipairs(self.nodeList) do
		build.advisorNodeIds[entry.nodeId] = i
		for _, stone in ipairs(entry.path) do
			if not build.advisorNodeIds[stone.id] then
				build.advisorViaIds[stone.id] = true
			end
		end
	end
end

function AdvisorTabClass:_rebuildSkills()
	local build = self.build
	self.mainSkillInfo  = nil
	self.gemSuggestions = {}

	local mainEnv = build.calcsTab and build.calcsTab.mainEnv
	if not mainEnv then return end

	local flags     = {}
	local mainSkill = mainEnv.player and mainEnv.player.mainSkill
	if mainSkill and mainSkill.activeEffect and mainSkill.activeEffect.statSet then
		flags = mainSkill.activeEffect.statSet.skillFlags or {}
	end

	local mainGroup = build.skillsTab.socketGroupList[build.mainSocketGroup]
	if not mainGroup then return end

	local mainGemIdx = mainGroup.mainActiveSkill or 1
	local mainGem    = mainGroup.gemList and mainGroup.gemList[mainGemIdx]
	local mainDPS    = build.calcsTab.mainOutput and build.calcsTab.mainOutput.TotalDPS or 0

	self.mainSkillInfo = {
		name  = mainGem and mainGem.nameSpec or "Unknown",
		dps   = mainDPS,
		group = mainGroup,
	}

	local usedSupports = {}
	if mainGroup.gemList then
		for _, gem in ipairs(mainGroup.gemList) do
			local isSupport = gem.gemData and gem.gemData.tags and gem.gemData.tags.support
			if isSupport then usedSupports[(gem.nameSpec or ""):lower()] = true end
		end
	end

	local weights = { ["damage"] = 1, ["penetration"] = 2, ["critical"] = 1, ["faster"] = 1 }
	if flags["isFire"]       then weights["fire"]       = 3 end
	if flags["isCold"]       then weights["cold"]       = 3 end
	if flags["isLightning"]  then weights["lightning"]  = 3 end
	if flags["isChaos"]      then weights["chaos"]      = 3 end
	if flags["isPhysical"]   then weights["physical"]   = 3 end
	if flags["isSpell"]      then weights["spell"]      = 2 end
	if flags["isAttack"]     then weights["attack"]     = 2 end
	if flags["isProjectile"] then weights["projectile"] = 2 end

	local suggestions = {}
	if build.data and build.data.gems then
		for _, gemData in pairs(build.data.gems) do
			if gemData.tags and gemData.tags.support then
				local gemName = (gemData.name or ""):lower()
				if not usedSupports[gemName] then
					local haystack = gemName .. " " .. (gemData.tagString or ""):lower()
					local score    = 0
					for kw, wt in pairs(weights) do
						if haystack:find(kw, 1, true) then score = score + wt end
					end
					if score > 0 then t_insert(suggestions, { name = gemData.name, score = score }) end
				end
			end
		end
	end

	t_sort(suggestions, function(a, b) return a.score > b.score end)
	for i = 1, m_min(6, #suggestions) do self.gemSuggestions[i] = suggestions[i] end
end

-- Draw one target-node row plus its (possibly expanded) stepping-stone chain.
-- Registers a hit area in self.clickableRows for rows that have hops.
-- Returns the updated lY.
function AdvisorTabClass:_drawEntry(entry, lx, lY, colW)
	local node     = entry.node
	local hasHops  = #entry.path > 0
	local hopCount = #entry.path
	local expanded = hasHops and self.expandedEntries[entry.nodeId]

	-- ── Target-node row ──────────────────────────────────────────────────────

	-- Alternating background
	if entry.rank % 2 == 0 then
		SetDrawColor(0.11, 0.11, 0.13)
		DrawImage(nil, lx, lY - 2, colW, LEAF_H)
	end

	-- Subtle tint on expandable rows to hint at interactivity
	if hasHops then
		SetDrawColor(0.18, 0.22, 0.30, 0.18)
		DrawImage(nil, lx, lY - 2, colW, LEAF_H)
		t_insert(self.clickableRows, { x = lx, y = lY - 2, w = colW, h = LEAF_H, nodeId = entry.nodeId })
	end

	-- Expand/collapse indicator: + (collapsed) or - (expanded) for hop rows
	local IND_W = 16
	if hasHops then
		if expanded then
			SetDrawColor(0.55, 0.65, 1.0)
			DrawString(lx + 2, lY + m_floor((LEAF_H - 14) / 2), "LEFT", 14, "VAR BOLD", "-")
		else
			SetDrawColor(0.40, 0.88, 0.55)
			DrawString(lx + 2, lY + m_floor((LEAF_H - 14) / 2), "LEFT", 14, "VAR BOLD", "+")
		end
	end

	-- Rank badge
	local RANK_W = 32
	local cx = lx + IND_W
	if entry.rank == 1 then
		SetDrawColor(0.30, 0.80, 1.0)
	else
		SetDrawColor(0.50, 0.50, 0.60)
	end
	DrawString(cx, lY + 5, "LEFT", 13, "VAR BOLD", "#" .. entry.rank)

	-- Icon vertically centred, immediately before the node name
	local iconX  = cx + RANK_W
	local iconY  = lY + m_floor((LEAF_H - ICON_SZ) / 2)
	local tree   = self.build.spec and self.build.spec.tree
	local asset  = tree and node.icon and tree:GetAssetByName(node.icon)
	drawNodeIcon(node, asset, iconX, iconY, ICON_SZ)

	-- Node name (line 1)
	local nameX = iconX + ICON_SZ + 4
	if node.isKeystone then
		SetDrawColor(1.0, 0.85, 0.30)
	elseif node.isNotable then
		SetDrawColor(0.80, 0.90, 1.0)
	else
		SetDrawColor(1, 1, 1)
	end
	DrawString(nameX, lY + 2, "LEFT", 15, "VAR BOLD", node.dn or node.name or "Unknown")

	-- Badge + invest + stat (line 2)
	local badge      = node.isKeystone and "Keystone" or node.isNotable and "Notable" or "Node"
	local investStr  = entry.chainLen .. "pt invest"
	SetDrawColor(0.45, 0.45, 0.50)
	DrawString(nameX, lY + 20, "LEFT", 11, "VAR", badge)
	SetDrawColor(0.38, 0.38, 0.48)
	DrawString(nameX + 62, lY + 20, "LEFT", 11, "VAR", investStr)

	if node.sd and node.sd[1] then
		local avail    = colW - (nameX - lx) - 210
		local maxChars = m_max(6, m_floor(avail / 6))
		local sdText   = node.sd[1]
		if #sdText > maxChars then sdText = sdText:sub(1, maxChars - 3) .. "..." end
		SetDrawColor(0.58, 0.58, 0.60)
		DrawString(nameX + 122, lY + 20, "LEFT", 11, "VAR", sdText)
	end

	-- Hop expand/collapse toggle (line 2, right of centre)
	if hasHops then
		local label = expanded
			and ("[-" .. hopCount .. (hopCount == 1 and " hop]" or " hops]"))
			or  ("[+" .. hopCount .. (hopCount == 1 and " hop]" or " hops]"))
		SetDrawColor(0.50, 0.62, 0.88)
		DrawString(lx + colW - 108, lY + 20, "LEFT", 11, "VAR", label)
	end

	-- DPS delta (right-aligned, line 1)
	local offPct = entry.offence * 100
	if offPct >= 0.05 then
		SetDrawColor(0.30, 1.0, 0.40)
		DrawString(lx + colW - 4, lY + 2, "RIGHT", 13, "VAR", s_format("+%.2f%% DPS", offPct))
	elseif offPct <= -0.05 then
		SetDrawColor(1.0, 0.40, 0.30)
		DrawString(lx + colW - 4, lY + 2, "RIGHT", 13, "VAR", s_format("%.2f%% DPS", offPct))
	else
		SetDrawColor(0.50, 0.50, 0.50)
		DrawString(lx + colW - 4, lY + 2, "RIGHT", 13, "VAR", "~0% DPS")
	end

	-- Def delta (right-aligned, line 2)
	local defPct = entry.defence * 100
	if defPct >= 0.01 then
		SetDrawColor(0.40, 0.70, 1.0)
		DrawString(lx + colW - 4, lY + 20, "RIGHT", 11, "VAR", s_format("+%.2f%% Def", defPct))
	end

	lY = lY + LEAF_H

	-- ── Stepping-stone rows (only when expanded) ─────────────────────────────

	if expanded then
		for si, stone in ipairs(entry.path) do
			local isLast = si == #entry.path

			-- Row background
			SetDrawColor(0.08, 0.09, 0.12)
			DrawImage(nil, lx, lY, colW, STONE_H)

			-- Vertical spine connecting stones
			if not isLast then
				SetDrawColor(0.28, 0.40, 0.68, 0.50)
				DrawImage(nil, lx + STONE_INDT + m_floor(STONE_SZ / 2), lY + m_floor(STONE_H / 2), 1, m_floor(STONE_H / 2))
			end

			-- Horizontal connector tick
			SetDrawColor(0.28, 0.40, 0.68, 0.50)
			DrawImage(nil, lx + STONE_INDT + m_floor(STONE_SZ / 2), lY + m_floor(STONE_H / 2), STONE_INDT - 2, 1)

			-- Stone icon
			local stoneIconY    = lY + m_floor((STONE_H - STONE_SZ) / 2)
			local stoneAsset    = tree and stone.icon and tree:GetAssetByName(stone.icon)
			drawStoneIcon(stone, stoneAsset, lx + STONE_INDT, stoneIconY, STONE_SZ)

			-- Arrow + type badge
			local arrowX = lx + STONE_INDT + STONE_SZ + 6
			SetDrawColor(0.38, 0.42, 0.52)
			DrawString(arrowX, lY + 5, "LEFT", 11, "VAR", "->")

			local isSocket = stone.type == "Socket"
			if isSocket then
				SetDrawColor(0.55, 0.26, 0.85)
			else
				SetDrawColor(0.26, 0.65, 0.36)
			end
			local badgeX = arrowX + 22
			DrawString(badgeX, lY + 4, "LEFT", 10, "VAR BOLD", isSocket and "SOCKET" or "ATTR")

			-- Stone name
			local stoneNameX = badgeX + 52
			SetDrawColor(0.62, 0.65, 0.75)
			DrawString(stoneNameX, lY + 4, "LEFT", 12, "VAR BOLD", stone.dn or stone.name or "Node")

			-- Stone first stat
			if stone.sd and stone.sd[1] then
				local avail    = colW - (stoneNameX - lx) - 80
				local maxChars = m_max(6, m_floor(avail / 6))
				local sdText   = stone.sd[1]
				if #sdText > maxChars then sdText = sdText:sub(1, maxChars - 3) .. "..." end
				SetDrawColor(0.42, 0.45, 0.54)
				DrawString(stoneNameX + 130, lY + 5, "LEFT", 11, "VAR", sdText)
			end

			-- Cumulative cost (right-aligned)
			SetDrawColor(0.38, 0.40, 0.50)
			DrawString(lx + colW - 4, lY + 6, "RIGHT", 10, "VAR", si .. "pt to here")

			lY = lY + STONE_H
		end

		-- Small gap after the chain
		lY = lY + 4
	end

	return lY
end

function AdvisorTabClass:Draw(viewPort, inputEvents)
	local vx, vy, vw, vh = viewPort.x, viewPort.y, viewPort.width, viewPort.height

	-- ── Step 1: process scroll input ─────────────────────────────────────────
	for _, event in ipairs(inputEvents) do
		if event.type == "KeyDown" then
			if event.key == "WHEELUP" then
				self.scrollY = m_max(0, self.scrollY - 30)
			elseif event.key == "WHEELDOWN" then
				local maxScroll = m_max(0, self.totalContentH - vh + 20)
				self.scrollY    = m_min(maxScroll, self.scrollY + 30)
			end
		end
	end

	-- ── Step 2: reset hit areas (rebuilt during draw below) ──────────────────
	self.clickableRows = {}

	-- ── Step 3: draw ─────────────────────────────────────────────────────────
	SetDrawLayer(nil, 1)
	SetDrawColor(0.08, 0.08, 0.08)
	DrawImage(nil, vx, vy, vw, vh)

	local PAD    = 12
	local GAP    = 16
	local colW   = m_floor((vw - PAD * 2 - GAP) / 2)
	local lx     = vx + PAD
	local rx     = vx + PAD + colW + GAP
	local scroll = self.scrollY

	SetDrawLayer(nil, 5)

	-- Left column ─────────────────────────────────────────────────────────────
	local lY = vy + PAD - scroll

	SetDrawColor(0.40, 0.75, 1.0)
	DrawString(lx, lY, "LEFT", 18, "VAR BOLD", "Passive Node Suggestions")
	lY = lY + 24
	SetDrawColor(0.40, 0.75, 1.0, 0.5)
	DrawImage(nil, lx, lY, colW, 1)
	lY = lY + 8

	if #self.nodeList == 0 then
		SetDrawColor(0.50, 0.50, 0.50)
		DrawString(lx, lY, "LEFT", 14, "VAR", "Allocate some passives to see suggestions.")
		lY = lY + 22
	else
		for _, entry in ipairs(self.nodeList) do
			lY = self:_drawEntry(entry, lx, lY, colW)
		end
	end

	-- Right column ────────────────────────────────────────────────────────────
	local rY = vy + PAD - scroll

	SetDrawColor(0.40, 1.0, 0.55)
	DrawString(rx, rY, "LEFT", 18, "VAR BOLD", "Skills & Gem Suggestions")
	rY = rY + 24
	SetDrawColor(0.40, 1.0, 0.55, 0.5)
	DrawImage(nil, rx, rY, colW, 1)
	rY = rY + 8

	if self.mainSkillInfo then
		local info = self.mainSkillInfo
		SetDrawColor(0.85, 0.85, 0.85)
		DrawString(rx, rY, "LEFT", 14, "VAR BOLD", "Main Skill")
		rY = rY + 18
		SetDrawColor(1, 1, 1)
		DrawString(rx + 8, rY, "LEFT", 13, "VAR", info.name)
		rY = rY + 16
		if info.dps > 0 then
			SetDrawColor(0.70, 0.70, 0.70)
			DrawString(rx + 8, rY, "LEFT", 12, "VAR", "DPS: " .. s_format("%.1f", info.dps))
			rY = rY + 16
		end
		local group       = info.group
		local hasSupports = false
		if group and group.gemList then
			for _, gem in ipairs(group.gemList) do
				local isSupport = gem.gemData and gem.gemData.tags and gem.gemData.tags.support
				if isSupport and gem.enabled ~= false then
					if not hasSupports then
						SetDrawColor(0.70, 0.70, 0.70)
						DrawString(rx + 8, rY, "LEFT", 12, "VAR", "Active supports:")
						rY = rY + 15
						hasSupports = true
					end
					SetDrawColor(0.55, 0.65, 0.95)
					DrawString(rx + 16, rY, "LEFT", 12, "VAR", "- " .. (gem.nameSpec or "Unknown"))
					rY = rY + 15
				end
			end
		end
		if not hasSupports then
			SetDrawColor(0.50, 0.50, 0.50)
			DrawString(rx + 8, rY, "LEFT", 12, "VAR", "No support gems in main group.")
			rY = rY + 16
		end
		rY = rY + 10
	else
		SetDrawColor(0.50, 0.50, 0.50)
		DrawString(rx, rY, "LEFT", 13, "VAR", "Set a main skill to see suggestions.")
		rY = rY + 20
	end

	SetDrawColor(0.85, 0.85, 0.85)
	DrawString(rx, rY, "LEFT", 14, "VAR BOLD", "Suggested Supports")
	rY = rY + 18
	SetDrawColor(0.40, 1.0, 0.55, 0.40)
	DrawImage(nil, rx, rY, colW, 1)
	rY = rY + 6

	if #self.gemSuggestions == 0 then
		SetDrawColor(0.50, 0.50, 0.50)
		DrawString(rx, rY, "LEFT", 13, "VAR", "No suggestions — set a main skill first.")
		rY = rY + 20
	else
		for i, sug in ipairs(self.gemSuggestions) do
			if i % 2 == 0 then
				SetDrawColor(0.11, 0.11, 0.13)
				DrawImage(nil, rx, rY - 2, colW, 20)
			end
			SetDrawColor(0.35, 0.90, 0.45)
			DrawString(rx, rY, "LEFT", 13, "VAR", "+ " .. (sug.name or ""))
			rY = rY + 19
		end
	end

	rY = rY + 16
	SetDrawColor(0.30, 0.30, 0.35)
	DrawString(rx, rY, "LEFT", 11, "VAR", "Active skill analysis — coming in a future update.")
	rY = rY + 20

	-- ── Step 4: process click events against this frame's hit areas ───────────
	-- PoB2 LEFTBUTTON events carry no x/y; use GetCursorPos() for position.
	for _, event in ipairs(inputEvents) do
		if event.type == "KeyDown" and event.key == "LEFTBUTTON" then
			local mx, my = GetCursorPos()
			if mx and my then
				for _, row in ipairs(self.clickableRows) do
					if mx >= row.x and mx <= row.x + row.w
					and my >= row.y and my <= row.y + row.h then
						self.expandedEntries[row.nodeId] = not self.expandedEntries[row.nodeId]
						break
					end
				end
			end
		end
	end

	-- ── Step 5: update scroll bounds ─────────────────────────────────────────
	self.totalContentH = m_max(lY, rY) - vy + scroll
end
