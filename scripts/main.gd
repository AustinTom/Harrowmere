extends Node3D
## Entry point. Wires the modules together:
##   World (map, actors, out-of-combat systems)
##   CombatManager (turn-based and real-time on one rule set)
##   HUD (all UI)  +  PlayerController (input)  +  CameraRig

const AREA := "res://data/areas/fennicks_landing.json"

var world: World
var combat: CombatManager
var hud
var controller
var rig


func _ready() -> void:
	GameState.reset()
	world = World.new()
	world.name = "World"
	combat = CombatManager.new()
	combat.name = "Combat"
	world.combat = combat
	combat.world = world
	add_child(world)
	add_child(combat)
	world.load_area(AREA)
	combat.turn_changed.connect(world.on_turn_changed)
	print(Models.report())

	rig = preload("res://scripts/world/camera_rig.gd").new()
	rig.name = "CameraRig"
	rig.target = world.player
	add_child(rig)
	rig.snap()

	controller = preload("res://scripts/ui/player_controller.gd").new()
	controller.name = "PlayerController"
	controller.world = world
	controller.combat = combat
	controller.rig = rig

	hud = preload("res://scripts/ui/hud.gd").new()
	hud.name = "HUD"
	hud.world = world
	hud.combat = combat
	hud.controller = controller
	controller.hud = hud
	add_child(hud)
	add_child(controller)

	Events.post("[b]Fennick's Landing[/b], the Meltlands. Sixty years into the Thaw.")
	Events.post("Warden Osk Brannel (by the well) has work. Iska Vell follows you.")
	Events.post("East of the fence the ground is grey: low Resonance. Spells weaken there, and guns run true.")
