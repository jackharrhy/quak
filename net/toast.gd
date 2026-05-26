extends CanvasLayer
## Toast — minimal "show a message for N seconds, then fade out" overlay.

const DEFAULT_DURATION: float = 3.0
const FADE_TIME: float = 0.4

@onready var label: Label = $Panel/Label
@onready var panel: PanelContainer = $Panel

var _tween: Tween


func _ready() -> void:
	panel.modulate.a = 0.0


func show_message(text: String, duration: float = DEFAULT_DURATION) -> void:
	label.text = text
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = create_tween()
	_tween.tween_property(panel, "modulate:a", 1.0, FADE_TIME)
	_tween.tween_interval(duration)
	_tween.tween_property(panel, "modulate:a", 0.0, FADE_TIME)
