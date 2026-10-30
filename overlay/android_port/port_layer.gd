extends Node
# Cave Crawler - Android port layer (Godot 3.5)
# Port by The Soim (https://t.me/thesoim) - v1.0.0
#
# Added as an autoload by tools/prepare_project.py. It never edits the game's own scripts:
# the touch buttons send the very same keys the keyboard uses (read from the game's input map),
# and menu taps go through the same focus + "ui_accept" path as a keyboard/gamepad.

const CFG_PATH = "user://thesoim_port.cfg"
const TELEGRAM_URL = "https://t.me/thesoim"
const TELEGRAM_APP_URL = "tg://resolve?domain=thesoim"
const GITHUB_URL = "https://github.com/Thesoim/Cave-Crawler"
const PLUGIN_NAME = "TheSoimPort"
const DESIGN_W = 256.0
const LABEL_SCALE = 0.7
const PORT_VERSION = "v1.0.0"
const THEME_PATH = "res://gui/theme_data/ui_theme.tres"
const ASSET_DIR = "res://android_port/"
const GAME_ACTIONS = ["left", "right", "jump", "fire", "up", "down", "pause"]
const BTN_W = 223.0       # button texture width (px)
const BTN_H = 243.0       # texture height incl. bottom padding used by the pressed state
const BTN_BODY_H = 233.0  # visible button body height (px)

# ---- saved settings ----
var cfg_enabled = true
var cfg_opacity = 0.7
var cfg_scale = 1.0
var cfg_haptics = true
var cfg_extra = false      # optional Up / Down buttons
var cfg_fps = 60
var cfg_fill = true       # automatic: fill the whole screen; "Original" keeps the 16:9 frame
var cfg_debug = false
var cfg_offsets = {}

# ---- runtime ----
var defs = {}
var buttons = {}          # name -> Sprite (visual only)
var tex_n = {}
var tex_p = {}
var touch_map = {}        # finger index -> button name
var action_count = {}     # action -> fingers holding it
var sent_state = {}       # action -> key currently held down in the engine
var press_time = {}
var pending_release = {}
var settings_buttons = {}

var ctl_layer
var ctl_root
var ui_layer
var ui_root
var deco
var tg_btn
var credit_left
var credit_right
var settings_panel
var credits_panel
var edit_overlay
var debug_label

var theme_res = null
var play_mode = false
var edit_mode = false
var gamepad_active = false
var panel_open = false
var player_now = false
var _scan_t = 0.0
var _drag_name = ""
var _drag_idx = -1
var _ui_target = null
var _ui_idx = -1
var _ui_start = Vector2.ZERO
var _slider = null
var _slider_idx = -1
var _last_auto_pause = -10.0
var _log_count = 0


func _ready():
	pause_mode = Node.PAUSE_MODE_PROCESS
	_load_cfg()
	get_tree().set_quit_on_go_back(false)
	_apply_display()
	if OS.get_name() != "Android" and not OS.has_touchscreen_ui_hint():
		# Desktop / no touchscreen: leave the game completely untouched.
		set_process(false)
		set_physics_process(false)
		set_process_input(false)
		return
	if ResourceLoader.exists(THEME_PATH):
		theme_res = load(THEME_PATH)
	_build_defs()
	ctl_layer = CanvasLayer.new()
	ctl_layer.layer = 120
	ctl_layer.pause_mode = Node.PAUSE_MODE_PROCESS
	add_child(ctl_layer)
	ctl_root = Node2D.new()
	ctl_root.visible = false
	ctl_layer.add_child(ctl_root)
	ui_layer = CanvasLayer.new()
	ui_layer.layer = 128
	ui_layer.pause_mode = Node.PAUSE_MODE_PROCESS
	add_child(ui_layer)
	ui_root = Control.new()
	ui_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui_root.rect_position = Vector2.ZERO
	ui_layer.add_child(ui_root)
	for bname in defs.keys():
		_make_button(bname)
	_make_deco()
	_make_debug_label()
	_make_panels()
	_make_edit_overlay()
	get_tree().root.connect("size_changed", self, "_relayout")
	_relayout()
	_refresh_labels()
	print("[TheSoimPort] ready, touch layer active ", PORT_VERSION)


# ------------------------------------------------------------------ config

