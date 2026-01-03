--[[
Server-side sandbox building controller.
Handler for:
- Building placement and validation
- Conveyor placement and auto-connection
- Material consumption and refunds (delete)
- Save/load orchestration
]]

-- Module used to ensure builds do not overlap or exceed plot boundary
local buildValidator = require(game.ServerScriptService:WaitForChild("ServerBuildValidator"))

-- Module used for player's material checking
local hasMaterial = require(game.ReplicatedStorage:WaitForChild("HasMaterial"))

local remotes = game.ReplicatedStorage:FindFirstChild("Remotes")

-- Server-Client remotes
local placeBuildRemote = remotes:FindFirstChild("PlaceBuild")
local placeConveyorRemote = remotes:FindFirstChild("PlaceConveyor")
local saveRecipeRemote = remotes:FindFirstChild("SaveRecipe")
local deleteBuildRemote = remotes:FindFirstChild("DeleteBuild")
local popupRemote = remotes:FindFirstChild("Popup")

-- Server-Server remotes
local serverStorageRemotes = game.ServerStorage:FindFirstChild("Remotes")

local loadBuildRemote = serverStorageRemotes:FindFirstChild("LoadBuild")
local loadConveyorRemote = serverStorageRemotes:FindFirstChild("LoadConveyor")

-- Folders
local buildLibFold = game.ReplicatedStorage:FindFirstChild("BuildLib")
local buildingFold = game.ReplicatedStorage:FindFirstChild("Buildings")
local itemsFold = game.ReplicatedStorage:FindFirstChild("Items")

local bin = workspace:FindFirstChild("server")

-- Default conveyor for directly connected conveyors
local normalConveyor = buildingFold:FindFirstChild("Conveyor Mk. 1")
local normalConveyorBuilder = require(normalConveyor:FindFirstChild("Builder"))
local normalConveyorInit = normalConveyor:FindFirstChild("Module")

local directConvTolerance = game.ReplicatedStorage:FindFirstChild("DirectConvTolerance").Value

local buildToMats = {}

--[[
Gets all unoccupied input and output nodes from a plot,
used for checking adjacent nodes.
Nodes that has "Occupied" is skipped
]]
local function getInputOutputNodes(plotBuildingsFold)
	local nodes = {
		["Input"] = {},
		["Output"] = {}
	}

	for i, build in pairs(plotBuildingsFold:GetChildren()) do
		if build:FindFirstChild("Node") then
			for i, node in pairs(build:FindFirstChild("Node"):GetChildren()) do
				if node:FindFirstChild("Occupied").Value ~= nil then continue end

				local typ = string.split(node.Name, "_")[1] -- Node name format is "Input_*" or "Output_*"
				table.insert(nodes[typ], node)
			end
		end
	end

	return nodes
end

--[[
Creates conveyor with given input and output nodes.
If nodes are close enough, construct direct conveyor instead.
Returns the module (to initialize the conveyor), item slot fold and item slot amount (depending on length)
]]
local function buildConveyor(module, outputNode, inputNode, parent, initModule)
	local model, cost, slotFold, slotAmt = module.build(outputNode.CFrame, inputNode.CFrame)
	model.Parent = parent
	
	outputNode:FindFirstChild("Occupied").Value = model
	inputNode:FindFirstChild("Occupied").Value = model
	
	local convInput = Instance.new("ObjectValue")
	convInput.Parent = model
	convInput.Name = "Input"
	convInput.Value = outputNode
	
	local convOutput = Instance.new("ObjectValue")
	convOutput.Parent = model
	convOutput.Name = "Output"
	convOutput.Value = inputNode
	
	local module = initModule:Clone()
	module.Parent = model
	
	local isConveyor = Instance.new("BoolValue")
	isConveyor.Parent = model
	isConveyor.Name = "IsConveyor"
	
	if (outputNode.Position - inputNode.Position).Magnitude <= directConvTolerance then -- Direct conveyor checks
		local isDirectConv = Instance.new("BoolValue")
		isDirectConv.Name = "IsDirectConv"
		isDirectConv.Parent = model
	end
	
	return module, slotFold, slotAmt
end

local oppositeTab = {
	["Input"] = "Output",
	["Output"] = "Input"
}

