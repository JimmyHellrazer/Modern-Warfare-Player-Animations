p = "mpm_render.py"
s = open(p, encoding="utf-8").read()


def rep(a, b):
    global s
    assert a in s, a[:80]
    s = s.replace(a, b, 1)


rep('''  RIGHT "MW":  MW's raw skeleton from the source clip with the gun on j_gun * T(gt) (MW's own pose).''',
    '''  MIDDLE "MW": MW's raw skeleton from the source clip with the gun on j_gun * T(gt) (MW's own pose).
  RIGHT "GAME": what the game really showed - the photo booth's bone dump for that gun + state
        (garrysmod/data/mpm_booth/mg_<gun>_<state>.json; mpm_devtools), plus a per-bone table GAME vs MPM.''')

rep('''# ---------------------------------------------------------------- drawing''', '''# ---------------------------------------------------------------- in game (photo booth dumps)
BOOTH = ADDONS.replace("/addons", "/data/mpm_booth")
BOOTH_NAME = {"hold": "hold", "ads": "ads", "rel@0.3": "rel30", "rel@0.7": "rel70", "raise@0.5": "draw50",
              "rech@0.4": "bolt40"}
GAME_PARENT = {"Spine4": "Pelvis", "Neck1": "Spine4", "Head1": "Neck1"}
for _s in ("R", "L"):
    GAME_PARENT.update({f"{_s}_Clavicle": "Spine4", f"{_s}_UpperArm": f"{_s}_Clavicle",
                        f"{_s}_Forearm": f"{_s}_UpperArm", f"{_s}_Hand": f"{_s}_Forearm"})
    for _f in range(5):
        GAME_PARENT[f"{_s}_Finger{_f}"] = f"{_s}_Hand"
        GAME_PARENT[f"{_s}_Finger{_f}1"] = f"{_s}_Finger{_f}"
        GAME_PARENT[f"{_s}_Finger{_f}2"] = f"{_s}_Finger{_f}1"


def game_state(g, state):
    """(W, nodes, gun 4x4, dump) from the booth's dump, or None. Positions are in the dump's player frame."""
    import json
    name = BOOTH_NAME.get(state)
    path = os.path.join(BOOTH, f"mg_{g}_{name}.json") if name else None
    if not (path and os.path.exists(path)):
        return None
    t = json.load(open(path))
    W = {}
    for n, b in t["bones"].items():
        W["ValveBiped.Bip01_" + n] = PA(b["pos"] + b["ang"])
    names = list(W)
    nodes = []
    for n in names:
        par = GAME_PARENT.get(n[len("ValveBiped.Bip01_"):])
        nodes.append((n, names.index("ValveBiped.Bip01_" + par) if par and "ValveBiped.Bip01_" + par in W else -1))
    gb = t["gun"].get("tag_sling") or t["gun"].get("tag_pistol_offset")
    gun = PA(gb["pos"] + gb["ang"]) if gb else None
    return W, nodes, gun, t


CMP = ["R_Hand", "R_Forearm", "L_Hand", "L_Forearm", "R_Finger1", "R_Finger11", "R_Finger12", "L_Finger1"]


def compare(Wg, gg, Wm, gm):
    """GAME vs MPM in each one's torso frame: per-bone distance (u), gun origin distance and barrel angle."""
    Tg, Tm = np.linalg.inv(torso(Wg)), np.linalg.inv(torso(Wm))
    out = []
    for n in CMP:
        k = "ValveBiped.Bip01_" + n
        if k in Wg and k in Wm:
            out.append((n, float(np.linalg.norm((Tg @ Wg[k])[:3, 3] - (Tm @ Wm[k])[:3, 3]))))
    if gg is not None:
        a, b = Tg @ gg, Tm @ gm
        out.append(("gun origin", float(np.linalg.norm(a[:3, 3] - b[:3, 3]))))
        c = float(np.clip(a[:3, 0] @ b[:3, 0], -1, 1))
        out.append(("gun barrel deg", math.degrees(math.acos(c))))
    return out


# ---------------------------------------------------------------- drawing''')

