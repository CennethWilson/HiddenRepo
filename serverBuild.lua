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
local plotHeight = 2

local Conveyor = {}
Conveyor.__index = Conveyor

function Conveyor.new(model: Model, inputNode: BasePart, outputNode: BasePart)
	return setmetatable({
		Model = model,
		InputNode = inputNode,
		OutputNode = outputNode,
	}, Conveyor)
end


function Conveyor.FromModel(model: Model)
	return Conveyor.new(
		model,
		model:WaitForChild("Input").Value,
		model:WaitForChild("Output").Value
	)
end

function Conveyor:GetModule()
	return self.Model:FindFirstChild("Module")
end

function Conveyor:Disconnect()
	if self.InputNode then
		self.InputNode.Occupied.Value = nil
	end
	if self.OutputNode then
		self.OutputNode.Occupied.Value = nil
	end
end

function Conveyor:Destroy()
	self:Disconnect()
	self.Model:Destroy()
end

--[[
During building placement, the script create "direct conveyors"
to reduce manual player setup when two compatible nodes are in front of each other.

This function:
- Runs only once, immediately after a building is placed
- Searches for *unoccupied* opposite node types (Input to Output, vice versa)
- Stops after the first valid match to prevent duplicate conveyors
- Returns conveyor objects instead of initializing them immediately so 
the caller can batch-initialize modules after placement completes

This avoids partially initialized conveyor states if placement fails.
]]

local function getInputOutputNodes(plotBuildingsFold : Folder)
	local nodes = {
		["Input"] = {},
		["Output"] = {}
	}

	for _, build in ipairs(plotBuildingsFold:GetChildren()) do
		if build:FindFirstChild("Node") then
			for _, node in ipairs(build:FindFirstChild("Node"):GetChildren()) do
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
local function buildConveyor(
	module, 
	outputNode : BasePart, 
	inputNode : BasePart,
	parent : Folder, 
	initModule : ModuleScript
)
	local model, cost, slotFold, slotAmt = module.build(
		outputNode.CFrame, 
		inputNode.CFrame
	)
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
	
	initModule:Clone().Parent = model
	
	Instance.new("BoolValue", model).Name = "IsConveyor"
	
	if (outputNode.Position - inputNode.Position).Magnitude <= directConvTolerance then -- Direct conveyor checks
		Instance.new("BoolValue", model).Name = "IsDirectConv"
	end
	
	local conveyorObject = Conveyor.new(model, inputNode, outputNode)
	return conveyorObject, slotFold, slotAmt
end

local oppositeTab = {Input = "Output", Output = "Input"}

--[[
Scans for nearby opposite nodes. If there is one directly in front, connects them with direct conveyor.
]]
local function checkAdjacentNodes(
	nodesFold : Folder, 
	parent : Folder
)
	local nodes = getInputOutputNodes(parent)
	
	local convObjects = {}
	
	for _, node in ipairs(nodesFold:GetChildren()) do
		local typ = string.split(node.Name, "_")[1]
		
		for _, targetNode in ipairs(nodes[oppositeTab[typ]]) do -- Looks for in opposite node type
			if (node.Position - targetNode.Position).Magnitude <= directConvTolerance then
				local inputNode = (typ == "Input") and node or targetNode
				local outputNode = (typ == "Output") and targetNode or node
				
				local convObj = buildConveyor(
					normalConveyorBuilder, 
					outputNode, 
					inputNode, 
					parent, 
					normalConveyorInit
				)
				
				table.insert(convObjects, convObj) -- Module will be run for initialization later on
				break -- Stops after finding match
			end
		end
	end
	
	return convObjects
end