func _load_cfg():
	var c = ConfigFile.new()
	if c.load(CFG_PATH) != OK:
		return
	cfg_enabled = bool(c.get_value("controls", "enabled", true))
	cfg_opacity = clamp(float(c.get_value("controls", "opacity", 0.7)), 0.2, 1.0)
	cfg_scale = clamp(float(c.get_value("controls", "scale", 1.0)), 0.6, 1.6)
	cfg_haptics = bool(c.get_value("controls", "haptics", true))
	cfg_extra = bool(c.get_value("controls", "extra", false))
	var offs = c.get_value("controls", "offsets", {})
	if typeof(offs) == TYPE_DICTIONARY:
		cfg_offsets = offs
	cfg_fps = int(c.get_value("display", "fps", 60))
	cfg_fill = bool(c.get_value("display", "fill", true))
	cfg_debug = bool(c.get_value("display", "debug", false))


func _save_cfg():
	var c = ConfigFile.new()
	c.set_value("controls", "enabled", cfg_enabled)
	c.set_value("controls", "opacity", cfg_opacity)
	c.set_value("controls", "scale", cfg_scale)
	c.set_value("controls", "haptics", cfg_haptics)
	c.set_value("controls", "extra", cfg_extra)
	c.set_value("controls", "offsets", cfg_offsets)
	c.set_value("display", "fps", cfg_fps)
	c.set_value("display", "fill", cfg_fill)
	c.set_value("display", "debug", cfg_debug)
	c.save(CFG_PATH)


func _apply_display():
	Engine.target_fps = cfg_fps
	var aspect = SceneTree.STRETCH_ASPECT_KEEP
	if cfg_fill:
		aspect = SceneTree.STRETCH_ASPECT_EXPAND
	get_tree().set_screen_stretch(SceneTree.STRETCH_MODE_2D, aspect, Vector2(256, 144))


# ------------------------------------------------------------------ touch buttons

func _build_defs():
	# name: [action, anchor_x (0 left / 1 right), anchor_y (0 top / 1 bottom), dx, dy, width, passby, extra]
	defs = {
		"left": ["left", 0, 1, 6, 6, 30, true, false],
		"right": ["right", 0, 1, 42, 6, 30, true, false],
		"up": ["up", 0, 1, 6, 50, 24, false, true],
		"down": ["down", 0, 1, 36, 50, 24, false, true],
		"jump": ["jump", 1, 1, 6, 24, 32, false, false],
		"fire": ["fire", 1, 1, 50, 6, 32, false, false],
		"pause": ["pause", 1, 0, 6, 16, 20, false, false],
	}


func _tex_file(bname, pressed):
	var base = bname
	if bname == "fire":
		base = "shoot"
	var suffix = ""
	if pressed:
		suffix = "_p"
	return ASSET_DIR + "btn_" + base + suffix + ".png"


func _load_tex(path):
	var img = Image.new()
	if img.load(path) != OK:
		return null
	var t = ImageTexture.new()
	t.create_from_image(img, Texture.FLAG_FILTER | Texture.FLAG_MIPMAPS)
	return t


func _make_button(bname):
	var spr = Sprite.new()
	spr.name = "btn_" + bname
	spr.centered = false
	tex_n[bname] = _load_tex(_tex_file(bname, false))
	tex_p[bname] = _load_tex(_tex_file(bname, true))
	spr.texture = tex_n[bname]
	ctl_root.add_child(spr)
	buttons[bname] = spr


func _margins(vis):
	# Safe margins (left, top, right, bottom) in virtual units so buttons avoid notches / cutouts.
	var win = OS.get_window_size()
	if win.x <= 0.0 or win.y <= 0.0 or vis.x <= 0.0 or vis.y <= 0.0:
		return [0.0, 0.0, 0.0, 0.0]
	var sc = min(win.x / vis.x, win.y / vis.y)
	var bar_x = (win.x - vis.x * sc) * 0.5
	var bar_y = (win.y - vis.y * sc) * 0.5
	var sa = OS.get_window_safe_area()
	if sa.size.x <= 0.0 or sa.size.y <= 0.0:
		return [0.0, 0.0, 0.0, 0.0]
	var l = max(0.0, (sa.position.x - bar_x) / sc)
	var t = max(0.0, (sa.position.y - bar_y) / sc)
	var r = max(0.0, (win.x - (sa.position.x + sa.size.x) - bar_x) / sc)
	var b = max(0.0, (win.y - (sa.position.y + sa.size.y) - bar_y) / sc)
	return [l, t, r, b]


