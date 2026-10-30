#!/usr/bin/env python3
"""
Logic simulation of the port's multi-touch state machine (overlay/android_port/port_layer.gd:
_button_at / _play_touch / _press_finger / _release_finger / _set_action / _delayed_release).

It replays finger sequences and checks that every button is independent: pressing or releasing one
finger never changes the key held by another finger. This validates the LOGIC only; it is not a test of
the Godot engine or of a device.

    python3 tools/simulate_touch_logic.py
"""
BTN_W, BODY_H = 223.0, 233.0
VIS = (256.0, 144.0)
# name: (action, anchor_x, anchor_y, dx, dy, width, passby)   (same numbers as _build_defs, scale 1.0)
DEFS = {
    "left": ("left", 0, 1, 6, 6, 30, True), "right": ("right", 0, 1, 42, 6, 30, True),
    "up": ("up", 0, 1, 6, 50, 24, False), "down": ("down", 0, 1, 36, 50, 24, False),
    "jump": ("jump", 1, 1, 6, 24, 32, False), "fire": ("fire", 1, 1, 50, 6, 32, False),
    "pause": ("pause", 1, 0, 6, 16, 20, False),
}


def rect(n):
    _a, ax, ay, dx, dy, w, _p = DEFS[n]
    h = w * BODY_H / BTN_W
    x = dx if ax == 0 else VIS[0] - dx - w
    y = dy if ay == 0 else VIS[1] - dy - h
    return x, y, w, h


def center(n):
    x, y, w, h = rect(n)
    return (x + w / 2, y + h / 2)


class Port:
    def __init__(self):
        self.t = 0
        self.touch_map, self.count = {}, {}
        self.sent, self.press_time, self.pending = {}, {}, {}
        self.game = {}
        self.timers = []

    def advance(self, ms):
        end = self.t + ms
        while True:
            due = sorted([x for x in self.timers if x[0] <= end], key=lambda x: x[0])
            if not due:
                break
            d = due[0]; self.timers.remove(d); self.t = d[0]; d[1]()
        self.t = end

    def send(self, a, pressed):
        self.game[a] = pressed

    def set_action(self, a, delta):
        prev = self.count.get(a, 0); now = max(0, prev + delta); self.count[a] = now
        if prev == 0 and now > 0:
            self.pending.pop(a, None)
            if self.sent.get(a):
                self.send(a, False)
            self.press_time[a] = self.t; self.sent[a] = True; self.send(a, True)
        elif prev > 0 and now == 0:
            held = self.t - self.press_time.get(a, 0)
            if held < 70:
                self.pending[a] = True
                def later(a=a):
                    if self.pending.get(a) and self.count.get(a, 0) == 0:
                        self.pending.pop(a); self.sent[a] = False; self.send(a, False)
                self.timers.append((self.t + (70 - held), later))
            else:
                self.sent[a] = False; self.send(a, False)

    def button_at(self, pos, slop=6.0):
        found = ""
        for n in DEFS:
            x, y, w, h = rect(n)
            if x - slop <= pos[0] <= x + w + slop and y - slop <= pos[1] <= y + h + slop:
                found = n
        return found

    def press_finger(self, idx, n):
        if idx in self.touch_map:
            self.release_finger(idx)
        self.touch_map[idx] = n; self.set_action(DEFS[n][0], 1)

    def release_finger(self, idx):
        if idx not in self.touch_map:
            return
        n = self.touch_map.pop(idx); self.set_action(DEFS[n][0], -1)

    def touch(self, idx, pos, pressed):
        if pressed:
            n = self.button_at(pos)
            if n:
                self.press_finger(idx, n)
        else:
            self.release_finger(idx)

    def drag(self, idx, pos):
        cur = self.touch_map.get(idx, "")
        if cur and DEFS[cur][6]:
            n2 = self.button_at(pos)
            if n2 and n2 != cur and DEFS[n2][6]:
                self.release_finger(idx); self.press_finger(idx, n2)


def check(p, **expect):
    for a, v in expect.items():
        assert bool(p.game.get(a, False)) == v, (p.t, a, v, p.game)


def check_matches_gdscript():
    import os, re
    src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "overlay", "android_port", "port_layer.gd")).read()
    rows = re.findall(r'"(\w+)": \["(\w+)", (\d), (\d), (\d+), (\d+), (\d+), (true|false), (true|false)\],', src)
    gd = {r[0]: (r[1], int(r[2]), int(r[3]), int(r[4]), int(r[5]), int(r[6]), r[7] == "true") for r in rows}
    assert gd == DEFS, "layout table differs from port_layer.gd:\n%s\n%s" % (gd, DEFS)