--[[
Clones and position building in player plot, returns the model
]]
local function placeBuild(
	buildModel : Model, 
	plotBuildingsFold : Folder, 
	xPos : number, 
	zPos : number, 
	rot : number
)
	local model = buildModel:Clone()
	model.Parent = plotBuildingsFold
	
	local yPos = plotHeight + model.PrimaryPart.Size.Y/2

	model:PivotTo(CFrame.new(xPos, yPos, zPos) * CFrame.Angles(0, math.rad(rot), 0))
	
	if model:FindFirstChild("TempWeld") then -- Unwelds animation parts (fans, drills, etc)
		task.delay(1, function()
			for _, weldVal in ipairs(model:FindFirstChild("TempWeld"):GetChildren()) do
				weldVal.Value.Parent.Anchored = true
				weldVal.Value:Destroy()
			end
		end)
	end
	
	return model
end

--[[
Generates a monotonically increasing serial ID per building.

Doesn't use child count or timestamps because
Buildings can be deleted, leaving gaps

Ex:
Furnace_1 output -> Conveyor -> Furnace_2 input
The 1 and 2 is the serial ID
]]
local function getSerial(serialFold)
	local i = 0
	repeat
		i += 1
	until serialFold:FindFirstChild(i) == nil
	return i
end

--[[
The main function of this script, handles player building placement request
Steps:
Step 1: Check validity for research and library requirements
Step 2: Clone hitbox, then check collision and boundary validity
Step 3: Check materials, then consume them
Step 4: Assign a serial ID, for conveyor load/save
Step 5: Clone and place the building
Step 6: Check for adjacent nodes and create direct conveyors if possible
Step 7: Return the building and direct conveyor modules, to be initialized by client
]]
placeBuildRemote.OnServerInvoke = function(
	plr : Player, 
	val : BoolValue, -- The name of the Building
	xPos : number, 
	zPos : number, 
	rot : number
)
	if not val:IsDescendantOf(buildLibFold) then 
		return false
	end

	local researchReq = val:GetAttribute("ResearchReq")
	local plrResearchFold = plr:FindFirstChild("Research")

	if not ((researchReq == "") or (plrResearchFold:FindFirstChild(researchReq))) then 
		return  false
	end

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

	if not hasMaterial.check(plr, hasMaterial.valToTab(val)) then 
		return false 
	end

	local plrItems = plr:FindFirstChild("Items")
	for _, mat in ipairs(val:FindFirstChild("Materials"):GetChildren()) do
		local plrVal = plrItems:FindFirstChild(mat.Name)
		plrVal.Value -= mat.Value
	end
	
	local plot = plr:FindFirstChild("Plot").Value
	local plotBuildingsFold = plot:FindFirstChild("Buildings")

	local model = placeBuild(buildModel, plotBuildingsFold, xPos, zPos, rot)
	local serial = getSerial(plot:FindFirstChild("Serials"))
	
	Instance.new("BoolValue", plot:FindFirstChild("Serials")).Name = serial -- Serial used for saving / loading conveyor purposes
	
	model.Name = model.Name .. "_" .. serial
	
	local conveyorObjects -- Direct conveyor modules, exists if there is adjacent opposite nodes
	if model:FindFirstChild("Node") then
		conveyorObjects = checkAdjacentNodes(model:FindFirstChild("Node"), plotBuildingsFold)
	end

	local module = model:FindFirstChild("Module") -- Module used for initialization
	return module, conveyorObjects
end

loadBuildRemote.OnInvoke = placeBuild