--[[
Scans for nearby opposite nodes. If there is one directly in front, connects them with direct conveyor.
]]
local function checkAdjacentNodes(nodesFold, parent)
	local module = nodesFold.Parent:FindFirstChild("Module")
	local nodes = getInputOutputNodes(parent)
	
	local convModules = {}
	
	for i, node in pairs(nodesFold:GetChildren()) do
		local typ = string.split(node.Name, "_")[1]
		local pos = node.Position

		for i, targetNode in pairs(nodes[oppositeTab[typ]]) do -- Looks for in opposite node type
			local dist = (pos - targetNode.Position).Magnitude
			if dist <= directConvTolerance then
				local targetModule = targetNode.Parent.Parent:FindFirstChild("Module")

				local inputNode, outputNode
				if typ == "Input" then
					inputNode = node
					outputNode = targetNode
				else
					inputNode = targetNode
					outputNode = node
				end
				
				local convModule = buildConveyor(normalConveyorBuilder, outputNode, inputNode, parent, normalConveyorInit)
				table.insert(convModules, convModule) -- Module will be run for initialization later on
				break -- Stops after finding match
			end
		end
	end
	
	return convModules
end

--[[
Clones and position building in player plot, returns the model
]]
local function placeBuild(buildModel, plotBuildingsFold, xPos, zPos, rot)
	local model = buildModel:Clone()
	model.Parent = plotBuildingsFold
	
	local yPos = 2 + model.PrimaryPart.Size.Y/2

	model:PivotTo(CFrame.new(xPos, yPos, zPos) * CFrame.Angles(0, math.rad(rot), 0))
	
	if model:FindFirstChild("TempWeld") then -- Unwelds animation parts (fans, drills, etc)
		delay(1, function()
			for i, weldVal in pairs(model:FindFirstChild("TempWeld"):GetChildren()) do
				weldVal.Value.Parent.Anchored = true
				weldVal.Value:Destroy()
			end
		end)
	end
	
	return model
end

--[[
Serial is different for each building,
used for saving / loading conveyors. 

Ex:
Furnace_1 output -> Conveyor -> Furnace_2 input, not the other way
]]
local function getSerial(serialFold)
	local i = 0
	repeat
		i += 1
	until serialFold:FindFirstChild(i) == nil
	return i
end

--[[
Handles player building placement request
Checks:
- Valid building?
- Has research for it?
- Check collision?
- Check boundary?
- Has materials?

Also constructs a direct conveyor if the building node is adjacent to other node
]]
placeBuildRemote.OnServerInvoke = function(plr, val, xPos, zPos, rot)
	if not (val:IsA("BoolValue") and val:IsDescendantOf(buildLibFold)) then return false end

	local researchReq = val:GetAttribute("ResearchReq")
	local plrResearchFold = plr:FindFirstChild("Research")

	if not ((researchReq == "") or (plrResearchFold:FindFirstChild(researchReq))) then return end

	local buildModel = buildingFold:FindFirstChild(val.Name)
	local buildPrimSample = buildModel.PrimaryPart:Clone() -- Sample to check collision / boundary
	local yPos = 2 + buildPrimSample.Size.Y/2

	buildPrimSample.Parent = bin	
	buildPrimSample.CFrame = CFrame.new(xPos, yPos, zPos) * CFrame.Angles(0, math.rad(rot), 0)

	if not buildValidator.checkCollision(plr, buildPrimSample) then 
		buildPrimSample:Destroy()
		return false
	end
	if not buildValidator.checkBoundary(plr, buildPrimSample) then 
		buildPrimSample:Destroy()
		return false
	end

	buildPrimSample:Destroy()

	if not hasMaterial.check(plr, hasMaterial.valToTab(val)) then return false end

	local plrItems = plr:FindFirstChild("Items")
	for i, mat in pairs(val:FindFirstChild("Materials"):GetChildren()) do
		local plrVal = plrItems:FindFirstChild(mat.Name)
		plrVal.Value -= mat.Value
	end
	
	local plot = plr:FindFirstChild("Plot").Value
	local plotBuildingsFold = plot:FindFirstChild("Buildings")

	local model = placeBuild(buildModel, plotBuildingsFold, xPos, zPos, rot)
	
	local serial = getSerial(plot:FindFirstChild("Serials"))
	
	local serialVal = Instance.new("BoolValue") -- Serial used for saving / loading conveyor purposes
	serialVal.Name = serial
	serialVal.Parent = plot:FindFirstChild("Serials")
	
	model.Name = model.Name .. "_" .. serial
	
	local conveyorModules -- Direct conveyor modules, exists if there is adjacent opposite nodes
	if model:FindFirstChild("Node") then
		conveyorModules = checkAdjacentNodes(model:FindFirstChild("Node"), plotBuildingsFold)
	end

	local module = model:FindFirstChild("Module") -- Module used for initialization
	return module, conveyorModules
end

loadBuildRemote.OnInvoke = placeBuild