func _layout_scene(vis):
	# Fill mode: the screen is wider than the game's 256x144 design area. Centre every UI layer of the
	# current scene (title, menus, HUD) in it; the world is centred by the game's own camera.
	var scene = get_tree().current_scene
	if scene == null:
		return
	var extra = max(0.0, (vis.x - DESIGN_W) / 2.0)
	for c in scene.get_children():
		if c is CanvasLayer and abs(c.offset.x - extra) > 0.01:
			c.offset = Vector2(extra, c.offset.y)


func _body_size(bname):
	var w = float(defs[bname][5]) * cfg_scale
	return Vector2(w, w * BTN_BODY_H / BTN_W)


func _relayout():
	if ctl_root == null:
		return
	var vis = get_viewport().get_visible_rect().size
	var m = _margins(vis)
	for bname in buttons.keys():
		var d = defs[bname]
		var sz = _body_size(bname)
		var spr = buttons[bname]
		var k = sz.x / BTN_W
		spr.scale = Vector2(k, k)
		var x
		var y
		if int(d[1]) == 0:
			x = m[0] + float(d[3])
		else:
			x = vis.x - m[2] - float(d[3]) - sz.x
		if int(d[2]) == 0:
			y = m[1] + float(d[4])
		else:
			y = vis.y - m[3] - float(d[4]) - sz.y
		var off = Vector2.ZERO
		if cfg_offsets.has(bname):
			off = cfg_offsets[bname]
		spr.position = Vector2(x, y) + off
		var a = cfg_opacity
		if edit_mode:
			a = 1.0
		spr.modulate = Color(1, 1, 1, a)
		spr.visible = (not bool(d[7])) or cfg_extra or edit_mode
	tg_btn.rect_position = Vector2(m[0] + 5, m[1] + 5)
	var lh = credit_left.get_font("font").get_height() * LABEL_SCALE
	credit_left.rect_scale = Vector2(LABEL_SCALE, LABEL_SCALE)
	credit_right.rect_scale = Vector2(LABEL_SCALE, LABEL_SCALE)
	credit_left.rect_position = Vector2(m[0] + 6, vis.y - m[3] - 3 - lh * 2.0)
	var rw = credit_right.get_font("font").get_string_size(credit_right.text).x * LABEL_SCALE
	credit_right.rect_position = Vector2(vis.x - m[2] - 6 - rw, vis.y - m[3] - 3 - lh)
	_layout_scene(vis)
	for p in [settings_panel, credits_panel, edit_overlay]:
		p.rect_position = Vector2.ZERO
		p.rect_size = vis


# ------------------------------------------------------------------ title-screen decorations

func _style(c):
	if theme_res != null:
		c.theme = theme_res


func _pixel_label(txt, align):
	var l = Label.new()
	l.text = txt
	l.align = align
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


func _make_deco():
	deco = Control.new()
	deco.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_style(deco)
	ui_root.add_child(deco)
	deco.visible = false
	tg_btn = TextureButton.new()
	var tg_tex = _load_tex(ASSET_DIR + "telegram.png")
	if tg_tex != null:
		tg_btn.texture_normal = tg_tex
	tg_btn.expand = true
	tg_btn.stretch_mode = TextureButton.STRETCH_SCALE
	tg_btn.rect_min_size = Vector2(28, 28)
	tg_btn.rect_size = Vector2(28, 28)
	tg_btn.connect("pressed", self, "_open_telegram")
	deco.add_child(tg_btn)
	credit_left = _pixel_label("Port By\nThe Soim", Label.ALIGN_LEFT)
	credit_left.autowrap = false
	deco.add_child(credit_left)
	credit_right = _pixel_label("Release " + PORT_VERSION, Label.ALIGN_RIGHT)
	credit_right.autowrap = false
	deco.add_child(credit_right)


func _open_telegram():
	# The native plugin opens the Telegram app by its own package (org.telegram.messenger and the
	# usual forks); without it fall back to the tg:// link, then to the web page.
	if Engine.has_singleton(PLUGIN_NAME):
		var p = Engine.get_singleton(PLUGIN_NAME)
		if p.openTelegram():
			return
	var err = OS.shell_open(TELEGRAM_APP_URL)
	if err != OK:
		OS.shell_open(TELEGRAM_URL)


func _open_github():
	OS.shell_open(GITHUB_URL)


func _make_debug_label():
	debug_label = Label.new()
	debug_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_style(debug_label)
	debug_label.rect_position = Vector2(70, 2)
	debug_label.visible = false
	ui_root.add_child(debug_label)


# ------------------------------------------------------------------ settings / credits panels