--[[
The main function of this script, handles player conveyor placement request
Steps:
Step 1: Check validity for library requirements
Step 2: Check if both input and output is occupied (Both must be not occupied)
Step 3: Build only hitbox from builder module, then check collision and boundary validity
Step 3: Check materials, then consume them
Step 5: Build conveyor from builder module
Step 7: Return the conveyor module (to be initalized by client), slots folder, and the slots amount
(Folder and amount is returned so that the client waits untill all slot is loaded before initializing)
]]
placeConveyorRemote.OnServerInvoke = function(
	plr : Player, 
	val : BoolValue, -- The name of the Conveyor
	outputNode : BasePart, 
	inputNode : BasePart
)
	if val:IsDescendantOf(buildLibFold) then 
		return false 
	end
	if outputNode:FindFirstChild("Occupied").Value ~= nil then 
		return false 
	end
	if inputNode:FindFirstChild("Occupied").Value ~= nil then 
		return false 
	end
	
	local buildModel = buildingFold:FindFirstChild(val.Name)
	local module = require(buildModel:FindFirstChild("Builder"))
	
	local hitboxModel, cost = module.build(outputNode.CFrame, inputNode.CFrame, true) -- Gets only the hitbox model and cost (no visual parts)
	local except = {outputNode.Parent.Parent.PrimaryPart, inputNode.Parent.Parent.PrimaryPart} -- Doesnt check for building of the nodes
	hitboxModel.Parent = bin
	
	for _, hitbox in (hitboxModel:GetChildren()) do
		if not buildValidator.checkCollisionWithException(plr, hitbox, except) then
			hitboxModel:Destroy()
			return false
		end
	end
	
	hitboxModel:Destroy()
	
	if not hasMaterial.check(plr, cost) then 
		return false 
	end
	
	local plrItems = plr:FindFirstChild("Items")
	for matName, matAmt in ipairs(cost) do
		local plrVal = plrItems:FindFirstChild(matName)
		plrVal.Value -= matAmt
	end
	
	local plot = plr:FindFirstChild("Plot").Value
	local plotBuildingsFold = plot:FindFirstChild("Buildings")
	
	local convObj, slotFold, slotAmt = buildConveyor(module, outputNode, inputNode, plotBuildingsFold, buildModel:FindFirstChild("Module"))
	local convModule = convObj:GetModule()
	
	return convModule, slotFold, slotAmt
end

loadConveyorRemote.OnInvoke = buildConveyor

--[[
Handles player recipe change request
Recipe (the item crafted) is for crafter building only
]]
saveRecipeRemote.OnServerEvent:Connect(function(plr, build, value)
	if not build:FindFirstChild("Recipe") then 
		return 
	end
	build:FindFirstChild("Recipe").Value = value
end)

local function refundMats(plr, mats)
	local plrInventory = plr:FindFirstChild("Items")
	for matName, matVal in ipairs(mats) do
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

	if not build:IsDescendantOf(plotBuildingsFold) then 
		return 
	end

	if not build:FindFirstChild("IsConveyor") then -- Handles building
		local nodeFold = build:FindFirstChild("Node")
		if nodeFold then
			for _, node in ipairs(nodeFold:GetChildren()) do
				local conv = node:FindFirstChild("Occupied").Value
				if conv and conv:FindFirstChild("IsDirectConv") == nil then -- Prevents deletion if conveyor is still atached (not direct coneyor)
					return false
				end
			end
		end

		local mats = buildToMats[string.split(build.Name, "_")[1]]

		if nodeFold then
			for _, node in ipairs(nodeFold:GetChildren()) do
				local conv = node:FindFirstChild("Occupied").Value
				if conv then
					deleteBuild(plr, conv)
				end
			end
		end

		build:Destroy()
		refundMats(plr, mats)
		
	else -- Handles conveyor
		local conveyor = Conveyor.FromModel(build)
		
		local builder = require(buildingFold[build.Name].Builder)
		local mats = builder.getCost(build:FindFirstChild("Length").Value) -- Get the original cost
		
		conveyor:Destroy()
		refundMats(plr, mats)
	end
end

deleteBuildRemote.OnServerEvent:Connect(deleteBuild)

--[[
Cache build materials at startup
]]
for _, category in ipairs(buildLibFold:GetChildren()) do
	for _, buildVal in ipairs(category:GetChildren()) do
		if buildVal:FindFirstChild("IsConveyor") then 
			continue 
		end
		
		local mats = {}
		for _, matVal in ipairs(buildVal:FindFirstChild("Materials"):GetChildren()) do
			mats[matVal.Name] = matVal.Value
		end
		buildToMats[buildVal.Name] = mats
	end
end