--[[
Handles player conveyor placement request
Checks:
- Valid building?
- Both input and output is not occupied?
- Check collision?
- Check boundary?
- Has materials?
]]
placeConveyorRemote.OnServerInvoke = function(plr, val, outputNode, inputNode)
	if not (val:IsA("BoolValue") and val:IsDescendantOf(buildLibFold)) then return false end
	if outputNode:FindFirstChild("Occupied").Value ~= nil then return false end
	if inputNode:FindFirstChild("Occupied").Value ~= nil then return false end
	
	local buildModel = buildingFold:FindFirstChild(val.Name)
	local module = require(buildModel:FindFirstChild("Builder"))
	
	local hitboxModel, cost = module.build(outputNode.CFrame, inputNode.CFrame, true) -- Gets only the hitbox model and cost (no visual parts)
	local except = {outputNode.Parent.Parent.PrimaryPart, inputNode.Parent.Parent.PrimaryPart} -- Doesnt check for building of the nodes
	hitboxModel.Parent = bin
	
	for i, hitbox in (hitboxModel:GetChildren()) do
		if not buildValidator.checkCollisionWithException(plr, hitbox, except) then
			hitboxModel:Destroy()
			return false
		end
	end
	
	hitboxModel:Destroy()
	
	if not hasMaterial.check(plr, cost) then return false end
	
	local plrItems = plr:FindFirstChild("Items")
	for matName, matAmt in pairs(cost) do
		local plrVal = plrItems:FindFirstChild(matName)
		plrVal.Value -= matAmt
	end
	
	local plot = plr:FindFirstChild("Plot").Value
	local plotBuildingsFold = plot:FindFirstChild("Buildings")
	
	local module, slotFold, slotAmt = buildConveyor(module, outputNode, inputNode, plotBuildingsFold, buildModel:FindFirstChild("Module"))
	return module, slotFold, slotAmt
end

loadConveyorRemote.OnInvoke = buildConveyor

--[[
Handles player recipe change request
Recipe (the item crafted) is for crafter building only
]]
saveRecipeRemote.OnServerEvent:Connect(function(plr, build, value)
	if not build:FindFirstChild("Recipe") then return end
	build:FindFirstChild("Recipe").Value = value
end)

local function refundMats(plr, mats)
	local plrInventory = plr:FindFirstChild("Items")
	for matName, matVal in pairs(mats) do
		if not plrInventory:FindFirstChild(matName) then
			local val = Instance.new("IntValue")
			val.Name = matName
			val.Value = matVal
			val.Parent = plrInventory
		else
			plrInventory:FindFirstChild(matName).Value += matVal
		end
		
		popupRemote:FireClient(plr, "+" .. matVal .. " " .. matName, itemsFold:FindFirstChild(matName):GetAttribute("Icon"))
	end
end

--[[
Deletes building or conveyor of plot.
Also refunds materials
]]
local function deleteBuild(plr, build)
	local plot = plr:FindFirstChild("Plot").Value
	local plotBuildingsFold = plot:FindFirstChild("Buildings")

	if not build:IsDescendantOf(plotBuildingsFold) then return end

	if not build:FindFirstChild("IsConveyor") then -- Handles building
		local nodeFold = build:FindFirstChild("Node")
		if nodeFold then
			for i, node in pairs(nodeFold:GetChildren()) do
				local conv = node:FindFirstChild("Occupied").Value
				if conv and conv:FindFirstChild("IsDirectConv") == nil then -- Prevents deletion if conveyor is still atached (not direct coneyor)
					return false
				end
			end
		end

		local mats = buildToMats[string.split(build.Name, "_")[1]]

		if nodeFold then
			for i, node in pairs(nodeFold:GetChildren()) do
				local conv = node:FindFirstChild("Occupied").Value
				if conv then
					deleteBuild(plr, conv)
				end
			end
		end

		build:Destroy()
		refundMats(plr, mats)
		
	else -- Handles conveyor
		local inputNode = build:FindFirstChild("Input").Value
		inputNode.Occupied.Value = nil

		local outputNode = build:FindFirstChild("Output").Value
		outputNode.Occupied.Value = nil

		local convModule = require(buildingFold:FindFirstChild(build.Name):FindFirstChild("Builder"))
		local mats = convModule.getCost(build:FindFirstChild("Length").Value) -- Get the original cost

		build:Destroy()
		refundMats(plr, mats)
	end
end

deleteBuildRemote.OnServerEvent:Connect(deleteBuild)

--[[
Cache build materials at startup
]]
for i, category in pairs(buildLibFold:GetChildren()) do
	for i, buildVal in pairs(category:GetChildren()) do
		if buildVal:FindFirstChild("IsConveyor") then continue end
		local mats = {}
		for i, matVal in pairs(buildVal:FindFirstChild("Materials"):GetChildren()) do
			mats[matVal.Name] = matVal.Value
		end
		buildToMats[buildVal.Name] = mats
	end
end