func _make_panel_root():
	var root = Control.new()
	_style(root)
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	var bg = ColorRect.new()
	bg.color = Color(0, 0, 0, 0.96)
	bg.set_anchors_and_margins_preset(Control.PRESET_WIDE)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(bg)
	ui_root.add_child(root)
	root.visible = false
	return root


func _centered_box(root):
	var cc = CenterContainer.new()
	cc.set_anchors_and_margins_preset(Control.PRESET_WIDE)
	cc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(cc)
	var vb = VBoxContainer.new()
	vb.add_constant_override("separation", 3)
	cc.add_child(vb)
	return vb


func _title_label(txt):
	var t = Label.new()
	t.text = txt
	t.align = Label.ALIGN_CENTER
	return t


func _make_panels():
	settings_panel = _make_panel_root()
	var vb = _centered_box(settings_panel)
	vb.add_child(_title_label("Port Settings"))
	var grid = GridContainer.new()
	grid.columns = 2
	grid.add_constant_override("hseparation", 3)
	grid.add_constant_override("vseparation", 3)
	vb.add_child(grid)
	for k in ["touch", "haptics", "opacity", "size", "extra", "fps", "fit", "edit", "reset", "debug"]:
		var btn = Button.new()
		btn.connect("pressed", self, "_on_setting", [k])
		grid.add_child(btn)
		settings_buttons[k] = btn
	var back = Button.new()
	back.text = "Back"
	back.connect("pressed", self, "_close_panels")
	vb.add_child(back)

	credits_panel = _make_panel_root()
	var cb = _centered_box(credits_panel)
	cb.add_child(_title_label("Credits"))
	var info = Label.new()
	info.text = "Android port by The Soim\nRelease " + PORT_VERSION
	info.align = Label.ALIGN_CENTER
	cb.add_child(info)
	var game = Label.new()
	game.text = "Game by evan12811\nEngine: Godot 3.5"
	game.align = Label.ALIGN_CENTER
	cb.add_child(game)
	var links = VBoxContainer.new()
	links.add_constant_override("separation", 3)
	cb.add_child(links)
	var tg = Button.new()
	tg.text = "Telegram: t.me/thesoim"
	tg.connect("pressed", self, "_open_telegram")
	links.add_child(tg)
	var gh = Button.new()
	gh.text = "GitHub: Thesoim/Cave-Crawler"
	gh.connect("pressed", self, "_open_github")
	links.add_child(gh)
	var cback = Button.new()
	cback.text = "Back"
	cback.connect("pressed", self, "_close_panels")
	cb.add_child(cback)


func _on_off(v):
	if v:
		return "On"
	return "Off"


func _refresh_labels():
	if settings_buttons.empty():
		return
	settings_buttons["touch"].text = "Touch: " + _on_off(cfg_enabled)
	settings_buttons["haptics"].text = "Vibrate: " + _on_off(cfg_haptics)
	settings_buttons["opacity"].text = "Opacity: " + str(int(round(cfg_opacity * 100.0))) + "%"
	settings_buttons["size"].text = "Size: " + str(int(round(cfg_scale * 100.0))) + "%"
	settings_buttons["extra"].text = "Up/Down: " + _on_off(cfg_extra)
	var f = "Max"
	if cfg_fps != 0:
		f = str(cfg_fps)
	settings_buttons["fps"].text = "FPS: " + f
	var fit = "Original"
	if cfg_fill:
		fit = "Fill"
	settings_buttons["fit"].text = "Screen: " + fit
	settings_buttons["edit"].text = "Edit layout"
	settings_buttons["reset"].text = "Reset layout"
	settings_buttons["debug"].text = "Debug: " + _on_off(cfg_debug)


func _next_value(cur, arr):
	var best = 0
	var best_d = 1000.0
	for i in range(arr.size()):
		var dd = abs(float(arr[i]) - cur)
		if dd < best_d:
			best_d = dd
			best = i
	return float(arr[(best + 1) % arr.size()])


func _on_setting(k):
	match k:
		"touch":
			cfg_enabled = not cfg_enabled
		"haptics":
			cfg_haptics = not cfg_haptics
		"opacity":
			cfg_opacity = _next_value(cfg_opacity, [0.3, 0.45, 0.6, 0.7, 0.85, 1.0])
		"size":
			cfg_scale = _next_value(cfg_scale, [0.8, 1.0, 1.2, 1.4])
		"extra":
			cfg_extra = not cfg_extra
		"fps":
			if cfg_fps == 30:
				cfg_fps = 60
			elif cfg_fps == 60:
				cfg_fps = 0
			else:
				cfg_fps = 30
		"fit":
			cfg_fill = not cfg_fill
		"edit":
			_start_edit()
			return
		"reset":
			cfg_offsets.clear()
		"debug":
			cfg_debug = not cfg_debug
	_apply_display()
	_relayout()
	_refresh_labels()
	_save_cfg()


