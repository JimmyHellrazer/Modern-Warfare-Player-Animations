"""Offline check of MPM's gun placement + hand IK against MW's own pose.

For a gun and a state (hold / ADS / an action at a cycle) it draws, side by side:
  LEFT  "MPM": the player skeleton from our built clip, the world-model mesh placed by cl_gun.lua's maths
        (hand * J * T(gt), let-go -> clavicle track), right hand IK onto MW's grip, left hand IK onto the grip tag.
  MIDDLE "MW": MW's raw skeleton from the source clip with the gun on j_gun * T(gt) (MW's own pose).
  RIGHT "GAME": what the game really showed - the photo booth's bone dump for that gun + state
        (garrysmod/data/mpm_booth/mg_<gun>_<state>.json; mpm_devtools), plus a per-bone table GAME vs MPM.
Usage: python mpm_render.py <gun> [state ...]   states: hold ads rel@0.5 emp@0.3 raise@0.8 ...
"""
import math
import os
import struct
import sys

import numpy as np

TOOLS = r"K:/mods map pics/smh_cod_anim_baker/tools"
sys.path.insert(0, TOOLS)
import runpy  # noqa: E402

import matplotlib  # noqa: E402
matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

import mpm_build as mb  # noqa: E402
import cod_to_breen as c2b  # noqa: E402
import tif_mw_build as tmb  # noqa: E402

ADDONS = r"K:/SteamLibrary/steamapps/common/GarrysMod/garrysmod/addons"
CLIPS_DIR = ADDONS + "/modern_player_motion/lua/mpm/data"
BUILD = "K:/jimmyproject/mpm/build/clips/"
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")
os.makedirs(OUT, exist_ok=True)

M = runpy.run_path("K:/jimmyproject/mpm/manifest.py")
_B = None


def builder():
    global _B
    if _B is None:
        _B = mb.Builder(M)
    return _B


_G = None


def guns():
    global _G
    if _G is None:
        import lupa.luajit21 as lj
        L = lj.LuaRuntime()
        names = sorted(f for f in os.listdir(CLIPS_DIR) if f.startswith("clips_p") and f.endswith(".lua")) or ["clips.lua"]
        L.execute("MPM={} " + chr(10).join(open(os.path.join(CLIPS_DIR, n), encoding="utf-8").read() for n in names))
        _G = L
    return _G


def entry(g):
    return guns().eval(f'MPM.Guns["{g}"]')


def lst(t):
    return [t[i + 1] for i in range(len(t))] if t is not None else None


def T(p):
    X = np.eye(4)
    X[:3, 3] = p
    return X


def PA(v):
    """[x y z p y r] -> 4x4"""
    X = np.eye(4)
    X[:3, :3] = mb.ang_matrix(*v[3:6])
    X[:3, 3] = v[:3]
    return X


# ---------------------------------------------------------------- world model mesh
def vvd_vertices(path):
    d = open(path, "rb").read()
    num_lods = struct.unpack_from("<i", d, 12)[0]
    lodv = struct.unpack_from("<8i", d, 16)
    nfix, fixstart, vstart = struct.unpack_from("<3i", d, 48)
    def vert(i):
        o = vstart + i * 48
        return struct.unpack_from("<3f", d, o + 16)
    if nfix:
        out = []
        for k in range(nfix):
            lod, src, n = struct.unpack_from("<3i", d, fixstart + k * 12)
            if lod >= 0:
                out += [vert(src + j) for j in range(n)]
        return np.array(out)
    return np.array([vert(i) for i in range(lodv[0])])


def wm_mesh(g):
    """(vertices in the placement bone's frame, info) of mg_<g>'s world model."""
    info = mb.wm_info(M, g)
    import glob
    import re
    f = glob.glob(ADDONS + f"/*/lua/weapons/mg_{g}/shared.lua")[0]
    s = open(f, encoding="utf-8", errors="replace").read()
    rel = re.search(r'SWEP\.WorldModel\s*=\s*(?:Model\()?\s*"([^"]+)"', s).group(1)
    mdl = glob.glob(ADDONS + "/*/" + rel)[0]
    V = vvd_vertices(mdl[:-4] + ".vvd")
    W = mb.mdl_bone_world(mdl)
    S = W[info["bone"]]
    Vh = (np.linalg.inv(S) @ np.c_[V, np.ones(len(V))].T).T[:, :3]
    if len(Vh) > 2500:
        Vh = Vh[np.linspace(0, len(Vh) - 1, 2500).astype(int)]
    return Vh, info