rep('''def render(g, states, views=((15, -40), (5, -100))):
    e = entry(g)
    V, _info = wm_mesh(g)
    rows = len(states)
    fig = plt.figure(figsize=(4.2 * len(views) * 2, 4.2 * rows))
    k = 1
    for st in states:
        Wm, nm, gm, xm = mpm_state(g, e, st)
        Wr, nr, gr, xr = mw_state(g, e, st)''', '''def render(g, states, views=((15, -40), (5, -100))):
    e = entry(g)
    V, _info = wm_mesh(g)
    rows = len(states)
    cols = len(views) * 3
    fig = plt.figure(figsize=(4.2 * cols, 4.2 * rows))
    k = 1
    report = []
    for st in states:
        Wm, nm, gm, xm = mpm_state(g, e, st)
        Wr, nr, gr, xr = mw_state(g, e, st)
        game = game_state(g, st)''')
rep('''        for el, az in views:
            ax = fig.add_subplot(rows, len(views) * 2, k, projection="3d")
            draw(ax, Wm, nm, gm, V, f"MPM {g} {st}''', '''        for el, az in views:
            ax = fig.add_subplot(rows, cols, k, projection="3d")
            draw(ax, Wm, nm, gm, V, f"MPM {g} {st}''')
rep('''        for el, az in views:
            ax = fig.add_subplot(rows, len(views) * 2, k, projection="3d")
            draw(ax, Wr, nr, gr, V, f"MW  {g} {st}\\n{xr['src']}", rel=_info["rel"])
            ax.view_init(el, az)
            k += 1''', '''        for el, az in views:
            ax = fig.add_subplot(rows, cols, k, projection="3d")
            draw(ax, Wr, nr, gr, V, f"MW  {g} {st}\\n{xr['src']}", rel=_info["rel"])
            ax.view_init(el, az)
            k += 1
        cmp = None
        if game:
            Wg, ng, gg, t = game
            cmp = compare(Wg, gg, Wm, gm)
            report.append((st, cmp, t))
        for el, az in views:
            ax = fig.add_subplot(rows, cols, k, projection="3d")
            if game and gg is not None:
                worst = max(cmp, key=lambda x: x[1] if x[0] != "gun barrel deg" else 0)
                bar = dict(cmp).get("gun barrel deg", 0)
                draw(ax, Wg, ng, gg, V, f"GAME {g} {st}  (booth)\\nvs MPM: gun {dict(cmp).get('gun origin', 0):.1f}u {bar:.0f}deg, "
                     f"worst {worst[0]} {worst[1]:.1f}u", rel=_info["rel"])
            else:
                ax.set_title(f"GAME {g} {st}\\nno booth dump", fontsize=8)
                ax.set_xticks([]); ax.set_yticks([]); ax.set_zticks([])
            ax.view_init(el, az)
            k += 1''')
rep('''    fig.savefig(out, dpi=80)
    plt.close(fig)
    return out''', '''    fig.savefig(out, dpi=80)
    plt.close(fig)
    for st, cmp, t in report:
        m = t.get("mpm", {})
        print(f"  {g} {st:10s} GAME vs MPM: " + "  ".join(f"{n} {d:.1f}" for n, d in cmp)
              + f"   | in game: action {m.get('action')} letgo {m.get('letgo')} R-IK {m.get('right_ik')} "
                f"L-IK {m.get('left_ik')} hold {m.get('hold')} placement_error {t.get('placement_error_u')}")
    return out''')
rep('''    states = sys.argv[2:] or ["hold", "ads", "rel@0.4", "raise@0.6"]''',
    '''    states = sys.argv[2:] or ["hold", "ads", "rel@0.3", "rel@0.7", "raise@0.5"]''')
open(p, "w", encoding="utf-8").write(s)
print("ok")