func _open_settings():
	panel_open = true
	credits_panel.visible = false
	settings_panel.visible = true
	_refresh_labels()
	_update_state()


func _open_credits():
	panel_open = true
	settings_panel.visible = false
	credits_panel.visible = true
	_update_state()


func _close_panels():
	panel_open = false
	settings_panel.visible = false
	credits_panel.visible = false
	_save_cfg()
	_update_state()


# ------------------------------------------------------------------ layout editor

func _make_edit_overlay():
	edit_overlay = Control.new()
	_style(edit_overlay)
	edit_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	var bg = ColorRect.new()
	bg.color = Color(0, 0, 0, 0.4)
	bg.set_anchors_and_margins_preset(Control.PRESET_WIDE)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	edit_overlay.add_child(bg)
	var top = HBoxContainer.new()
	top.rect_position = Vector2(60, 6)
	top.add_constant_override("separation", 4)
	var hint = Label.new()
	hint.text = "Drag buttons"
	top.add_child(hint)
	var done = Button.new()
	done.text = "Done"
	done.connect("pressed", self, "_end_edit")
	top.add_child(done)
	var rst = Button.new()
	rst.text = "Reset"
	rst.connect("pressed", self, "_reset_offsets")
	top.add_child(rst)
	edit_overlay.add_child(top)
	ui_root.add_child(edit_overlay)
	edit_overlay.visible = false


func _start_edit():
	edit_mode = true
	settings_panel.visible = false
	edit_overlay.visible = true
	_relayout()
	_update_state()


func _end_edit():
	edit_mode = false
	edit_overlay.visible = false
	_drag_name = ""
	_save_cfg()
	_relayout()
	_open_settings()


func _reset_offsets():
	cfg_offsets.clear()
	_relayout()


func _button_at(pos, slop):
	var found = ""
	for bname in buttons.keys():
		var spr = buttons[bname]
		if not spr.visible:
			continue
		var r = Rect2(spr.position, _body_size(bname)).grow(slop)
		if r.has_point(pos):
			found = bname
	return found


# ------------------------------------------------------------------ input

func _input(event):
	if event is InputEventJoypadButton:
		gamepad_active = true
	elif event is InputEventJoypadMotion:
		if abs(event.axis_value) > 0.6:
			gamepad_active = true
	if ctl_root == null:
		return
	if not (event is InputEventScreenTouch or event is InputEventScreenDrag):
		return
	if event is InputEventScreenTouch and event.pressed:
		gamepad_active = false
	if _log_count < 12:
		_log_count += 1
		print("[TheSoimPort] touch ", event.as_text(), " play=", play_mode, " panel=", panel_open, " edit=", edit_mode)
	if play_mode:
		_play_touch(event)
		return
	var consumed = _ui_touch(event)
	if edit_mode and not consumed:
		_edit_touch(event)


# ---- gameplay buttons: every finger drives its own button ----

func _play_touch(event):
	if event is InputEventScreenTouch:
		if event.pressed:
			var bn = _button_at(event.position, 6.0)
			if bn != "":
				_press_finger(event.index, bn)
		else:
			_release_finger(event.index)
	elif event is InputEventScreenDrag:
		var cur = ""
		if touch_map.has(event.index):
			cur = touch_map[event.index]
		if cur != "" and bool(defs[cur][6]):
			var bn2 = _button_at(event.position, 6.0)
			if bn2 != "" and bn2 != cur and bool(defs[bn2][6]):
				_release_finger(event.index)
				_press_finger(event.index, bn2)


func _press_finger(idx, bname):
	if touch_map.has(idx):
		_release_finger(idx)
	touch_map[idx] = bname
	buttons[bname].texture = tex_p[bname]
	_set_action(str(defs[bname][0]), 1)
	if cfg_haptics:
		Input.vibrate_handheld(12)


func _release_finger(idx):
	if not touch_map.has(idx):
		return
	var bname = touch_map[idx]
	touch_map.erase(idx)
	buttons[bname].texture = tex_n[bname]
	_set_action(str(defs[bname][0]), -1)