# ---------------------------------------------------------------- poses
def smd_pose(path, frame):
    smd = mb.prep.read_smd(path)
    mb.prep.fill_frames(smd)
    frame = min(frame, len(smd.frames) - 1)
    w = c2b.world_pose(smd.nodes, {i: mb.prep.to_rt(v) for i, v in smd.frames[frame][1].items()})
    names = [n for n, _ in smd.nodes]
    W = {}
    for i, n in enumerate(names):
        r, t = w[i]
        X = np.eye(4)
        X[:3, :3] = np.array(r)
        X[:3, 3] = t
        W[n] = X
    return W, smd.nodes, len(smd.frames)


def cod_pose(clip, frame, fps30=True):
    b = builder()
    src = mb.prep.read_seanim(tmb.src_path(M, clip))
    if abs((src["fps"] or 30) - 60) < 0.5:
        src = mb.resample_half(src)
    cod, _ = mb.prep.seanim_to_smd(src, b.ctx.src_body, b.ctx.mapping, True, mb.prep.CM_TO_INCH, inplace=True)
    mb.prep.fill_frames(cod)
    frame = min(frame, len(cod.frames) - 1)
    w = c2b.world_pose(cod.nodes, {i: mb.prep.to_rt(v) for i, v in cod.frames[frame][1].items()})
    W = {}
    for i, (n, _p) in enumerate(cod.nodes):
        r, t = w[i]
        X = np.eye(4)
        X[:3, :3] = np.array(r)
        X[:3, 3] = t
        W[n] = X
    return W, cod.nodes


def track_at(trk, c, frames, k=6):
    n = len(trk) // k
    x = c * (frames - 1) / 2
    i = max(0, min(int(math.floor(x)), n - 1))
    j = min(i + 1, n - 1)
    f = max(0.0, min(1.0, x - i))
    a, b = np.array(trk[i * k:i * k + k]), np.array(trk[j * k:j * k + k])
    return list(a + (b - a) * f) if k > 1 else float(a[0] + (b[0] - a[0]) * f)


# ---------------------------------------------------------------- IK (same two-bone solve as cl_gun.lua, positions)
ARM = {"R": ("ValveBiped.Bip01_R_UpperArm", "ValveBiped.Bip01_R_Forearm", "ValveBiped.Bip01_R_Hand"),
       "L": ("ValveBiped.Bip01_L_UpperArm", "ValveBiped.Bip01_L_Forearm", "ValveBiped.Bip01_L_Hand")}


def solve_arm(W, side, target, w):
    u, f, h = ARM[side]
    S, E, H = W[u][:3, 3], W[f][:3, 3], W[h][:3, 3]
    Tg = H + (target - H) * w
    a, b = np.linalg.norm(E - S), np.linalg.norm(H - E)
    d = np.clip(np.linalg.norm(Tg - S), abs(a - b) + 0.01, a + b - 0.01)
    dr = (Tg - S) / max(np.linalg.norm(Tg - S), 1e-6)
    pole = (E - S) - dr * np.dot(E - S, dr)
    if np.linalg.norm(pole) < 1e-4:
        return
    pole /= np.linalg.norm(pole)
    cA = np.clip((a * a + d * d - b * b) / (2 * a * d), -1, 1)
    newE = S + dr * a * cA + pole * a * math.sqrt(1 - cA * cA)
    W[f] = W[f].copy()
    W[f][:3, 3] = newE
    W[h] = W[h].copy()
    W[h][:3, 3] = S + dr * d