def run():
    check_matches_gdscript()
    n = 0
    # buttons must not overlap each other (otherwise one tap could press two buttons)
    names = list(DEFS)
    for i, a in enumerate(names):
        for b in names[i + 1:]:
            xa, ya, wa, ha = rect(a); xb, yb, wb, hb = rect(b)
            s = 6.0   # hit slop used by _button_at on each side; adjacent pairs share the slop zone on purpose
            assert xa + wa + s <= xb or xb + wb + s <= xa or ya + ha + s <= yb or yb + hb + s <= ya or {a, b} in ({"left", "right"}, {"up", "down"}), (a, b)
    n += 1
    # 1) right first, then jump; release jump, then right
    p = Port(); p.touch(0, center("right"), True); p.advance(200)
    p.touch(1, center("jump"), True); p.advance(300); check(p, right=True, jump=True)
    for _ in range(20): p.drag(0, center("right")); p.advance(10)
    check(p, right=True, jump=True)
    p.touch(1, center("jump"), False); p.advance(100); check(p, right=True, jump=False)
    p.touch(0, center("right"), False); p.advance(100); check(p, right=False, jump=False); n += 1
    # 2) jump first, then right, then release right first
    p = Port(); p.touch(1, center("jump"), True); p.advance(200)
    p.touch(0, center("right"), True); p.advance(300); check(p, right=True, jump=True)
    p.touch(0, center("right"), False); p.advance(100); check(p, right=False, jump=True)
    p.touch(1, center("jump"), False); p.advance(100); check(p, jump=False); n += 1
    # 3) left + jump, then slide to right while jump stays down
    p = Port(); p.touch(0, center("left"), True); p.touch(1, center("jump"), True); p.advance(300)
    check(p, left=True, jump=True)
    p.drag(0, center("right")); p.advance(50); check(p, left=False, right=True, jump=True); n += 1
    # 4) right + jump + fire, release in the middle
    p = Port(); p.touch(0, center("right"), True); p.touch(1, center("jump"), True); p.touch(2, center("fire"), True)
    p.advance(300); check(p, right=True, jump=True, fire=True)
    p.touch(1, center("jump"), False); p.advance(100); check(p, right=True, jump=False, fire=True)
    p.touch(2, center("fire"), False); p.advance(100); check(p, right=True, fire=False); n += 1
    # 5) left + fire (run and shoot) then right + fire
    p = Port(); p.touch(0, center("left"), True); p.touch(1, center("fire"), True); p.advance(300)
    check(p, left=True, fire=True)
    p.touch(0, center("left"), False); p.advance(100); check(p, left=False, fire=True)
    p.touch(0, center("right"), True); p.advance(100); check(p, right=True, fire=True); n += 1
    # 6) very short jump tap while right is held
    p = Port(); p.touch(0, center("right"), True); p.advance(300)
    p.touch(1, center("jump"), True); p.advance(20); p.touch(1, center("jump"), False)
    check(p, jump=True, right=True); p.advance(60); check(p, jump=False, right=True); n += 1
    # 7) tap, release, tap again inside the grace period: fresh press, never stuck
    p = Port(); p.touch(1, center("jump"), True); p.advance(10); p.touch(1, center("jump"), False)
    p.advance(10); p.touch(1, center("jump"), True); p.advance(300); check(p, jump=True)
    p.touch(1, center("jump"), False); p.advance(200); check(p, jump=False); n += 1
    # 8) thumb drifts off the buttons: action stays held until the finger lifts
    p = Port(); p.touch(0, center("right"), True); p.advance(200)
    for _ in range(10): p.drag(0, (120.0, 40.0)); p.advance(10)
    check(p, right=True); p.touch(0, center("right"), False); p.advance(100); check(p, right=False); n += 1
    # 9) finger indices are reused after release
    p = Port(); p.touch(0, center("right"), True); p.advance(200); p.touch(0, center("right"), False); p.advance(100)
    p.touch(0, center("jump"), True); p.advance(200); check(p, jump=True, right=False)
    p.touch(0, center("jump"), False); p.advance(100); check(p, jump=False); n += 1
    # 10) two fingers on the same button: held until the last one lifts
    p = Port(); p.touch(0, center("jump"), True); p.advance(200); p.touch(1, center("jump"), True); p.advance(200)
    p.touch(0, center("jump"), False); p.advance(100); check(p, jump=True)
    p.touch(1, center("jump"), False); p.advance(100); check(p, jump=False); n += 1
    # 11) optional up/down buttons are independent of jump/left/right
    p = Port(); p.touch(0, center("up"), True); p.touch(1, center("right"), True); p.touch(2, center("down"), True)
    p.advance(300); check(p, up=True, right=True, down=True, jump=False)
    p.touch(0, center("up"), False); p.advance(100); check(p, up=False, right=True, down=True); n += 1
    print("touch-logic simulation: %d scenarios passed" % n)


if __name__ == "__main__":
    run()