func _release_all():
	touch_map.clear()
	for bname in buttons.keys():
		buttons[bname].texture = tex_n[bname]
	for a in action_count.keys():
		if int(action_count[a]) > 0:
			_send_action(str(a), false)
	action_count.clear()
	pending_release.clear()
	sent_state.clear()
	for a2 in GAME_ACTIONS:
		_send_action(a2, false)


func _set_action(a, delta):
	var prev = int(action_count.get(a, 0))
	var now = int(max(0, prev + delta))
	action_count[a] = now
	if prev == 0 and now > 0:
		pending_release.erase(a)
		if bool(sent_state.get(a, false)):
			_send_action(a, false)
		press_time[a] = OS.get_ticks_msec()
		sent_state[a] = true
		_send_action(a, true)
	elif prev > 0 and now == 0:
		# Keep very short taps pressed for ~2 physics frames so the game never misses a jump.
		var held = OS.get_ticks_msec() - int(press_time.get(a, 0))
		if held < 70:
			_delayed_release(a, float(70 - held) / 1000.0)
		else:
			sent_state[a] = false
			_send_action(a, false)


func _delayed_release(a, secs):
	pending_release[a] = true
	yield(get_tree().create_timer(secs, true), "timeout")
	if bool(pending_release.get(a, false)) and int(action_count.get(a, 0)) == 0:
		pending_release.erase(a)
		sent_state[a] = false
		_send_action(a, false)


func _key_event_for(a):
	for ev in InputMap.get_action_list(a):
		if ev is InputEventKey:
			return ev
	return null


func _send_action(a, pressed):
	if not InputMap.has_action(a):
		return
	# The exact key the game has bound to this action: the engine treats the touch like a real
	# keyboard press (the game reads jump through _input, fire/left/right through Input polling).
	var src = _key_event_for(a)
	if src != null:
		var k = src.duplicate()
		k.pressed = pressed
		k.echo = false
		Input.parse_input_event(k)
		return
	var e = InputEventAction.new()
	e.action = a
	e.pressed = pressed
	Input.parse_input_event(e)


func _tap_action(a):
	_send_action(a, true)
	yield(get_tree().create_timer(0.08, true), "timeout")
	_send_action(a, false)


# Safety net while the touch buttons are active:
#  - a finger that is still down keeps its action pressed in the game (re-press if the engine lost it);
#  - an action with no finger, no physical key and no gamepad must not stay pressed
#    (a stuck "left" would cancel "right": movement = right - left).
func _physics_process(_delta):
	if ctl_root == null or not play_mode:
		return
	var has_pad = Input.get_connected_joypads().size() > 0
	for a in GAME_ACTIONS:
		if a == "pause":
			continue
		var held = int(action_count.get(a, 0)) > 0
		var pressed = Input.is_action_pressed(a)
		if held and bool(sent_state.get(a, false)) and not pressed:
			print("[TheSoimPort] re-pressing ", a)
			_send_action(a, true)
		elif (not held) and (not bool(sent_state.get(a, false))) and pressed and not has_pad and not _physical_key_down(a):
			print("[TheSoimPort] releasing stuck ", a)
			_send_action(a, false)
			Input.action_release(a)


func _physical_key_down(a):
	for ev in InputMap.get_action_list(a):
		if ev is InputEventKey:
			if ev.scancode != 0 and Input.is_key_pressed(ev.scancode):
				return true
	return false


# ---- layout editor drag ----

func _edit_touch(event):
	if event is InputEventScreenTouch:
		if event.pressed:
			_drag_name = _button_at(event.position, 5.0)
			_drag_idx = event.index
		elif event.index == _drag_idx:
			_drag_name = ""
			_save_cfg()
	elif event is InputEventScreenDrag:
		if _drag_name != "" and event.index == _drag_idx:
			var cur = Vector2.ZERO
			if cfg_offsets.has(_drag_name):
				cur = cfg_offsets[_drag_name]
			cfg_offsets[_drag_name] = cur + event.relative
			_relayout()


# ---- menus: own tap handling (the game ignores the mouse in its menus) ----

func _hit_control(c, pos):
	if c.rect_size.x <= 0.0 or c.rect_size.y <= 0.0:
		return false
	var xf = c.get_global_transform_with_canvas()
	var local = xf.affine_inverse().xform(pos)
	return Rect2(Vector2.ZERO, c.rect_size).has_point(local)


func _collect(n, out):
	for c in n.get_children():
		if c is BaseButton or c is Slider:
			out.append(c)
		if c is Control or c is CanvasLayer:
			_collect(c, out)


func _game_controls():
	var out = []
	var scene = get_tree().current_scene
	if scene != null:
		_collect(scene, out)
	return out