# ---------------------------------------------------------------- MPM runtime emulation (cl_gun.lua GunWorld + solve)
def mpm_state(g, e, state):
    """returns (W pose after IK, gun 4x4 (placement bone), label, extras)"""
    kind, _, cyc = state.partition("@")
    cyc = float(cyc or 0)
    st = "stand"
    if kind in ("hold", "ads"):
        path = BUILD + f"h_{g}_{st}_{'ads' if kind == 'ads' else 'nonads'}.smd"
        W, nodes, _n = smd_pose(path, 0)
        J = PA(lst(e["gunads_" + st] if kind == "ads" and e["gunads_" + st] else e["gunhold_" + st]))
        act = None
        lg = 0.0
        actw = 0.0
    else:
        act = e[f"{kind}_{st}"]
        path = BUILD + act["seq"][4:] + ".smd"
        smd_n = len(mb.prep.read_smd(path).frames)
        W, nodes, _n = smd_pose(path, round(cyc * (smd_n - 1)))
        frames = math.floor(act["dur"] * 30 + 1.5)
        J = PA(track_at(lst(act["gun"]), cyc, frames))
        lg = track_at(lst(act["lg"]), cyc, frames, 1) if act["lg"] else 0.0
        actw = 1.0
    H = W["ValveBiped.Bip01_R_Hand"]
    gunJ = H @ J
    if act is not None and act["gunc"] and lg > 0.5:
        frames = math.floor(act["dur"] * 30 + 1.5)
        gunJ = W["ValveBiped.Bip01_R_Clavicle"] @ PA(track_at(lst(act["gunc"]), cyc, frames))
    gt = np.array(lst(e["gt"]))
    gun = gunJ @ T(gt)
    # right hand onto MW's grip
    if e["jg"] and (1 - lg) > 0.01 and not (act is not None and kind == "rech"):
        hand = gun @ T(-gt) @ np.linalg.inv(PA(lst(e["jg"])))
        if np.linalg.norm(hand[:3, 3] - H[:3, 3]) < 14:
            solve_arm(W, "R", hand[:3, 3], 1 - lg)
    # left hand onto the grip tag (bind pose, relative to the placement bone) / magwell spot
    _V, info = wm_mesh(g)
    lt = None
    if e["lhg"]:
        lt = (gun @ T(np.array(lst(e["lhg"]))))[:3, 3]
    elif "tag_ik_loc_le" in info["rel"]:
        lt = (gun @ info["rel"]["tag_ik_loc_le"])[:3, 3]
    lw = 0.0
    if lt is not None:
        d = np.linalg.norm(W["ValveBiped.Bip01_L_Hand"][:3, 3] - lt)
        lw = 1 - np.clip((d - 8) / 8, 0, 1)
        if act is not None:
            n = act["notes"]
            if n and n["ikout"] and n["ikin"]:
                if n["ikout"] <= cyc < n["ikin"]:
                    lw = 0
        if lw > 0.01:
            solve_arm(W, "L", lt, lw)
    return W, nodes, gun, {"lg": lg, "lw": lw, "lt": lt, "src": act["from"] if act else path}


def mw_state(g, e, state):
    kind, _, cyc = state.partition("@")
    cyc = float(cyc or 0)
    if kind in ("hold", "ads"):
        # MW's grip at rest: the end frame of its reload (back on the idle)
        act, cyc = e["rel_stand"], 1.0
    else:
        act = e[f"{kind}_stand"]
    clip = act["from"]
    src = mb.prep.read_seanim(tmb.src_path(M, clip))
    nfr = src["frames"] if abs((src["fps"] or 30) - 60) > 0.5 else math.ceil(src["frames"] / 2)
    W, nodes = cod_pose(clip, round(cyc * (nfr - 1)))
    gun = W["j_gun"] @ T(np.array(lst(e["gt"])))
    return W, nodes, gun, {"src": clip}