func _my_controls():
	var out = []
	_collect(ui_root, out)
	return out


func _alive(c):
	return c != null and is_instance_valid(c) and c.is_inside_tree()


func _ctl_visible(c):
	return c.is_visible_in_tree()


func _button_ui_at(pos):
	var theirs = null
	var mine = null
	for c in _my_controls():
		if c is BaseButton and not c.disabled and _ctl_visible(c) and _hit_control(c, pos):
			mine = c
	if mine != null:
		return mine
	if panel_open or edit_mode:
		return null
	for c in _game_controls():
		if c is BaseButton and not c.disabled and _ctl_visible(c) and _hit_control(c, pos):
			theirs = c
	return theirs


func _slider_at(pos):
	var found = null
	for c in _game_controls():
		if c is Slider and c.editable and _ctl_visible(c) and _hit_control(c, pos):
			found = c
	return found


func _set_slider(s, pos):
	var xf = s.get_global_transform_with_canvas()
	var local = xf.affine_inverse().xform(pos)
	var ratio
	if s is VSlider:
		ratio = 1.0 - clamp(local.y / max(s.rect_size.y, 1.0), 0.0, 1.0)
	else:
		ratio = clamp(local.x / max(s.rect_size.x, 1.0), 0.0, 1.0)
	s.value = s.min_value + ratio * (s.max_value - s.min_value)


func _is_mine(c):
	return ui_root.is_a_parent_of(c)


func _activate(b):
	if not _alive(b) or b.disabled:
		return
	if _is_mine(b):
		b.emit_signal("pressed")
		return
	# The game's buttons: same path as a keyboard/gamepad - focus + "ui_accept".
	if b.focus_mode != Control.FOCUS_NONE:
		b.grab_focus()
	_send_ui_accept()


func _send_ui_accept():
	var src = _key_event_for("ui_accept")
	if src == null:
		return
	var down = src.duplicate()
	down.pressed = true
	down.echo = false
	Input.parse_input_event(down)
	yield(get_tree().create_timer(0.06, true), "timeout")
	var up = src.duplicate()
	up.pressed = false
	up.echo = false
	Input.parse_input_event(up)


func _slider_signal(s, sig, args):
	# drag_started / drag_ended exist only on some Godot 3 versions: emit them when present.
	if s.has_signal(sig):
		s.callv("emit_signal", [sig] + args)


func _ui_reset():
	if _slider != null and _alive(_slider):
		_slider_signal(_slider, "drag_ended", [true])
	_ui_target = null
	_ui_idx = -1
	_slider = null
	_slider_idx = -1


func _ui_touch(event):
	if event is InputEventScreenTouch:
		if event.pressed:
			if _ui_idx != -1 or _slider_idx != -1:
				return false
			if not (panel_open or edit_mode):
				var sl = _slider_at(event.position)
				if sl != null:
					_slider = sl
					_slider_idx = event.index
					_slider_signal(sl, "drag_started", [])
					_set_slider(sl, event.position)
					return true
			var b = _button_ui_at(event.position)
			if b != null:
				_ui_target = b
				_ui_idx = event.index
				_ui_start = event.position
				return true
			return false
		else:
			if event.index == _slider_idx and _slider != null:
				_set_slider(_slider, event.position)
				_slider_signal(_slider, "drag_ended", [true])
				_slider = null
				_slider_idx = -1
				return true
			if event.index == _ui_idx:
				var tgt = _ui_target
				_ui_target = null
				_ui_idx = -1
				if _alive(tgt) and event.position.distance_to(_ui_start) < 14.0 and _hit_control(tgt, event.position):
					_activate(tgt)
				return true
		return false
	elif event is InputEventScreenDrag:
		if event.index == _slider_idx and _slider != null:
			_set_slider(_slider, event.position)
			return true
		if event.index == _ui_idx:
			return true
	return false


# ------------------------------------------------------------------ state

func _process(delta):
	if debug_label != null:
		debug_label.visible = cfg_debug
		if cfg_debug:
			var t = "Fingers " + str(touch_map.size()) + " Game:"
			for a in ["right", "left", "jump", "fire"]:
				if Input.is_action_pressed(a):
					t += " " + a
			debug_label.text = t
	_scan_t -= delta
	if _scan_t <= 0.0:
		_scan_t = 0.15
		_update_state()


func _global():
	return get_node_or_null("/root/Global")


func _menu_visible():
	for c in _game_controls():
		if c is BaseButton and _ctl_visible(c):
			return true
	return false