# ---------------------------------------------------------------- in game (photo booth dumps)
BOOTH = ADDONS.replace("/addons", "/data/mpm_booth")
BOOTH_NAME = {"hold": "hold", "ads": "ads", "rel@0.3": "rel30", "rel@0.7": "rel70", "raise@0.5": "draw50", "raise@0.95": "draw95",
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


# ---------------------------------------------------------------- drawing
BODY_SKIP = ("Finger", "Anim_Attachment", "Pelvis_orig")


def torso(W):
    """4x4 world <- torso frame (x forward, y left, z up, origin Spine4) from bone POSITIONS (rig independent)."""
    P = lambda n: W[n][:3, 3]
    up = P("ValveBiped.Bip01_Neck1") - P("ValveBiped.Bip01_Pelvis")
    up /= np.linalg.norm(up)
    left = P("ValveBiped.Bip01_L_Clavicle") - P("ValveBiped.Bip01_R_Clavicle")
    left -= up * np.dot(left, up)
    left /= np.linalg.norm(left)
    fwd = np.cross(left, up)
    X = np.eye(4)
    X[:3, 0], X[:3, 1], X[:3, 2], X[:3, 3] = fwd, left, up, P("ValveBiped.Bip01_Spine4")
    return X


def draw(ax, W, nodes, gun, V, title, extra=None, center=None, rel=None):
    names = [n for n, _ in nodes]
    TI = np.linalg.inv(torso(W))
    W = {n: TI @ X for n, X in W.items()}
    gun = TI @ gun
    if extra and extra.get("lt") is not None:
        extra = dict(extra, lt=(TI @ np.append(extra["lt"], 1))[:3])
    c = np.zeros(3)
    # the gun's outline from its tags: bore line (stock -> muzzle), magazine (down from the mag well), grip tags
    if rel:
        def tp(n):
            return (gun @ rel[n])[:3, 3] if n in rel else None
        a = tp("tag_stock_attach")
        if a is None:
            a = (gun @ T([-8, 0, 0]))[:3, 3]
        b = tp("tag_flash")
        if b is None and "tag_barrel_attach" in rel:
            b = (gun @ rel["tag_barrel_attach"] @ T([12, 0, 0]))[:3, 3]
        if b is not None:
            ax.plot(*np.c_[a, b], color="k", lw=4)
        m = tp("tag_mag_attach")
        if m is not None:
            m2 = (gun @ rel["tag_mag_attach"] @ T([0, 0, -6]))[:3, 3]
            ax.plot(*np.c_[m, m2], color="saddlebrown", lw=4)
        for tg, col in (("tag_ik_loc_ri", "orange"), ("tag_ik_loc_le", "cyan")):
            q = tp(tg)
            if q is not None:
                ax.scatter(*q, color=col, s=35, marker="D")
    for i, (n, p) in enumerate(nodes):
        if p < 0 or n not in W or names[p] not in W or any(s in n for s in BODY_SKIP) or not n.startswith("ValveBiped"):
            continue
        a, b = W[names[p]][:3, 3] - c, W[n][:3, 3] - c
        col = "tab:red" if "_R_" in n else ("tab:blue" if "_L_" in n else "0.35")
        ax.plot([a[0], b[0]], [a[1], b[1]], [a[2], b[2]], color=col, lw=2)
    for side, col in (("R", "darkred"), ("L", "navy")):
        h = W[f"ValveBiped.Bip01_{side}_Hand"]
        p = h[:3, 3] - c
        ax.scatter(*p, color=col, s=40)
        tip = p + h[:3, 0] * 3.5  # hand +x toward the knuckles
        ax.plot([p[0], tip[0]], [p[1], tip[1]], [p[2], tip[2]], color=col, lw=3)
    P = (gun @ np.c_[V, np.ones(len(V))].T).T[:, :3] - c
    ax.scatter(P[:, 0], P[:, 1], P[:, 2], s=0.4, color="0.2", alpha=0.5)
    if extra and extra.get("lt") is not None:
        q = extra["lt"] - c
        ax.scatter(*q, color="lime", s=50, marker="x")
    ax.set_title(title, fontsize=8)
    r = 20
    ax.set_xlim(-r, r)
    ax.set_ylim(-r, r)
    ax.set_zlim(-r, r)
    ax.set_box_aspect((1, 1, 1))
    ax.set_xticks([])
    ax.set_yticks([])
    ax.set_zticks([])


def render(g, states, views=((15, -40), (5, -100))):
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
        game = game_state(g, st)
        for el, az in views:
            ax = fig.add_subplot(rows, cols, k, projection="3d")
            draw(ax, Wm, nm, gm, V, f"MPM {g} {st}\nlg {xm['lg']:.2f} L-IK {xm['lw']:.2f}", xm, rel=_info["rel"])
            ax.view_init(el, az)
            k += 1
        for el, az in views:
            ax = fig.add_subplot(rows, cols, k, projection="3d")
            draw(ax, Wr, nr, gr, V, f"MW  {g} {st}\n{xr['src']}", rel=_info["rel"])
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
                draw(ax, Wg, ng, gg, V, f"GAME {g} {st}  (booth)\nvs MPM: gun {dict(cmp).get('gun origin', 0):.1f}u {bar:.0f}deg, "
                     f"worst {worst[0]} {worst[1]:.1f}u", rel=_info["rel"])
            else:
                ax.set_title(f"GAME {g} {st}\nno booth dump", fontsize=8)
                ax.set_xticks([]); ax.set_yticks([]); ax.set_zticks([])
            ax.view_init(el, az)
            k += 1
    fig.tight_layout()
    out = os.path.join(OUT, f"{g}.png")
    fig.savefig(out, dpi=80)
    plt.close(fig)
    for st, cmp, t in report:
        m = t.get("mpm", {})
        print(f"  {g} {st:10s} GAME vs MPM: " + "  ".join(f"{n} {d:.1f}" for n, d in cmp)
              + f"   | in game: action {m.get('action')} letgo {m.get('letgo')} R-IK {m.get('right_ik')} "
                f"L-IK {m.get('left_ik')} hold {m.get('hold')} placement_error {t.get('placement_error_u')}")
    return out


if __name__ == "__main__":
    g = sys.argv[1]
    states = sys.argv[2:] or ["hold", "ads", "rel@0.3", "rel@0.7", "raise@0.5"]
    print(render(g, states))