func _in_level():
	var g = _global()
	if g == null:
		return false
	var p = g.get("player")
	return p != null and is_instance_valid(p)


func _update_state():
	if ctl_root == null:
		return
	var menu_now = _menu_visible()
	player_now = _in_level()
	var g = _global()
	var level_over = false
	if g != null:
		level_over = bool(g.get("level_end")) or bool(g.get("ending")) or bool(g.get("player_dead"))
	var want = cfg_enabled and player_now and (not menu_now) and (not get_tree().paused) and (not level_over) and (not panel_open) and (not gamepad_active) and (not edit_mode)
	if want != play_mode:
		_set_play_mode(want)
	ctl_root.visible = play_mode or edit_mode
	# Telegram icon + "Port By" / "Release" texts: title screen only, never inside sub menus.
	var scene = get_tree().current_scene
	var on_title = scene != null and scene.name == "MainMenu"
	deco.visible = on_title and (not panel_open) and (not edit_mode) and (not play_mode)
	if scene != null:
		_inject_menus(scene)
		_layout_scene(get_viewport().get_visible_rect().size)


func _set_play_mode(on):
	play_mode = on
	_ui_reset()
	_release_all()
	print("[TheSoimPort] play_mode=", on)


# ------------------------------------------------------------------ menu injection

func _inject_menus(scene):
	# Adds the port's entries to the game's own menus with the game's own button style:
	#  - title screen: "Credits" right under "Options"
	#  - OPTIONS screen: "Port Settings" at the end of the list
	var menu = scene.get_node_or_null("UI/MainMenuGUI/Menu")
	if menu != null and not menu.has_meta("port_injected"):
		menu.set_meta("port_injected", true)
		var opt = menu.get_node_or_null("OptBtn")
		if opt != null:
			var b = opt.duplicate(2)  # groups only: no signal connections, no script
			b.name = "CreditsBtn"
			b.text = "Credits"
			menu.add_child(b)
			menu.move_child(b, opt.get_index() + 1)
			b.connect("button_down", self, "_play_select")
			b.connect("pressed", self, "_open_credits")
			# Centred under the title, text centred; nothing else on the screen is covered.
			menu.anchor_left = 0.5
			menu.anchor_right = 0.5
			menu.margin_left = -29.0
			menu.margin_right = 29.0
			menu.margin_top = -86.0
			menu.margin_bottom = -26.0
			for mb in menu.get_children():
				if mb is Button:
					mb.align = Button.ALIGN_CENTER
			print("[TheSoimPort] injected Credits button")
	for path in ["UI/OptionsMenuGUI", "OptionsMenuGUI"]:
		var om = scene.get_node_or_null(path)
		if om != null and not om.has_meta("port_injected"):
			om.set_meta("port_injected", true)
			var box = om.get_node_or_null("VBoxContainer")
			var back = om.get_node_or_null("BackBtn")
			if box != null and back != null:
				var b2 = back.duplicate(2)
				b2.name = "PortSettingsBtn"
				b2.text = "Port Settings"
				box.add_child(b2)
				b2.connect("button_down", self, "_play_select")
				b2.connect("pressed", self, "_open_settings")
				print("[TheSoimPort] injected Port Settings button")


func _play_select():
	var a = get_node_or_null("/root/Audio")
	if a != null and a.get("select") != null:
		a.select.play()


# ------------------------------------------------------------------ Android lifecycle

func _notification(what):
	if what == MainLoop.NOTIFICATION_WM_GO_BACK_REQUEST:
		_on_back()
	elif what == MainLoop.NOTIFICATION_APPLICATION_PAUSED or what == MainLoop.NOTIFICATION_WM_FOCUS_OUT:
		_auto_pause()


func _on_back():
	if ctl_root == null:
		return
	if edit_mode:
		_end_edit()
	elif panel_open:
		_close_panels()
	elif play_mode:
		_tap_action("pause")
	else:
		# Menus: Continue on the pause screen, Back on Options / Level select; nothing elsewhere
		# (so Back can never leave the game or jump to the main menu by accident).
		for wanted in ["ContBtn", "BackBtn"]:
			for c in _game_controls():
				if c is BaseButton and _ctl_visible(c) and c.name == wanted:
					_activate(c)
					return


func _auto_pause():
	if ctl_root == null:
		return
	_release_all()
	if not play_mode:
		return
	var now = OS.get_ticks_msec() / 1000.0
	if now - _last_auto_pause < 1.0:
		return
	_last_auto_pause = now
	_tap_action("pause")
