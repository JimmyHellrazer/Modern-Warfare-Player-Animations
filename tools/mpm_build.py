"""
Build MW19/MW22 player animations for Modern Player Motion (addons/modern_player_motion).

Every clip goes through the same conversion as TIF (tif_mw_build.build_clip: SEAnim -> CoD rig SMD -> ValveBiped /
Breen retarget, in place, feet centred on the origin). What differs is the output:

  * one animation model, models/mpm/mpm_anims.mdl, with
      - 8-way direction blends per gait on the pose parameters mpm_mx (forward +) / mpm_my (left +),
        centre = a held stance pose (studiomdl blend grid, numpad directions: 8 fwd, 2 back, 4 left, 6 right)
      - forward-only 3-way blends (sprint / tac sprint: 9 8 7) on mpm_my
      - plain sequences (idles, one-shots)
    Sequence names start with "mpm_" so they can't clash with HL2's in m_anm.mdl.
  * patched copies of the game's models/m_anm.mdl and f_anm.mdl with one $includemodel added
    (models/mpm/mpm_anims.mdl). Every ValveBiped playermodel includes m_anm / f_anm, and Source's virtual model
    follows includes recursively, so every playermodel gets the MPM sequences, on the client and the server (hitboxes).
    HL2's own sequences are untouched: the original bytes are copied and one include record is appended.
  * lua/mpm/data/clips.lua: per sequence / direction the measured ground speed, travel direction, duration and foot
    plants (0..1 of the cycle) for the anim graph (stride sync, stop foot choice).

Usage:
  python mpm_build.py <manifest.py> [--compile] [--no-patch]
Manifest: SOURCE, EXTRA_SOURCES, FIX_FIRST_KEY, BUILD, ADDON, plus
  BLEND8 = { name: (clip_fmt with {} = numpad dir, centre_clip) }
  FWD3   = { name: clip_fmt }                 (dirs 7 8 9)
  SINGLE = { name: (clip, {"loop": bool}) }
"""

import argparse
import copy
import math
import re
import os
import runpy
import shutil
import struct
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import cod_anim_prep as prep  # noqa: E402
import tif_mw_build as tmb  # noqa: E402

# MPM converts MULTIPLAYER clips: use the decoded MP gun chain (clavicle -> j_gun_adjust -> j_gun) instead of the AI fit
prep.MP_GUN = prep.MP_GUN_FIT
# MWII exports rig the gun with other rests: tag every clip read from an iw9_ file so seanim_to_smd picks its fit
_read_seanim = prep.read_seanim


def _read_seanim_rig(path):
    anim = _read_seanim(path)
    if os.path.basename(path).lower().startswith("iw9_"):
        anim["rig"] = "iw9"
    return anim


prep.read_seanim = _read_seanim_rig

FPS = 30
PX, PY = "mpm_mx", "mpm_my"  # forward +, left +
AY, AP = "mpm_ay", "mpm_ap"  # aim yaw (+ left of the body) / aim pitch (+ down), degrees
ADS = "mpm_ads"              # 0 hip .. 1 aiming down sights (crossfades the hip / ADS aim layers)
AIM_GRID = (-90, -45, 0, 45, 90)
DIRVEC = {8: (1, 0), 2: (-1, 0), 4: (0, 1), 6: (0, -1), 7: (1, 1), 9: (1, -1), 1: (-1, 1), 3: (-1, -1)}
# studiomdl blend grid: first blend parameter = columns, second = rows (checked on TIF's aim blends).
# rows mx -1..1 (back, middle, fwd), columns my -1..1 (right, middle, left); 0 = the centre pose.
GRID = [3, 2, 1, 6, 0, 4, 9, 8, 7]
FILL = {1: (2, 4), 3: (2, 6), 7: (8, 4), 9: (8, 6), 2: (1, 3), 4: (7, 1), 6: (9, 3), 8: (7, 9)}

GAMEDIR = tmb.GAMEDIR
VPK = os.path.join(GAMEDIR, "garrysmod_dir.vpk")
INCLUDE = "models/mpm/mpm_anims.mdl"


# --- VPK + MDL include patch ----------------------------------------------------------------------------------------

def vpk_get(path, name):
    """One file's bytes out of a Valve VPK (v1/v2 directory + numbered archives)."""
    with open(path, "rb") as f:
        _sig, ver, _tree = struct.unpack("<III", f.read(12))
        if ver == 2:
            f.read(16)

        def cstr():
            b = bytearray()
            while True:
                c = f.read(1)
                if c in (b"\0", b""):
                    return b.decode("latin1")
                b += c

        want = None
        while want is None:
            ext = cstr()
            if not ext:
                break
            while True:
                d = cstr()
                if not d:
                    break
                while True:
                    n = cstr()
                    if not n:
                        break
                    _crc, pre, arch, off, ln, _term = struct.unpack("<IHHIIH", f.read(18))
                    pdata = f.read(pre)
                    if f"{d}/{n}.{ext}" == name:
                        want = (arch, off, ln, pdata)
        end = f.tell()
    if want is None:
        raise FileNotFoundError(name)
    arch, off, ln, pdata = want
    if arch == 0x7FFF:
        src, off = path, end + off
    else:
        src = path.replace("_dir.vpk", "_%03d.vpk" % arch)
    with open(src, "rb") as f:
        f.seek(off)
        return pdata + f.read(ln)


H_LENGTH, H_NUMINCL, H_INCLINDEX = 76, 336, 340


def mdl_includes(b):
    n, idx = struct.unpack_from("<ii", b, H_NUMINCL)
    out = []
    for i in range(n):
        base = idx + i * 8
        _lab, nm = struct.unpack_from("<ii", b, base)
        out.append(b[base + nm:].split(b"\0")[0].decode())
    return out


def add_include(b, name):
    """The MDL with one more $includemodel. Existing include records are copied next to the new one at the end of the
    file (records must be contiguous); every other offset stays valid because nothing before the end moves."""
    b = bytearray(b)
    old = mdl_includes(b)
    if name in old:
        return bytes(b)
    names = old + [name]
    while len(b) % 4:
        b.append(0)
    start = len(b)
    recs = len(names) * 8
    strings = bytearray()
    offs = []
    for n in names:
        lab = len(strings)
        strings += b"\0"  # empty label
        nm = len(strings)
        strings += n.encode() + b"\0"
        offs.append((lab, nm))
    block = bytearray()
    for i, (lab, nm) in enumerate(offs):
        rec = start + i * 8
        block += struct.pack("<ii", start + recs + lab - rec, start + recs + nm - rec)
    b += block + strings
    while len(b) % 4:
        b.append(0)
    struct.pack_into("<ii", b, H_NUMINCL, len(names), start)
    struct.pack_into("<i", b, H_LENGTH, len(b))
    assert mdl_includes(bytes(b)) == names
    return bytes(b)


def patch_anm(addon):
    out = os.path.join(addon, "models")
    os.makedirs(out, exist_ok=True)
    for name in ("m_anm.mdl", "f_anm.mdl"):
        src = vpk_get(VPK, f"models/{name}")
        dst = add_include(src, INCLUDE)
        with open(os.path.join(out, name), "wb") as f:
            f.write(dst)
        print(f"patched {name}: {len(src)} -> {len(dst)} bytes, includes {mdl_includes(dst)}")


def mat_angles(m):
    """Rotation matrix (columns forward / left / up) -> Source QAngle (pitch, yaw, roll) degrees."""
    fx, fy, fz = m[0][0], m[1][0], m[2][0]
    lz, uz = m[2][1], m[2][2]
    return (math.degrees(math.atan2(-fz, math.hypot(fx, fy))), math.degrees(math.atan2(fy, fx)),
            math.degrees(math.atan2(lz, uz)))


GUN_CLIP_VER = 3  # (v0.10.0 adds data only; converted clips unchanged)  # bump when gun-action conversion changes outside cod_anim_prep / tif_mw_build (v2: finger overlay)
_BODY = None
MAG_PARK = 12.0  # u: a mag this far from its seat that isn't moving is parked (pouch / dropped) -> hidden
MAG_FAR = 30.0   # u: a mag further than this is never in a hand (MW parks some hundreds of units away mid-move)
PART_SKIP = ("j_gun", "j_gun_adjust")
NO_MAGS = ("raise", "draw", "drawc", "hol", "holc", "rech", "fire", "fireads")  # actions whose mags stay seated


_WEAPON_BONES = None


def weapon_model_bones(m):
    """Every j_ bone name on MW Base's weapon / attachment models (only those can be driven at runtime)."""
    global _WEAPON_BONES
    if _WEAPON_BONES is None:
        import glob as _glob
        root = os.path.dirname(os.path.normpath(m["ADDON"]))
        names = set()
        for pat in ("modern_warfare_2019_sweps_*", "modern_wokefare_base_*"):
            for f in _glob.glob(os.path.join(root, pat, "models", "**", "*.mdl"), recursive=True):
                with open(f, "rb") as fh:
                    names |= {x.decode("ascii", "replace") for x in fh.read().split(bytes(1)) if x.startswith(b"j_")}
        _WEAPON_BONES = names
    return _WEAPON_BONES


def part_tracks(m, clip, body, step=2, mags=True, native=False):
    """MW's own gun-part motion in a clip (mags, 725 break barrel, LMG lid / cover / belt rounds, bolts, charging
    handles ...): {bone: {"p": [x y z ...], "a": [p y r ...], "v": [0/1 ...]}} every `step` frames at 30 fps. "p" =
    offset from the part's seat (parent space, inches), "a" = the part's ABSOLUTE local angle (MW's keys; the runtime
    plays rest^-1 * a against the world model's own rest), "v" (mags only) = 0 while parked away from the gun. MW Base's
    world models carry the same bones (its attachment models bonemerge onto them), so these play as manipulations."""
    try:
        anim = prep.read_seanim(tmb.src_path(m, clip))
    except Exception:  # noqa: BLE001
        return None
    if abs((anim["fps"] or 30) - 60) < 0.5 and not native:
        anim = resample_half(anim)
    n = max(2, anim["frames"])
    idx = list(range(0, n, step))
    if idx[-1] != n - 1:
        idx.append(n - 1)
    out = {}
    for b, k in anim["bones"].items():
        if b in body or not b.startswith("j_") or b in PART_SKIP or b not in weapon_model_bones(m):
            continue
        is_mag = b.startswith("j_mag") and b[5:].isdigit()
        if is_mag and not mags:
            continue
        rot, loc = k.get("rot") or [], k.get("loc") or []
        if len(rot) < 2 and len(loc) < 2:
            continue
        pts = [[v * prep.CM_TO_INCH for v in prep.sample_keys(loc, f, prep.vlerp)] if loc else [0.0, 0.0, 0.0]
               for f in range(n)]
        qs = [prep.sample_keys(rot, f, prep.slerp) if rot else [0, 0, 0, 1] for f in range(n)]
        moved = max(math.dist(pts[f], pts[0]) for f in range(n))
        turned = max(math.degrees(2 * math.acos(min(1.0, abs(sum(x * y for x, y in zip(qs[0], q)))))) for q in qs)
        if moved < 0.15 and turned < 2:
            continue
        tr = {}
        if moved >= 0.15:
            tr["p"] = [round(v, 2) for f in idx for v in pts[f]]
        if turned >= 2 or (rot and is_mag):
            tr["a"] = [round(v, 1) for f in idx for v in mat_angles(prep.quat_to_matrix(qs[f]))]
        if is_mag:
            vis = []
            for f in idx:
                d = math.hypot(*pts[f])
                still = all(math.dist(pts[f], pts[j]) < 0.3 for j in (max(0, f - 2), min(n - 1, f + 2)))
                vis.append(0 if d > MAG_FAR or (d > MAG_PARK and still) else 1)
            tr["v"] = vis
        out[b] = tr
    return out or None


def smd_angles(rx, ry, rz):
    """SMD euler (radians) -> Source QAngle (pitch, yaw, roll) degrees, via the rotation matrix's axes."""
    m = prep.euler_to_matrix(rx, ry, rz)
    fx, fy, fz = m[0][0], m[1][0], m[2][0]
    lz, uz = m[2][1], m[2][2]
    pitch = math.degrees(math.atan2(-fz, math.hypot(fx, fy)))
    yaw = math.degrees(math.atan2(fy, fx))
    roll = math.degrees(math.atan2(lz, uz))
    return pitch, yaw, roll


def gun_track(path, step=2):
    """j_gun's local transform under the right hand per `step` frames of a built SMD (cod_to_breen keeps j_gun parented
    to the right hand with MW's grip), as a flat list x y z p y r ... (inches / degrees, Source angles). This is MW's
    own gun motion: during reloads / bolt pulls the gun moves relative to the hand exactly as MW animated it."""
    smd = prep.read_smd(path)
    names = [n for n, _ in smd.nodes]
    if "j_gun" not in names:
        return None
    prep.fill_frames(smd)
    gi = names.index("j_gun")
    out = []
    fr = smd.frames
    idx = list(range(0, len(fr), step))
    if idx[-1] != len(fr) - 1:
        idx.append(len(fr) - 1)
    for i in idx:
        v = fr[i][1][gi]
        p, y, r = smd_angles(v[3], v[4], v[5])
        out += [round(v[0], 2), round(v[1], 2), round(v[2], 2), round(p, 1), round(y, 1), round(r, 1)]
    return out


def left_in_right(path):
    """Where the left hand sits in the right hand's frame (x y z inches) in frame 0 of a built SMD: the hold's
    two-handed grip. Pistols' MW Base world models have no tag_ik_loc_le, so the runtime pins the left hand here."""
    import cod_to_breen as c2b
    smd = prep.read_smd(path)
    names = [n for n, _ in smd.nodes]
    if "ValveBiped.Bip01_L_Hand" not in names or "ValveBiped.Bip01_R_Hand" not in names:
        return None
    prep.fill_frames(smd)
    w = c2b.world_pose(smd.nodes, {i: prep.to_rt(v) for i, v in smd.frames[0][1].items()})
    (rr, rt), (_lr, lt) = w[names.index("ValveBiped.Bip01_R_Hand")], w[names.index("ValveBiped.Bip01_L_Hand")]
    d = [lt[k] - rt[k] for k in range(3)]
    return [round(sum(rr[r][c] * d[r] for r in range(3)), 2) for c in range(3)]  # R^T d


# --- gun rework (v0.10.0): MW's real grip, body-anchored gun, hand / finger targets ---------------------------------
# MW Base's world models are MW's own gun models: their frame (tag_sling / tag_pistol_offset, identity under the hand
# bone) has j_gun's axes (checked on 50 guns: the right AND left grip tags land on MW's hands within 1-2 u after one
# translation), so the gun is placed as hand * J * T(gt): J = MW's j_gun under the right hand (the clip), gt = where the
# world model's origin sits in j_gun's frame, solved per gun so MW's right wrist lands on the model's tag_ik_loc_ri.
# Guns without that tag: estimated from the ejection port (tag_brass) - pistols with a pistol grip offset.
RI_FROM_BRASS = {"pi": (-3.7, -1.2, -4.0), "_": (-8.12, -0.54, -4.17)}
R_FINGERS = [f"ValveBiped.Bip01_R_Finger{a}{b}" for a in range(5) for b in ("", "1", "2")]
L_FINGERS = [f"ValveBiped.Bip01_L_Finger{a}{b}" for a in range(5) for b in ("", "1", "2")]
_WM = {}


def _np():
    import numpy as np
    return np


def mdl_bone_world(path):
    """{bone: 4x4 model-space matrix} of a compiled .mdl's bind pose (studiohdr bones)."""
    import struct
    np = _np()
    d = open(path, "rb").read()
    n, bi = struct.unpack_from("<ii", d, 0x9c)
    out, W = {}, []
    for i in range(n):
        o = bi + i * 216
        sz, par = struct.unpack_from("<ii", d, o)
        name = d[o + sz:d.index(b"\0", o + sz)].decode("ascii", "replace")
        pos = struct.unpack_from("<3f", d, o + 32)
        x, y, z, w = struct.unpack_from("<4f", d, o + 44)
        m = np.eye(4)
        m[:3, :3] = [[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
                     [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
                     [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]]
        m[:3, 3] = pos
        W.append(W[par] @ m if par >= 0 else m)
        out[name] = W[-1]
    return out


def wm_info(m, g):
    """MW Base world model of mg_<g>: {"bone": placement bone, "rel": {bone: matrix in that bone's frame}} or None."""
    if g in _WM:
        return _WM[g]
    import glob as _glob
    import re
    np = _np()
    _WM[g] = None
    root = os.path.dirname(os.path.normpath(m["ADDON"]))
    for f in _glob.glob(os.path.join(root, "*", "lua", "weapons", f"mg_{g}", "shared.lua")):
        src = open(f, encoding="utf-8", errors="replace").read()
        mm = re.search(r'SWEP\.WorldModel\s*=\s*(?:Model\()?\s*"([^"]+)"', src)
        if not mm:
            continue
        bm = re.search(r'WorldModelOffsets\s*=\s*\{[^}]*?Bone\s*=\s*"([^"]+)"', src, re.S)
        hits = _glob.glob(os.path.join(root, "*", mm.group(1)))
        if not hits:
            continue
        bones = mdl_bone_world(hits[0])
        bone = bm.group(1) if bm else "tag_sling"
        if bone not in bones:
            bone = next((b for b in ("tag_sling", "tag_pistol_offset") if b in bones), None)
        if not bone:
            break
        inv = np.linalg.inv(bones[bone])
        _WM[g] = {"bone": bone, "rel": {n: inv @ M for n, M in bones.items()}}
        break
    return _WM[g]


def smd_world(path, frames=None):
    """[(frame index, {bone name: 4x4 world})] of a built SMD."""
    import cod_to_breen as c2b
    np = _np()
    smd = prep.read_smd(path)
    prep.fill_frames(smd)
    names = [n for n, _ in smd.nodes]
    out = []
    for f in (frames if frames is not None else range(len(smd.frames))):
        f = min(f, len(smd.frames) - 1)
        w = c2b.world_pose(smd.nodes, {i: prep.to_rt(v) for i, v in smd.frames[f][1].items()})
        d = {}
        for i, nm in enumerate(names):
            r, t = w[i]
            M = np.eye(4)
            M[:3, :3] = np.array(r)
            M[:3, 3] = t
            d[nm] = M
        out.append((f, d))
    return out


# bullpups: the grip sits ahead of the ejection port, the brass estimate doesn't hold
BULLPUPS = ("lima86", "augolf", "sbeta", "tango21", "falpha", "papa90")


def mw_grip(smds):
    """MW's real grip from the END frames of a gun's actions (reload / empty / inspect / raise: the hand back on the
    gun, mocap): (R, L) = MW's wrists in j_gun's frame (median), J = j_gun under the right hand (4x4), or None.
    (v0.10.0 read the HOLD clip: its wrist bends ~24 deg against the gun - the idle / action jumps.)"""
    np = _np()
    Rs, Ls, Js, JLs = [], [], [], []
    rig = "mw"
    for p in smds:
        if not os.path.exists(p):
            continue
        n = len(prep.read_smd(p).frames) - 1
        w = smd_world(p, [n])[0][1]
        if "j_gun" not in w:
            continue
        Gi = np.linalg.inv(w["j_gun"])
        H = w["ValveBiped.Bip01_R_Hand"]
        Rs.append((Gi @ H[:, 3])[:3])
        Ls.append((Gi @ w["ValveBiped.Bip01_L_Hand"][:, 3])[:3])
        Js.append(np.linalg.inv(H) @ w["j_gun"])
        JLs.append(Gi @ w["ValveBiped.Bip01_L_Hand"])  # MW's left hand on the gun (pos + rotation), j_gun frame
        if (_cache_src(p) or "").startswith("iw9_"):
            rig = "iw9"
    if not Rs:
        return None
    R, L = np.median(Rs, axis=0), np.median(Ls, axis=0)
    # the J closest to the median grip (a real frame, not an average of rotations)
    k = int(np.argmin([np.linalg.norm(np.linalg.inv(J)[:3, 3] - R) for J in Js]))
    return R, L, Js[k], rig, JLs[k]


def gun_calib(m, g, cls, grip):
    """gt (x y z: the world model origin in j_gun's frame) + whether it's estimated, or None. grip = mw_grip().
    Every sane calibration puts the origin 3.5-8.5 u to the side of j_gun (the MP rig's constant); outside that the model
    frame or the clip's rig doesn't match (AUG / mike14 from MWII came out at 0 / -1) and the gun keeps the old placement."""
    r = _gun_calib(m, g, cls, grip)
    # (MWII's rig has its gun bone elsewhere on the gun: its guns calibrate near y 0 - only MW19 values are checked)
    if r and grip[3] == "mw" and not 3.5 <= r[0][1] <= 8.5:
        return None
    return r


def _gun_calib(m, g, cls, grip):
    np = _np()
    info = wm_info(m, g)
    if not info or not grip:
        return None
    R, L = grip[0], grip[1]
    rel = info["rel"]
    if "tag_ik_loc_ri" in rel:
        tR = R - rel["tag_ik_loc_ri"][:3, 3]
        if "tag_ik_loc_le" in rel:
            tL = L - rel["tag_ik_loc_le"][:3, 3]
            # the two grip tags must agree across the gun (a turned model frame - the slima - doesn't): else no calib
            if float(np.hypot(*(tR - tL)[1:])) > 4.0:
                return None
            return [round(float(v), 2) for v in (tR + tL) / 2], False
        return [round(float(v), 2) for v in tR], False
    if cls == "pi" and MW_GT and "tag_brass" in rel:
        # pistols (no grip tags): sideways from MW's own attach offset (the tag-calibrated MW19 guns cluster there; the
        # ejection-port estimate left the right hand to the RIGHT of the pistol), forward / height still from the
        # ejection port (MW's full offset pushed the pistol forward of the hand - user, v0.10.4)
        ri = rel["tag_brass"][:3, 3] + np.array(RI_FROM_BRASS["pi"])
        est = R - ri
        return [round(float(est[0]), 2), MW_GT[1], round(float(est[2]), 2)], True
    if "tag_brass" in rel and g not in BULLPUPS:
        ri = rel["tag_brass"][:3, 3] + np.array(RI_FROM_BRASS["pi" if cls == "pi" else "_"])
        return [round(float(v), 2) for v in (R - ri)], True
    return None


MW_GT = None  # median gt of the tag-calibrated MW19-rig guns (set by Builder.guns before the pistols are calibrated)


def ang_matrix(p, y, r):
    """Source angles -> 3x3 rotation (columns forward / left / up)."""
    np = _np()
    p, y, r = map(math.radians, (p, y, r))
    cp, sp, cy, sy, cr, sr = math.cos(p), math.sin(p), math.cos(y), math.sin(y), math.cos(r), math.sin(r)
    f = [cp * cy, cp * sy, -sp]
    rt = [-sr * sp * cy + cr * sy, -sr * sp * sy - cr * cy, -sr * cp]
    u = [cr * sp * cy + sr * sy, cr * sp * sy - sr * cy, cr * cp]
    return np.column_stack([f, [-x for x in rt], u])


def letgo_track(gun, J):
    """Per gun-track sample: 0 = MW's gun in the right hand (its real grip J), 1 = the hand has let go (LMG lids,
    charging handles, the 725's reload, draws from the back): position > 2 u or rotation > 12 deg off the grip."""
    np = _np()
    n = len(gun) // 6
    jp, jr = J[:3, 3], J[:3, :3]
    raw = []
    for i in range(n):
        v = gun[i * 6:i * 6 + 6]
        d = float(np.linalg.norm(np.array(v[:3]) - jp))
        R = ang_matrix(*v[3:])
        a = math.degrees(math.acos(max(-1.0, min(1.0, (np.trace(jr.T @ R) - 1) / 2))))
        raw.append(max(0.0, min(1.0, max((d - 2.0) / 3.0, (a - 12.0) / 12.0))))
    # widen by a sample each side so the hand-off isn't a one-sample pop
    return [round(max(raw[max(0, i - 1):i + 2]), 2) for i in range(n)]


def finger_locals(path, names):
    """Local rotations (Source angles) of the given finger bones in frame 0 of a built SMD: [p y r ...] or None."""
    smd = prep.read_smd(path)
    prep.fill_frames(smd)
    idx = {n: i for i, (n, _) in enumerate(smd.nodes)}
    out = []
    for n in names:
        i = idx.get(n)
        if i is None:
            return None
        r, _t = prep.to_rt(smd.frames[0][1][i])
        out += [round(v, 1) for v in mat_angles(r)]
    return out


def body_gun(m, ctx, clip, built, step=2):
    """MW's gun relative to the right CLAVICLE through a clip (the MP gun chain hangs off it, so this is where the gun
    is while the right hand lets go): [x y z p y r ...] in the target (ValveBiped) clavicle's frame every `step`
    frames, plus MW's hands in j_gun's frame per sample (for mag visibility): ([...], [(R, L), ...]) or None."""
    import cod_to_breen as c2b
    np = _np()
    try:
        spath = tmb.src_path(m, clip)
        src = prep.read_seanim(spath)
        fix = [os.path.normcase(os.path.normpath(d)) for d in m.get("FIX_FIRST_KEY", [])]
        if os.path.normcase(os.path.normpath(os.path.dirname(spath))) in fix:
            src = tmb.fix_first_frame(src)
        if abs((src["fps"] or 30) - 60) < 0.5:
            src = resample_half(src)
        cod, _ = prep.seanim_to_smd(src, ctx.src_body, ctx.mapping, True, prep.CM_TO_INCH, inplace=True)
    except Exception:  # noqa: BLE001
        return None
    names = [n for n, _ in cod.nodes]
    if "j_gun" not in names:
        return None
    prep.fill_frames(cod)
    n = len(cod.frames)
    idx = list(range(0, n, step))
    if idx and idx[-1] != n - 1:
        idx.append(n - 1)
    res = [d for _f, d in smd_world(built, idx)]
    ci = {nm: i for i, nm in enumerate(names)}
    CL = "ValveBiped.Bip01_R_Clavicle"
    trk, hands = [], []
    for si, f in enumerate(idx):
        w = c2b.world_pose(cod.nodes, {i: prep.to_rt(v) for i, v in cod.frames[f][1].items()})

        def M(name):
            r, t = w[ci[name]]
            X = np.eye(4)
            X[:3, :3] = np.array(r)
            X[:3, 3] = t
            return X
        Sc, G = M(CL), M("j_gun")
        Tc = res[si][CL]
        # gun in the source clavicle's frame, re-expressed in the target clavicle's frame (same world rotations)
        rel = np.linalg.inv(Sc) @ G
        Rr = Tc[:3, :3].T @ Sc[:3, :3]                  # source clavicle frame -> target clavicle frame
        pos = Rr @ rel[:3, 3]
        rot = Rr @ rel[:3, :3]
        trk += [round(float(v), 2) for v in pos] + [round(v, 1) for v in mat_angles(rot.tolist())]
        Gi = np.linalg.inv(G)
        hands.append(((Gi @ M("ValveBiped.Bip01_R_Hand")[:, 3])[:3], (Gi @ M("ValveBiped.Bip01_L_Hand")[:, 3])[:3]))
    return trk, hands


MAG_HAND = 8.0   # u: a mag this close to MW's wrist is in the hand
MAG_SEAT = 2.5   # u: ...this close to its seat is in the gun


def resample_half(anim):
    """A 60 fps SEAnim as 30 fps: every key / note time halved."""
    out = dict(anim)
    out["fps"] = 30
    out["frames"] = max(2, int(math.ceil(anim["frames"] / 2)))
    bones = {}
    for n, b in anim["bones"].items():
        nb = {}
        for k, keys in b.items():
            d = {}
            for f, v in keys:
                d[int(round(f / 2.0))] = v  # whole frames; later keys win on a collision
            nb[k] = sorted(d.items())
        bones[n] = nb
    out["bones"] = bones
    out["notes"] = [(f / 2.0, n) for f, n in (anim.get("notes") or [])]
    return out


NOTE_KEYS = {"magout": "_magout", "magin": "_magin", "ikout": "ik_out_start_left_hand", "ikoutend": "ik_out_end_left_hand",
             "ikin": "ik_in_start_left_hand", "ikinend": "ik_in_end_left_hand"}


def action_notes(m, clip):
    """MW19 action notetracks as cycle fractions: mag out / mag in (dual-mag hand-off), left hand off / back on the gun
    (IK windows). MWII exports carry none (the runtime borrows the matching MW19 clip's)."""
    try:
        anim = prep.read_seanim(tmb.src_path(m, clip))
    except Exception:  # noqa: BLE001
        return None
    notes = anim.get("notes") or []
    if not notes:
        return None
    span = max(1, anim["frames"] - 1)
    out = {}
    for fr, name in notes:
        low = name.lower()
        for key, pat in NOTE_KEYS.items():
            if pat in low and key not in out:
                out[key] = round(min(1.0, fr / span), 3)
    return out or None


FINGER_NOTES = {"r": "right_hand", "l": "left_hand"}


def finger_window(notes, hand):
    """MW's finger-overlay weight per frame for one hand from the clip's notetracks: 1 = the gun's finger pose (MW lays
    mp_fingers_<gun> over every clip), 0 = the clip's own fingers. fingers_out_start..end fades it out, fingers_in_start
    ..end back in. None = the clip has no finger notes for that hand (left as authored)."""
    sfx = FINGER_NOTES[hand]
    ev = {}
    for f, n in notes or []:
        n = n.lower()
        for k in ("out_start", "out_end", "in_start", "in_end"):
            if n == f"fingers_{k}_{sfx}" and k not in ev:
                ev[k] = f
    if not ev:
        return None

    def ramp(f, a, b):
        return min(1.0, max(0.0, (f - a) / max(b - a, 1.0)))

    os_, oe = ev.get("out_start"), ev.get("out_end", ev.get("out_start"))
    is_, ie = ev.get("in_start", ev.get("in_end")), ev.get("in_end", ev.get("in_start"))
    w0 = 1.0 if os_ is not None else 0.0
    # a clip that only blends the fingers IN (draws: the hand starts off the gun) starts from the gun's finger pose and
    # eases out over the first frames, instead of snapping to the clip's first frame on the weapon switch
    ease = 6.0 if os_ is None and (is_ is None or is_ > 8) else 0.0

    def w(f):
        v = w0
        if ease and f < ease:
            v = 1.0 - ramp(f, 0.0, ease)
        if os_ is not None and f >= os_:
            v = 1.0 - ramp(f, os_, oe)
        if is_ is not None and f >= is_ and (os_ is None or is_ >= os_):
            v = ramp(f, is_, ie)
        return v
    return w


def finger_overlay(anim, fingers):
    """anim with MW's finger overlay baked in: every finger bone the gun's finger clips key is pulled toward that pose
    by finger_window (per hand). Without this the clip's raw finger keys show where MW never shows them (draws end
    with the index 36-83 deg off the grip, then snap to the hold when the action fades)."""
    bones = dict(anim["bones"])
    n = max(2, anim["frames"])
    for fa in fingers:
        for name, fb in fa["bones"].items():
            if not fb.get("rot") or not ("_ri" in name or "_le" in name):
                continue
            if name.startswith(("j_wrist", "j_elbow", "j_shoulder", "j_clavicle", "tag_")):
                continue
            hand = "r" if "_ri" in name else "l"
            wf = finger_window(anim.get("notes"), hand)
            if wf is None:
                continue
            target = fb["rot"][0][1]
            src = bones.get(name, {})
            keys = []
            for f in range(n):
                cur = prep.sample_keys(src["rot"], f, prep.slerp) if src.get("rot") else target
                keys.append((f, prep.slerp(cur, target, wf(f))))
            nb = dict(src)
            nb["rot"] = keys
            bones[name] = nb
    out = dict(anim)
    out["bones"] = bones
    return out


def override_bones(anim, src, skip=("tag_",)):
    """anim with every bone src keys held at src's first key (finger poses are absolute local)."""
    out = dict(anim)
    bones = {k: dict(v) for k, v in anim["bones"].items()}
    for name, b in src["bones"].items():
        if any(name.startswith(x) for x in skip):
            continue
        nb = dict(bones.get(name, {}))
        for k, keys in b.items():
            if keys:
                nb[k] = [(0, keys[0][1])]
        bones[name] = nb
    out["bones"] = bones
    return out


def compose_weighted(base, delta, rest_quat, frame, w):
    """compose_additive at a fractional frame with the offset scaled by w (0..1): base * slerp(identity, offset, w)."""
    ident = [0.0, 0.0, 0.0, 1.0]
    bones = {}
    for name in set(base["bones"]) | set(delta["bones"]):
        bb, db = base["bones"].get(name, {}), delta["bones"].get(name, {})
        out = {}
        if bb.get("rot") or db.get("rot"):
            q0 = prep.sample_keys(bb["rot"], 0, prep.slerp) if bb.get("rot") else rest_quat(name)
            if q0 is not None:
                if db.get("rot"):
                    qd = prep.slerp(ident, prep.sample_keys(db["rot"], frame, prep.slerp), w)
                    q0 = prep.qmul(q0, qd)
                out["rot"] = [(0, q0)]
        if bb.get("loc") or db.get("loc"):
            l0 = prep.sample_keys(bb["loc"], 0, prep.vlerp) if bb.get("loc") else [0.0, 0.0, 0.0]
            if db.get("loc"):
                ld = prep.sample_keys(db["loc"], frame, prep.vlerp)
                l0 = [l0[k] + ld[k] * w for k in range(3)]
            out["loc"] = [(0, l0)]
        bones[name] = out
    return {"fps": base["fps"], "frames": 2, "looped": True, "type": base["type"], "bones": bones, "notes": []}


def one_stride(res, root, frames, lp, rp, min_gap=8):
    """Cut a locomotion loop to exactly one stride starting on the left foot plant, so every direction in a blend
    has the same phase at the same cycle (the rips hold 1-3 strides per direction: crouch walk fwd 81 frames / 3
    strides next to back-right 22 frames / 1 stride; blended by cycle the feet fought each other).
    Returns (frames, lplant, rplant, speed, note) with plants as frame numbers in the new clip."""
    prep.fill_frames(res)
    lp = sorted(set(lp))
    pair = next(((a, b) for a, b in zip(lp, lp[1:]) if b - a >= min_gap), None)
    if pair is None and min_gap > 8 and len(lp) > 1:
        # plants closer than a stride (doubled / misplaced notes): span to the first plant far enough on
        pair = next(((a, b) for i, a in enumerate(lp) for b in lp[i + 1:] if b - a >= min_gap), None)
    if pair:
        a, b = pair
        res.frames = [(i, bones) for i, (_, bones) in enumerate(res.frames[a:b + 1])]
        x0, y0 = root[a][0], root[a][1]
        x1, y1 = root[min(b, len(root) - 1)][0], root[min(b, len(root) - 1)][1]
        n = b - a + 1
        speed = math.hypot(x1 - x0, y1 - y0) / max(1e-3, (n - 1) / FPS)
        nrp = [f - a for f in rp if a <= f <= b]
        return n, [0, n - 1], nrp, speed, f"stride {a}-{b}"
    # one left plant: the loop's start moves onto it (last frame repeats the first)
    a = lp[0]
    if 0 < a < frames - 1:
        body = res.frames[a:frames - 1] + res.frames[0:a + 1]
        res.frames = [(i, bones) for i, (_, bones) in enumerate(body)]
        x, y = root[-1][0], root[-1][1]
        speed = math.hypot(x, y) / max(1e-3, (frames - 1) / FPS)
        nrp = sorted(((f - a) % (frames - 1)) for f in rp)
        return frames, [0, frames - 1], nrp, speed, f"rotated to {a}"
    x, y = root[-1][0], root[-1][1]
    return frames, lp, rp, math.hypot(x, y) / max(1e-3, (frames - 1) / FPS), ""


def _mid_and_feet(res, bones):
    idx = {n: i for i, (n, _) in enumerate(res.nodes)}
    w = tmb.c2b.world_pose(res.nodes, {i: prep.to_rt(v) for i, v in bones.items()})
    p, h = w[idx["ValveBiped.Bip01_Pelvis"]][1], w[idx["ValveBiped.Bip01_Head1"]][1]
    lf, rf = w[idx["ValveBiped.Bip01_L_Foot"]][1], w[idx["ValveBiped.Bip01_R_Foot"]][1]
    return ((p[0] + h[0]) / 2, (p[1] + h[1]) / 2), ((lf[0] + rf[0]) / 2, (lf[1] + rf[1]) / 2)


def recenter_slide(res, mode):
    """Stance changes into / out of prone: standing clips are centred on the feet, prone ones on the body middle
    (recenter_mid). feet>mid: first frame feet on the origin, last frame body middle on it, shift eased between
    (the body slides forward as it goes down, so neither end pops against the clip next to it); mid>feet reverse."""
    prep.fill_frames(res)
    mid0, feet0 = _mid_and_feet(res, res.frames[0][1])
    mid1, feet1 = _mid_and_feet(res, res.frames[-1][1])
    # feet>feet (stops): first and last frame both feet-centred, so the stop starts on the loop and ends on the idle
    a, b = {"feet>mid": (feet0, mid1), "mid>feet": (mid0, feet1), "feet>feet": (feet0, feet1)}[mode]
    root = next(i for i, (_, p) in enumerate(res.nodes) if p == -1)
    n = max(1, len(res.frames) - 1)
    for k, (_, bones) in enumerate(res.frames):
        t = k / n
        t = t * t * (3 - 2 * t)
        dx, dy = a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t
        v = bones[root]
        bones[root] = [v[0] - dx, v[1] - dy] + v[2:]


def recenter_mid(res, loop):
    """Shift the clip so the midpoint of pelvis and head (averaged over a loop, first frame of a one-shot) sits on
    the origin (x, y only)."""
    prep.fill_frames(res)
    idx = {n: i for i, (n, _) in enumerate(res.nodes)}
    pel, head = idx.get("ValveBiped.Bip01_Pelvis"), idx.get("ValveBiped.Bip01_Head1")
    if pel is None or head is None:
        return
    root = next(i for i, (_, p) in enumerate(res.nodes) if p == -1)
    frames = res.frames if loop else res.frames[:1]
    sx = sy = 0.0
    for _, bones in frames:
        w = tmb.c2b.world_pose(res.nodes, {i: prep.to_rt(v) for i, v in bones.items()})
        sx += (w[pel][1][0] + w[head][1][0]) / 2
        sy += (w[pel][1][1] + w[head][1][1]) / 2
    dx, dy = sx / len(frames), sy / len(frames)
    for _, bones in res.frames:
        v = bones[root]
        bones[root] = [v[0] - dx, v[1] - dy] + v[2:]


# --- per-gun weapon actions ------------------------------------------------------------------------------------------

GUN_CLASSES = ("ar", "sm", "sh", "sn", "lm", "dm", "la", "pi")
STANCES = ("stand", "crouch", "prone")
# action -> candidate rip names, MW19 FIRST (MW Base ships MW19's guns; user 2026-11-24), MWII fills the gaps (mostly
# crouched clips and the per-mag reloads MW19 lacks). {c} class token, {g} gun codename, {st} stance,
# {sx} "" / "_crouch" / "_prone" (MW19's carry raise / lower names put the stance before the class)
GUN_ACTS = {
    "rel":   ["mp_{st}_custom_reload_{c}_{g}", "sdr_mp_{st}_custom_reload_{c}_{g}", "iw9_mp_{c}_{g}_reload_{st}"],
    "emp":   ["mp_{st}_custom_reload_empty_{c}_{g}", "sdr_mp_{st}_custom_reload_empty_{c}_{g}",
              "iw9_mp_{c}_{g}_reload_empty_{st}"],
    # extended mags (MW Base Reload_Xmag*) - MWII only
    "relx":  ["iw9_mp_{c}_{g}_reload_xmag_{st}"],
    "empx":  ["iw9_mp_{c}_{g}_reload_empty_xmag_{st}"],
    # large mags / drums (MW Base Reload_XmagLrg*)
    "relxl": ["mp_{st}_custom_reload_{c}_{g}_drum", "iw9_mp_{c}_{g}_reload_xmaglrg_{st}", "iw9_mp_{c}_{g}_reload_drums_{st}"],
    "empxl": ["mp_{st}_custom_reload_empty_{c}_{g}_drum", "iw9_mp_{c}_{g}_reload_empty_xmaglrg_{st}",
              "iw9_mp_{c}_{g}_reload_xmaglrg_empty_{st}", "iw9_mp_{c}_{g}_reload_empty_drums_{st}"],
    "insp":  ["sdr_mp_inspect_{st}_{c}_{g}", "mp_inspect_{st}_{c}_{g}", "iw9_mp_{c}_{g}_inspect_{st}"],
    # first draw (MW Base Equip) / normal draw from the back / holster to the back
    "raise": ["sdr_mp_raise_first_{st}_{c}_{g}", "iw9_mp_{c}_{g}_raise_first_{st}"],
    # normal draw / holster from the gun's carry: pistols the thigh holster, shotguns slung on the back ("2_back"),
    # long guns the back (rifles / SMGs prefer the chest sling, drawc / holc below)
    "draw":  ["sdr_mp_raise_thigh{sx}_{c}_{g}", "sdr_mp_raise_2_thigh{sx}_{c}_{g}", "sdr_mp_raise_thigh{sx}_moving_{c}_{g}",
              "sdr_mp_raise_2_back{sx}_{c}_{g}", "sdr_mp_raise_back_r{sx}_{c}_{g}", "sdr_mp_raise{sx}_{c}_{g}",
              "iw9_mp_{c}_{g}_raise_quickdraw_l_{st}"],
    "hol":   ["sdr_mp_lower_2_thigh{sx}_{c}_{g}", "sdr_mp_lower_thigh{sx}_{c}_{g}", "sdr_mp_lower_2_back{sx}_{c}_{g}",
              "sdr_mp_lower_2_back_r{sx}_{c}_{g}", "sdr_mp_lower{sx}_{c}_{g}", "iw9_mp_{c}_{g}_lower_quickdraw_l_{st}"],
    # chest sling (user: the sling draw) - rifles / SMGs prefer it over the back carry
    "drawc": ["sdr_mp_raise_chest{sx}_{c}_{g}"],
    "holc":  ["sdr_mp_lower_2_chest{sx}_{c}_{g}", "sdr_mp_lower_chest{sx}_{c}_{g}"],
    # shell-by-shell reloads (MW Base Reload_Start / Reload_Loop per round / ReloadEnd): MW19 has them for the 870, R9
    # and Kar98k (stand + prone), MWII for most of its pump / lever / bolt guns
    "rels":  ["mp_{st}_custom_reload_start_{c}_{g}", "sdr_mp_{st}_custom_reload_start_{c}_{g}",
              "iw9_mp_{c}_{g}_reload_start_{st}"],
    "rell":  ["mp_{st}_custom_reload_loop_{c}_{g}", "sdr_mp_{st}_custom_reload_loop_{c}_{g}",
              "iw9_mp_{c}_{g}_reload_loop_{st}"],
    "rele":  ["mp_{st}_custom_reload_end_{c}_{g}", "sdr_mp_{st}_custom_reload_end_{c}_{g}",
              "iw9_mp_{c}_{g}_reload_end_{st}"],
    # end with a pump / bolt (MW Base Reload_End_Empty, chamber was empty)
    "relee": ["iw9_mp_{c}_{g}_reload_end_rechamber_{st}"],
    # bolt / pump cycle after a shot (MW Base Rechamber task)
    # per-shot body kick (MW19: ADDITIVE upper-body clips, 60 fps; stand + prone, crouch borrows stand)
    "fire":  ["mp_{st}_custom_fire_{c}_{g}", "sdr_mp_{st}_custom_fire_{c}_{g}"],
    "fireads": ["mp_{st}_custom_fire_{c}_{g}_ads", "sdr_mp_{st}_custom_fire_{c}_{g}_ads"],
    "rech":  ["mp_{st}_custom_rechamber_{c}_{g}", "sdr_mp_{st}_custom_rechamber_{c}_{g}", "iw9_mp_{c}_{g}_rechamber_{st}",
              "iw9_mp_{c}_{g}_rechamber"],
    # melee (MW Base Meleeing): rifle-butt / pistol whip
    "melee": ["mp_{st}_gun_butt_hit_01_{c}_{g}", "sdr_mp_{st}_gun_butt_hit_01_{c}_{g}", "mp_{st}_melee_hit_01_{c}_{g}",
              "sdr_mp_{st}_melee_hit_01_{c}_{g}", "iw9_mp_{c}_{g}_melee_{st}_01"],
}
# Per-gun holds: MW addoff (additive offset on the stance idle) + the gun's finger poses, as a delta against the class's
# generic hold (rifle classes: M4, pistols: X16; prone: the M4 for everything - there's no prone aim layer to carry it)
HOLD_ADDOFF = {"stand": ["sdr_mp_addoff_{c}_{g}_{k}", "iw9_mp_addoff_{c}_{g}_{k}", "sdr_mp_addoff_{c}_{g}_{k}_noright"],
               "crouch": ["sdr_mp_addoff_crouch_{c}_{g}_{k}", "iw9_mp_addoff_crouch_{c}_{g}_{k}",
                          "sdr_mp_addoff_crouch_{c}_{g}_{k}_noright"],
               "prone": ["sdr_mp_addoff_prone_{c}_{g}_{k}", "iw9_mp_addoff_prone_{c}_{g}_{k}",
                         "sdr_mp_addoff_prone_{c}_{g}_{k}_noright"]}
HOLD_IDLE = {"stand": ("sdr_mp_stand_idle01", True), "crouch": ("sdr_mp_crouch_idle", True),
             "prone": ("sdr_mp_prone_idle_1", "mid")}
HOLD_GENERIC = {"pi": ("pi", "golf21"), "_": ("ar", "mike4")}
# Left-hand finger variants for grips (MW Base SetGripPoseParameter -> variant, sh_anim_guns GripVariant). A gun without
# its own variant borrows the generic rifle's (a hand round a vertical / angled grip is much the same on every gun).
GRIP_FINGERS = {
    "vert":    ["mp_fingers_{c}_{g}_l_grip", "mp_fingers_{c}_{g}_gripvert_l", "mp_fingers_{c}_{g}_l_gripvert",
                "mp_fingers_{c}_{g}_vertgrip_l", "iw9_mp_{c}_{g}_fingers_l_gripvert", "iw9_mp_fingers_{c}_{g}_l_gripvert"],
    "vertpro": ["mp_fingers_{c}_{g}_gripvertpro_l", "mp_fingers_{c}_{g}_l_gripvertpro", "mp_fingers_{c}_{g}_vertgrippro_l",
                "mp_fingers_{c}_{g}_gripvert_pro", "iw9_mp_{c}_{g}_fingers_l_gripvertshort"],
    "ang":     ["mp_fingers_{c}_{g}_l_gripang", "mp_fingers_{c}_{g}_gripang_l", "mp_fingers_{c}_{g}_angledgrip_l",
                "iw9_mp_{c}_{g}_fingers_l_gripang", "iw9_mp_fingers_{c}_{g}_l_gripang"],
    "side":    ["mp_fingers_{c}_{g}_gripside_l", "mp_fingers_{c}_{g}_l_gripside"],
    "gl":      ["mp_fingers_{c}_{g}_l_gl", "mp_fingers_{c}_{g}_gl_l", "iw9_mp_{c}_{g}_fingers_l_ubgl"],
}
SX = {"stand": "", "crouch": "_crouch", "prone": "_prone"}
# MW's bolt / pump clips are ADDITIVE upper-body offsets (as absolute poses the arms went straight up, right hand at
# 89 u; composed on the idle it sits at 49 u like a reload). They're composed on the stance idle and compiled as a delta
# of their own first frame, so they layer over whatever hold / aim the player is in.
ADDITIVE_ACTS = {"rech", "fire", "fireads"}
# the gun's own per-shot part motion (bolt / carrier / slide): no body, parts only, sampled at 60 fps (a bolt cycle is
# a few frames)
FIRE_WEAPON = ["mp_stand_custom_fire_{c}_{g}_weapon", "sdr_mp_stand_custom_fire_{c}_{g}_weapon",
               "iw9_mp_{c}_{g}_fire_weapon"]
# upper body only (legs keep the locomotion): pelvis / legs 0, spine fades in, Spine4 and up 1
UPPER = "mpm_upper"


# --- clips -----------------------------------------------------------------------------------------------------------

def _cache_src(out):
    try:
        with open(out + ".src", encoding="utf-8") as fh:
            return fh.read().strip()
    except OSError:
        return None


def exists(m, clip):
    p = tmb.src_path(m, clip)
    return os.path.exists(p) and tmb.is_seanim(p)


class Builder:
    @property
    def body_bones(self):
        """CoD body bone names (anything else animated in a gun clip is a gun part)."""
        global _BODY
        if _BODY is None:
            _BODY = set(prep.read_seanim(tmb.src_path(self.m, HOLD_IDLE["stand"][0]))["bones"])
        return _BODY

    def __init__(self, m):
        self.m = m
        self.ctx = tmb.Ctx(m)
        self.build = m["BUILD"]
        self.seqs = []      # QC lines
        self.data = {}      # name -> Lua entry
        self.report = []
        self.gun = None
        self.aims = []      # aim layer QC (emitted before the sequences that addlayer them)
        self.gun_table = {}
        self.anim_names, self.anim_used, self.anim_lines = {}, set(), []
        self.hold_lines, self.hold_refs = [], {}   # hold_lines: the generic hold refs (go into every gun model)
        self.gun_seqs = {}                          # gun -> its sequences / animations (split into gun models)
        self.specs = []

    def smd(self, key):
        p = os.path.join(self.build, "clips", key + ".smd")
        os.makedirs(os.path.dirname(p), exist_ok=True)
        return p

    def rel(self, p):
        return os.path.relpath(p, self.build).replace("\\", "/")

    def clip(self, clip, loop, anim=None, key=None, center=True, cycle=False, min_gap=8, cached=False, src_tag=None):
        """Convert one clip; returns (smd path, info dict). center "mid": the body's middle (pelvis-head midpoint)
        goes over the origin instead of the feet (prone: centred on the feet the body stuck ~50 units out in front of
        the hull)."""
        key = key or clip
        out = self.smd(key)
        # cache: reuse a converted gun clip unless the converter changed since (gun rig fits live in cod_anim_prep)
        if cached and os.path.exists(out) and not self.m.get("REBUILD_GUNS") and os.path.getmtime(out) > max(
                os.path.getmtime(prep.__file__), os.path.getmtime(tmb.__file__)) and _cache_src(out) == f"{src_tag or clip}|{GUN_CLIP_VER}":
            with open(out, encoding="utf-8", errors="replace") as fh:
                frames = sum(1 for ln in fh if ln.lstrip().startswith("time "))  # SMD frame lines are indented
            return out, {"from": clip, "frames": frames, "dur": round(max(1e-3, (frames - 1) / FPS), 3)}
        if anim is None:
            src = prep.read_seanim(tmb.src_path(self.m, clip))
            if abs((src["fps"] or 30) - 60) < 0.5:
                # MW19's bolt / pump cycles are 60 fps exports: halve the key times (sample_keys interpolates)
                anim = resample_half(src)
        anim, res, root, frames, _shift = tmb.build_clip(self.ctx, clip, out, loop, center is True, anim)
        with open(out + ".src", "w", encoding="utf-8") as fh:
            fh.write(f"{src_tag or clip}|{GUN_CLIP_VER}")
        if center == "mid":
            recenter_mid(res, loop)
            prep.write_smd(out, res)
        elif center in ("feet>mid", "mid>feet", "feet>feet"):
            recenter_slide(res, center)
            prep.write_smd(out, res)
        if self.gun is None:
            self.gun = tmb.gun_rest(res)
        dur = max(1e-3, (frames - 1) / FPS)
        x, y, _z, yaw = root[-1]
        speed = math.hypot(x, y) / dur
        notes = [] if key != clip else tmb.borrow_notes(self.m, clip, anim, frames)
        _tags, lp, rp = tmb.note_tags(notes, frames)
        if loop and not lp and not rp and speed > 15:
            lp, rp = tmb.detect_steps(res, frames)
        cut = ""
        if cycle and loop and lp:
            frames, lp, rp, speed, cut = one_stride(res, root, frames, lp, rp, min_gap)
            prep.write_smd(out, res)
            dur = max(1e-3, (frames - 1) / FPS)
        span = max(1, frames - 1)
        info = {}
        if not loop:
            # cumulative ground distance per frame (one-shots: the graph drives starts / stops by distance)
            d, acc = [0.0], 0.0
            for i in range(1, min(frames, len(root))):
                acc += math.hypot(root[i][0] - root[i - 1][0], root[i][1] - root[i - 1][1])
                d.append(acc)
            samp = d[::2]
            if (len(d) - 1) % 2:
                samp.append(d[-1])
            info["dist"] = [round(v, 1) for v in samp]
            info["total"] = round(acc, 1)
            yw = [root[i][3] for i in range(min(frames, len(root)))]
            ysamp = yw[::2]
            if (len(yw) - 1) % 2:
                ysamp.append(yw[-1])
            if any(abs(v) > 1 for v in yw):
                info["yawc"] = [round(v, 1) for v in ysamp]
        info.update({
            "from": clip, "frames": frames, "dur": round(dur, 3), "speed": round(speed, 1),
            "dir": round(math.degrees(math.atan2(y, x)), 1) if speed > 1 else 0,
            "turn": round(yaw, 1), "loop": bool(loop),
            "lplant": [round(f / span, 3) for f in lp], "rplant": [round(f / span, 3) for f in rp],
        })
        self.report.append(f"{key:46s} {frames:4d} fr  {speed:6.1f} u/s  dir {info['dir']:7.1f}  "
                           f"plants L{len(lp)} R{len(rp)}  {cut}")
        return out, info

    def pose(self, clip, frame=0, center=True, length=2):
        """One frame of a clip held as a loop of `length` frames (blend centres: the same length as the direction
        clips, or the engine plays the blend ~30x too fast near the centre - it weights each clip's cycle rate)."""
        key = f"{clip}_pose{frame}_{length}"
        anim = tmb.hold_pose(prep.read_seanim(tmb.src_path(self.m, clip)), frame)
        anim["frames"] = max(2, int(length))
        out, _ = self.clip(clip, True, anim, key, center)
        return out

    def layer_for(self, name):
        """The aim layer a sequence set gets (manifest AIM_ON: layer -> fnmatch patterns on set names)."""
        import fnmatch
        for layer, pats in self.m.get("AIM_ON", {}).items():
            if any(fnmatch.fnmatch(name, pt) for pt in pats):
                return f"mpm_{layer}"
        return None

    def anim_ref(self, rel):
        """A named $animation for a clip file (emitted once; every sequence / class set referencing the file shares
        the data instead of compiling it again)."""
        name = self.anim_names.get(rel)
        if not name:
            name = "an_" + re.sub(r"[^A-Za-z0-9_]", "_", os.path.splitext(os.path.basename(rel))[0])
            while name in self.anim_used:
                name += "_x"
            self.anim_used.add(name)
            self.anim_names[rel] = name
            self.anim_lines.append(f'$animation "{name}" "{rel}" fps {FPS}')
        return name

    def seq_line(self, seq, files_or_file, loop, layer, blend=None, set_name=None, named=True):
        """One $sequence; block form so an aim layer can ride on it (addlayer / blendlayer). Recorded in self.specs
        so CLASS_SETS can clone it for another weapon class with that class's aim layers."""
        if named:
            self.specs.append({"seq": seq, "files": files_or_file, "loop": loop, "layer": layer, "blend": blend,
                               "set": set_name})
        ref = self.anim_ref if named else (lambda f: f)
        body = []
        if isinstance(files_or_file, str):
            body.append(f'\t"{ref(files_or_file)}"')
        else:
            for row in files_or_file:
                body.append("\t" + " ".join(f'"{ref(f)}"' for f in row))
        if blend:
            body += blend
        body.append(f"\tfps {FPS}" + (" loop" if loop else ""))
        if layer:
            ads = self.m.get("ADS_OF", {}).get(layer[len("mpm_"):])
            if ads:
                # hip layer full at 0 fading out by 1, ADS layer fading in from 0 to full at 1
                body.append(f'\tblendlayer "{layer}" -1 -1 0 1 poseparameter "{ADS}"')
                body.append(f'\tblendlayer "mpm_{ads}" 0 1 2 2 poseparameter "{ADS}"')
            else:
                body.append(f'\taddlayer "{layer}"')
        return f'$sequence "{seq}" {{\n' + "\n".join(body) + "\n}"

    def aim_grid(self, name, circle, base_clip, opts=None):
        """MW aim circle -> 5x5 additive blend (hidden delta sequence mpm_<name>) on mpm_ay / mpm_ap.
        MW's circle_90 clips are additive upper-body offsets around a 90 deg ring: frame = direction angle
        (0 up, 90 right, 180 down, 270 left; measured 2026-11-24 from the hands line on sdr_mp_aims_ar_circle_90).
        Grid point (yaw, pitch): angle atan2(-yaw, -pitch), offset weight min(1, r / 90), composed on the base
        stance pose, then made a delta of the centre point (studiomdl subtract)."""
        opts = opts if isinstance(opts, dict) else {}
        center = opts.get("center", True)
        base = prep.read_seanim(tmb.src_path(self.m, base_clip))
        if opts.get("hold"):
            # ADS: the gun's ADS hold offset (MW addoff_<cls>_<gun>_ads) composed on the stance idle first
            base = compose_weighted(base, prep.read_seanim(tmb.src_path(self.m, opts["hold"])),
                                    self.ctx.rest_quat, 0, 1.0)
        circ = prep.read_seanim(tmb.src_path(self.m, circle))
        nfr = max(k[-1][0] for b in circ["bones"].values() for k in b.values() if k)
        rows, paths = [], {}
        for pi, pitch in enumerate(AIM_GRID):         # rows: second blend param (pitch, up first)
            row = []
            for yi, yaw in enumerate(AIM_GRID):       # columns: first blend param (yaw, right first)
                r = min(90.0, math.hypot(yaw, pitch))
                w = r / 90.0
                theta = math.degrees(math.atan2(-yaw, -pitch)) % 360.0
                frame = theta / 360.0 * nfr
                anim = compose_weighted(base, circ, self.ctx.rest_quat, frame, w)
                key = f"{name}_y{yaw}_p{pitch}".replace("-", "m")
                path, _ = self.clip(base_clip, True, anim, key, center)
                paths[(yaw, pitch)] = path
                row.append(f"a_{key}")
            rows.append(row)
        own_ref = f"a_{name}_ref"
        lines = [f'$animation "{own_ref}" "{self.rel(paths[(0, 0)])}" fps {FPS}']
        # deltas against another grid's centre (ADS against the HIP centre, so the raise to the eye is in the layer)
        ref = f"a_{opts['ref']}_ref" if opts.get("ref") else own_ref
        for (yaw, pitch), path in paths.items():
            key = f"{name}_y{yaw}_p{pitch}".replace("-", "m")
            lines.append(f'$animation "a_{key}" "{self.rel(path)}" fps {FPS} subtract "{ref}" 0')
        blk = [f'$sequence "mpm_{name}" {{']
        for row in rows:
            blk.append("\t" + " ".join(f'"{a}"' for a in row))
        blk += [f"\tblendwidth {len(AIM_GRID)}", f'\tblend "{AY}" {AIM_GRID[0]} {AIM_GRID[-1]}',
                f'\tblend "{AP}" {AIM_GRID[0]} {AIM_GRID[-1]}', "\tdelta", "\thidden", f"\tfps {FPS} loop", "}"]
        self.aims += lines + blk
        self.data[name] = {"seq": f"mpm_{name}", "kind": "aim", "from": circle, "base": base_clip}
        self.report.append(f"{name}: aim grid {len(AIM_GRID)}x{len(AIM_GRID)} from {circle} on {base_clip}")

    def guns(self, cfg):
        """Per-gun weapon actions for every gun of an addon set (MW Base: lua/weapons/mg_<codename>): reload / empty
        reload / inspect / first raise per stance, found by GUN_ACTS patterns. Each becomes an upper-body sequence
        mpm_g_<gun>_<act>_<stance> (weightlist mpm_upper, aim layer on stand / crouch) for the graph to play as a
        gesture, time-fitted to the weapon's own action length."""
        import glob
        guns = sorted({os.path.basename(d)[len(cfg.get("prefix", "mg_")):] for d in glob.glob(cfg["glob"])}
                      - set(cfg.get("skip", []))) if cfg.get("glob") else []
        alias = cfg.get("alias", {})
        # kits: non-gun holdtypes (fists, knife, frag, rpg, passive) built like a gun: {name: {rip, cls, acts, pose}}
        kits = cfg.get("kits", {})
        guns += sorted(kits)
        table = {}
        for g in guns:
            kit = kits.get(g, {})
            rip = kit.get("rip", alias.get(g, g))
            acts_all = dict(GUN_ACTS, **kit.get("acts", {}))
            # the class token with the most matching clips (the crossbow / MK14 also match a few "sn" names)
            best, cls = 0, kit.get("cls")
            for c in ([] if cls else GUN_CLASSES):
                # MW19 clips first (user rule): a class only MWII uses for this gun (AUG: MW19 sm / MWII ar, M14: MW19
                # sn / MWII dm) must not win on MWII's clip count - MW19 matches count 1000x
                n = sum((1 if pat.startswith("iw9_") else 1000) for pats in GUN_ACTS.values() for pat in pats
                        for st in STANCES if exists(self.m, pat.format(c=c, g=rip, st=st, sx=SX[st])))
                if n > best:
                    best, cls = n, c
            if not cls:
                self.report.append(f"gun {g}: no clips (alias?)")
                continue
            entry = {"cls": cls}
            if kit:
                entry["kit"] = True
            fingers_g = None  # the gun's MW finger poses (loaded on its first action)
            for act, pats in acts_all.items():
                for st in STANCES:
                    cands = [pt.format(c=cls, g=rip, st=st, sx=SX[st]) for pt in pats
                             if exists(self.m, pt.format(c=cls, g=rip, st=st, sx=SX[st]))]
                    if not cands:
                        continue
                    # user: MW19 anims first, MWII only fills holes. MW19 has no crouch reloads / inspects (the game
                    # plays the stand one over crouched legs) - so a MWII crouch clip must not beat a MW19 stand one;
                    # without a crouch entry the runtime falls back to stand.
                    if st == "crouch" and all(c.startswith("iw9_") for c in cands) and any(
                            not pt.startswith("iw9_") and exists(self.m, pt.format(c=cls, g=rip, st="stand", sx=""))
                            for pt in pats):
                        continue
                    key = f"g_{g}_{act}_{st}"
                    if fingers_g is None:
                        fingers_g = [prep.read_seanim(tmb.src_path(self.m, f))
                                     for f in (f"mp_fingers_{cls}_{rip}_r", f"mp_fingers_{cls}_{rip}_l")
                                     if exists(self.m, f)]
                    path = info = clip = None
                    for clip in cands:  # one bad clip (e.g. a 60 fps export) must not sink the gun or the table
                        try:
                            anim_in = None
                            if act in ADDITIVE_ACTS:
                                src = prep.read_seanim(tmb.src_path(self.m, clip))
                                if abs((src["fps"] or 30) - 60) < 0.5:
                                    src = resample_half(src)
                                idle = prep.read_seanim(tmb.src_path(self.m, HOLD_IDLE[st][0]))
                                anim_in = tmb.additive_on(idle, src, self.ctx.rest_quat)
                            elif fingers_g:
                                spath = tmb.src_path(self.m, clip)
                                src = prep.read_seanim(spath)
                                fix = [os.path.normcase(os.path.normpath(d)) for d in self.m.get("FIX_FIRST_KEY", [])]
                                if os.path.normcase(os.path.normpath(os.path.dirname(spath))) in fix:
                                    src = tmb.fix_first_frame(src)
                                if abs((src["fps"] or 30) - 60) < 0.5:
                                    src = resample_half(src)
                                anim_in = finger_overlay(src, fingers_g)
                            path, info = self.clip(clip, False, anim_in, key=key,
                                                   center=True if st != "prone" else "mid", cached=True)
                            break
                        except Exception as ex:  # noqa: BLE001
                            self.report.append(f"  gun {g} {act}_{st}: skipped {clip} ({ex})")
                    if not path:
                        continue
                    layer = {"stand": "mpm_aim_ar", "crouch": "mpm_aimc_ar"}.get(st)
                    seq = f"mpm_{key}"
                    if act in ADDITIVE_ACTS:
                        rel = self.rel(path)
                        self.gun_seqs.setdefault(g, []).append(
                            f'$animation "a_{key}_ref" "{rel}" fps {FPS} frames 0 0\n'
                            f'$animation "a_{key}" "{rel}" fps {FPS} subtract "a_{key}_ref" 0\n'
                            f'$sequence "{seq}" {{\n\t"a_{key}"\n\tdelta\n\tweightlist "{UPPER}"\n\tfps {FPS}\n}}')
                    else:
                        self.gun_seqs.setdefault(g, []).append(
                            self.seq_line(seq, self.rel(path), False, layer, [f'\tweightlist "{UPPER}"'], None, False))
                    entry[f"{act}_{st}"] = {"seq": seq, "dur": info["dur"], "from": clip}
            # MW's gun motion for every action (the runtime places the world model from it)
            for k, v in list(entry.items()):
                if isinstance(v, dict) and "seq" in v:
                    trk = gun_track(os.path.join(self.build, "clips", v["seq"][len("mpm_"):] + ".smd"))
                    if trk:
                        v["gun"] = trk
                    nt = action_notes(self.m, v["from"])
                    if nt:
                        v["notes"] = nt
                    pt = part_tracks(self.m, v["from"], self.body_bones,
                                     mags=k.rsplit("_", 1)[0] not in NO_MAGS)
                    if pt:
                        v["parts"] = pt
            # the gun's own per-shot part motion (played on the world model on every shot)
            for pat in FIRE_WEAPON:
                fc = pat.format(c=cls, g=rip)
                if exists(self.m, fc):
                    fa = prep.read_seanim(tmb.src_path(self.m, fc))
                    pt = part_tracks(self.m, fc, self.body_bones, step=1, mags=False, native=True)
                    if pt:
                        fps = fa["fps"] or 30
                        entry["firew"] = {"parts": pt, "dur": round(max(2, fa["frames"]) / fps, 3), "from": fc}
                    break
            gs = self.m.get("GUN_SETS", {}).get(g)
            self.hold_ref_over = gs and gs.get("ref")
            if gs:
                entry["set"] = gs["set"]
            self.kit_hold = kit.get("hold") or {}
            self.kit_fingers = kit.get("fingers")
            self.gun_hold(g, rip, cls, entry, kit.get("pose"))
            if gs and gs.get("sprint"):
                self.gun_sprint_hold(g, rip, cls, entry, gs["sprint"])
            self.kit_hold, self.kit_fingers, self.hold_ref_over = {}, None, None
            if not kit:
                self.gun_rework(g, cls, entry)
            self.gun_fingers(g, entry, bool(kit))
            table[g] = entry
            n = len([k for k in entry if k != "cls"])
            self.report.append(f"gun {g:12s} {cls}  {n} entries")
        self.fire_check(table)
        self.gun_table = dict(getattr(self, "gun_table", None) or {}, **table)

    def fire_check(self, table):
        """Shot kicks: drop clips whose muzzle goes DOWN more than 10 deg (MW's .357 kick reads -42 deg, the RPG hip -24
        - the M19 borrowed the .357's and recoiled the wrong way), then give guns without a kick their class's chosen
        donor (FIRE_DONOR) instead of the alphabetically first one."""
        np = _np()
        for g, entry in table.items():
            for k in [k for k in entry if k.startswith(("fire_", "fireads_")) and isinstance(entry[k], dict)]:
                p = os.path.join(self.build, "clips", entry[k]["seq"][len("mpm_"):] + ".smd")
                if not os.path.exists(p):
                    continue
                n = len(prep.read_smd(p).frames)
                W = [d for _f, d in smd_world(p, list(range(n)))]
                if "j_gun" not in W[0]:
                    continue
                g0 = np.linalg.inv(W[0]["ValveBiped.Bip01_Spine4"]) @ W[0]["j_gun"]
                worst = 0.0
                for d in W[1:]:
                    gi = np.linalg.inv(d["ValveBiped.Bip01_Spine4"]) @ d["j_gun"]
                    rise = math.degrees(math.asin(max(-1.0, min(1.0, float(gi[:3, 0] @ g0[:3, 2])))))
                    if abs(rise) > abs(worst):
                        worst = rise
                if worst < -10:
                    self.report.append(f"  {g}: shot kick {entry[k]['from']} dropped (muzzle {worst:+.0f} deg)")
                    del entry[k]
        for g, entry in table.items():
            donor = self.m.get("FIRE_DONOR", {}).get(entry.get("cls"))
            d = table.get(donor) if donor and donor != g else None
            if not d:
                continue
            for k, v in d.items():
                if k.startswith(("fire_", "fireads_")) and isinstance(v, dict) and k not in entry:
                    entry[k] = v
                    entry.setdefault("_firedonor", donor)

    def gun_rework(self, g, cls, entry):
        """v0.10.0: gt (MW grip calibration), per-action body-anchored gun track (gunc) and MW-hand mag visibility."""
        np = _np()
        global MW_GT
        if MW_GT is None and cls == "pi":
            MW_GT = self.mw_gt_median()
        acts = [os.path.join(self.build, "clips", entry[k]["seq"][len("mpm_"):] + ".smd")
                for k in ("rel_stand", "emp_stand", "insp_stand", "raise_stand") if isinstance(entry.get(k), dict)]
        grip = mw_grip(acts)
        cal = gun_calib(self.m, g, cls, grip)
        if not cal:
            self.report.append(f"  {g}: no world-model calibration (old placement)")
            return
        entry["gt"], est = cal
        if est:
            entry["gtest"] = True
        R, L, J, rig, JL = grip
        if rig == "iw9":
            # MWII actions, MW19-rig holds (MW19 idle + offset): the hold needs its own calibration (MW19 rig) - from the
            # hold clip itself (its wrist bends a few degrees; better than the 17 u between the two rigs' gun bones)
            hp = self.smd(f"h_{g}_stand_nonads")
            g0 = mw_grip([hp]) if os.path.exists(hp) else None
            if g0:
                hc = gun_calib(self.m, g, cls, g0[:3] + ("mw",))
                if hc:
                    entry["gth"] = hc[0]
        # the real grip (right hand IK target: gun * J^-1) and, for magwell holds, MW's left wrist on the gun
        entry["jg"] = [round(float(v), 2) for v in J[:3, 3]] + [round(v, 1) for v in mat_angles(J[:3, :3].tolist())]
        # MW's real left hand on the gun (j_gun frame; v0.10.4): the left-hand IK turns the hand to it - the hold clips
        # bend the left wrist like the right (30-63 deg off MW's draw / reload end frames: "right, then wrong")
        entry["jl"] = [round(float(v), 2) for v in JL[:3, 3]] + [round(v, 1) for v in mat_angles(JL[:3, :3].tolist())]
        t = np.array(entry["gt"])
        if g in self.m.get("LEFT_FROM_CLIP", ()):
            entry["lhg"] = [round(float(v), 2) for v in (L - t)]
        if g in self.m.get("INTEGRATED_GRIP", {}):
            entry["integ"] = self.m["INTEGRATED_GRIP"][g]
        info = wm_info(self.m, g)
        # tag_sling's rest under the hand bone, from the model (v0.10.0 measured it live: a stale frame baked MW Base's
        # 90 / 180 deg offset into it - the "90 degree" guns)
        bone = info["bone"]
        hb = info["rel"].get("ValveBiped.Bip01_R_Hand")
        if hb is not None:
            rest = np.linalg.inv(hb)  # the placement bone in the hand's frame (rel is in the placement bone's frame)
            entry["srest"] = [round(float(v), 3) for v in rest[:3, 3]] + [round(v, 2) for v in mat_angles(rest[:3, :3].tolist())]
        seats = {b: info["rel"][b][:3, 3] + t for b in ("j_mag1", "j_mag2") if b in info["rel"]}
        n_body = 0
        for k, v in list(entry.items()):
            if not (isinstance(v, dict) and "seq" in v and v.get("gun")) or k.rsplit("_", 1)[0] in ADDITIVE_ACTS:
                continue
            bg = body_gun(self.m, self.ctx, v["from"], os.path.join(self.build, "clips", v["seq"][len("mpm_"):] + ".smd"))
            if not bg:
                continue
            v["gunc"], hands = bg
            v["lg"] = letgo_track(v["gun"], J)
            n_body += 1
            # mags: visible only while seated or in one of MW's hands (user: hidden by the time it's at the pouches)
            for mb, tr in (v.get("parts") or {}).items():
                if "v" not in tr or mb not in seats:
                    continue
                p = tr.get("p")
                vis = []
                for i, (R, L) in enumerate(hands):
                    off = np.array(p[i * 3:i * 3 + 3]) if p and len(p) >= i * 3 + 3 else np.zeros(3)
                    pos = seats[mb] + off
                    near = (np.linalg.norm(off) < MAG_SEAT or np.linalg.norm(pos - L) < MAG_HAND
                            or np.linalg.norm(pos - R) < MAG_HAND)
                    vis.append(1 if near and tr["v"][min(i, len(tr["v"]) - 1)] else 0)
                if len(vis) == len(tr["v"]):
                    tr["v"] = vis
        self.report.append(f"  {g}: grip gt {entry['gt']}{' (estimated)' if est else ''}, body tracks {n_body}, "
                           f"grip from {len(acts)} action ends")

    def mw_gt_median(self):
        """Median calibration of the MW19 guns that carry both grip tags (MW's fixed gun attach offset)."""
        np = _np()
        import glob as _glob
        vals = []
        for p in _glob.glob(os.path.join(self.build, "clips", "g_*_rel_stand.smd")):
            g = os.path.basename(p)[2:-len("_rel_stand.smd")]
            info = wm_info(self.m, g)
            src = _cache_src(p) or ""
            if not info or src.startswith("iw9_") or "tag_ik_loc_ri" not in info["rel"] or "tag_ik_loc_le" not in info["rel"]:
                continue
            grip = mw_grip([p])
            c = grip and _gun_calib(self.m, g, "ar", grip)
            if c and not c[1] and 3.5 <= c[0][1] <= 8.5:
                vals.append(c[0])
        if not vals:
            return None
        med = [round(float(v), 2) for v in np.median(np.array(vals), axis=0)]
        self.report.append(f"MW attach offset (median of {len(vals)} tagged MW19 guns): {med}")
        return med

    def gun_fingers(self, g, entry, kit):
        """MW's finger poses as local rotations (runtime applies them while the hand holds the gun): fr / fl, fl_<grip>."""
        p = self.smd(f"h_{g}_stand_nonads")
        if not os.path.exists(p):
            return
        fr, fl = finger_locals(p, R_FINGERS), finger_locals(p, L_FINGERS)
        if fr:
            entry["fr"] = fr
        if fl:
            entry["fl"] = fl
        for var in (entry.get("grips") or {}):
            pv = self.smd(f"h_{g}_stand_{var}_nonads")
            if os.path.exists(pv):
                fv = finger_locals(pv, L_FINGERS)
                if fv:
                    entry["fl_" + var] = fv

    def hold_ref(self, cls, st, k):
        """The generic hold the class's aim layers already carry (stand / crouch) or the M4 prone hold: idle x addoff."""
        gc, gg = HOLD_GENERIC.get(cls if st != "prone" else "_", HOLD_GENERIC["_"])
        over = getattr(self, "hold_ref_over", None)
        if over and st != "prone":
            gc, gg = over  # a gun with its own set (minigun): its set's aim layer carries its own hold
        key = f"hr_{gc}_{st}_{k}"
        if key in self.hold_refs:
            return self.hold_refs[key]
        idle, center = HOLD_IDLE[st]
        base = prep.read_seanim(tmb.src_path(self.m, idle))
        add = next((pt.format(c=gc, g=gg, k=k) for pt in HOLD_ADDOFF[st]
                    if exists(self.m, pt.format(c=gc, g=gg, k=k))), None)
        anim = tmb.hold_pose(base, 0)
        if add:
            anim = compose_weighted(base, prep.read_seanim(tmb.src_path(self.m, add)), self.ctx.rest_quat, 0, 1.0)
        path, _ = self.clip(idle, True, anim, key, center)
        name = f"a_{key}"
        self.hold_lines.append(f'$animation "{name}" "{self.rel(path)}" fps {FPS}')
        self.hold_refs[key] = (name, path)
        return self.hold_refs[key]

    def gun_hold(self, g, rip, cls, entry, pose=None):
        """mpm_h_<gun>_<st>: the gun's own hold (addoff) + finger poses as a delta against the class hold, hip / ADS
        blended on mpm_ads. Also the gun's resting gun-bone pose per stance (gunhold_<st>, hip + ads) for placement."""
        fr = getattr(self, "kit_fingers", None) or [f"mp_fingers_{cls}_{rip}_r", f"mp_fingers_{cls}_{rip}_l"]
        fingers = [prep.read_seanim(tmb.src_path(self.m, f)) for f in fr if exists(self.m, f)]
        self.kit_pose = pose or {}
        self.gun_hold_set(g, rip, cls, entry, fingers, "")
        self.kit_pose = {}
        if pose or entry.get("kit"):
            return  # kits never carry MW Base grips
        # grip variants: same hold, the left hand's fingers from the grip's own finger pose
        right = [prep.read_seanim(tmb.src_path(self.m, f)) for f in fr[:1] if exists(self.m, f)]
        gen = HOLD_GENERIC.get(cls, HOLD_GENERIC["_"])
        have = {}
        for var, pats in GRIP_FINGERS.items():
            src = next((pt.format(c=cls, g=rip) for pt in pats if exists(self.m, pt.format(c=cls, g=rip))), None)
            if not src and cls != "pi":
                src = next((pt.format(c=gen[0], g=gen[1]) for pt in pats
                            if exists(self.m, pt.format(c=gen[0], g=gen[1]))), None)
            if not src:
                continue
            try:
                left = prep.read_seanim(tmb.src_path(self.m, src))
                if self.gun_hold_set(g, rip, cls, entry, right + [left], "_" + var):
                    have[var] = src
            except Exception as ex:  # noqa: BLE001 - one bad finger clip must not sink the gun
                self.report.append(f"  {g}: grip {var} ({src}) skipped: {ex}")
        if have:
            entry["grips"] = {v: True for v in have}
            self.report.append(f"  {g}: grips " + ", ".join(f"{v}={c}" for v, c in sorted(have.items())))

    def gun_sprint_hold(self, g, rip, cls, entry, addoff, base_clip="iw9_mp_strafe_sprint_ar_8"):
        """mpm_hs_<gun>: MW's sprint carry for a gun with its own one (the minigun's nonads_sprint offset), on MPM's sprint
        pose, as a delta against that plain sprint pose: the runtime plays it in the hold slot while sprinting (the normal
        hold is dropped there - the minigun showed the rifle sprint carry)."""
        if not (exists(self.m, base_clip) and exists(self.m, addoff)):
            self.report.append(f"  {g}: sprint hold skipped (missing {base_clip} / {addoff})")
            return
        base = prep.read_seanim(tmb.src_path(self.m, base_clip))
        if abs((base["fps"] or 30) - 60) < 0.5:
            base = resample_half(base)
        ref = tmb.hold_pose(base, 0)
        anim = compose_weighted(base, prep.read_seanim(tmb.src_path(self.m, addoff)), self.ctx.rest_quat, 0, 1.0)
        for f in (f"mp_fingers_{cls}_{rip}_r", f"mp_fingers_{cls}_{rip}_l"):
            if exists(self.m, f):
                anim = override_bones(anim, prep.read_seanim(tmb.src_path(self.m, f)))
        rp, _ = self.clip(base_clip, True, ref, f"hsr_{g}", True, cached=True, src_tag=f"{base_clip}+ref")
        hp, _ = self.clip(base_clip, True, anim, f"hs_{g}", True, cached=True, src_tag=f"{base_clip}+{addoff}+fingers")
        seq = f"mpm_hs_{g}"
        self.gun_seqs.setdefault(g, []).append(
            f'$animation "a_hsr_{g}" "{self.rel(rp)}" fps {FPS}\n'
            f'$animation "a_hs_{g}" "{self.rel(hp)}" fps {FPS} subtract "a_hsr_{g}" 0\n'
            f'$sequence "{seq}" {{\n\t"a_hs_{g}"\n\tdelta\n\tweightlist "{UPPER}"\n\tfps {FPS} loop\n}}')
        entry["hold_sprint"] = seq
        self.report.append(f"  {g}: sprint hold {addoff}")

    def gun_hold_set(self, g, rip, cls, entry, fingers, sfx):
        """One hold set (all stances) with the given finger poses; sfx "" = the default hold, "_<grip>" = a variant."""
        made = False
        for st in STANCES:
            idle, center = HOLD_IDLE[st]
            parts, guns = [], {}
            for k in ("nonads", "ads"):
                pats = list((getattr(self, "kit_hold", None) or {}).get(st, [])) + HOLD_ADDOFF[st]
                add = next((pt.format(c=cls, g=rip, k=k) for pt in pats
                            if exists(self.m, pt.format(c=cls, g=rip, k=k))), None)
                kp = getattr(self, "kit_pose", {}).get(st)
                if not add and not fingers and not kp:
                    break
                ref_name, ref_path = self.hold_ref(cls, st, k)
                base = prep.read_seanim(tmb.src_path(self.m, idle))
                if kp:
                    # a kit held in a pose frame of an MW clip (prepped frag, gun-down passive): [candidates], frame
                    src = next((c for c in kp[0] if exists(self.m, c)), None)
                    if not src:
                        break
                    sa = prep.read_seanim(tmb.src_path(self.m, src))
                    if abs((sa["fps"] or 30) - 60) < 0.5:
                        sa = resample_half(sa)
                    anim = tmb.hold_pose(sa, kp[1])
                elif add:
                    anim = compose_weighted(base, prep.read_seanim(tmb.src_path(self.m, add)), self.ctx.rest_quat, 0, 1.0)
                else:
                    # no own offset: the class hold, so only the fingers differ
                    anim = tmb.hold_pose(base, 0)
                    gc, gg = HOLD_GENERIC.get(cls if st != "prone" else "_", HOLD_GENERIC["_"])
                    gadd = next((pt.format(c=gc, g=gg, k=k) for pt in HOLD_ADDOFF[st]
                                 if exists(self.m, pt.format(c=gc, g=gg, k=k))), None)
                    if gadd:
                        anim = compose_weighted(base, prep.read_seanim(tmb.src_path(self.m, gadd)), self.ctx.rest_quat, 0, 1.0)
                for f in fingers:
                    anim = override_bones(anim, f)
                key = f"h_{g}_{st}{sfx}_{k}"
                # cache keyed on what the hold is made of (v0.10.0: keyed on the idle alone, a changed kit hold kept
                # the old clip)
                tag = "+".join([idle, add or "", (kp[0][0] + "@" + str(kp[1])) if kp else ""] + [
                    f.get("_src", "") for f in fingers])
                path, _ = self.clip(idle, True, anim, key, center, cached=True, src_tag=tag)
                name = f"a_{key}"
                self.gun_seqs.setdefault(g, []).append(
                    f'$animation "{name}" "{self.rel(path)}" fps {FPS} subtract "{ref_name}" 0')
                parts.append(name)
                if not sfx:
                    trk = gun_track(path, 99)
                    if trk:
                        guns[k] = trk[:6]
                    lh = left_in_right(path)
                    if lh:
                        guns["lh_" + k] = lh
            if len(parts) == 2:
                made = True
                seq = f"mpm_h_{g}_{st}{sfx}"
                self.gun_seqs.setdefault(g, []).append(
                    f'$sequence "{seq}" {{\n\t"{parts[0]}" "{parts[1]}"\n\tblend "{ADS}" 0 1\n'
                    f'\tdelta\n\tweightlist "{UPPER}"\n\tfps {FPS} loop\n}}')
                if sfx:
                    continue
                entry[f"hold_{st}"] = seq
                if guns.get("nonads"):
                    entry[f"gunhold_{st}"] = guns["nonads"]
                if guns.get("ads"):
                    entry[f"gunads_{st}"] = guns["ads"]
                if guns.get("lh_nonads"):
                    entry[f"lh_{st}"] = guns["lh_nonads"]
                if guns.get("lh_ads"):
                    entry[f"lhads_{st}"] = guns["lh_ads"]
        return made

    def find_dir(self, fmt, n):
        for name in (fmt.format(n), fmt.format(f"{n}_alt")):
            if exists(self.m, name):
                return name
        return None

    def blend8(self, name, fmt, centre, opts=None):
        opts = opts or {}
        c = opts.get("center", True)
        have, info = {}, {}
        for n in DIRVEC:
            clip = self.find_dir(fmt, n)
            if clip:
                have[n], info[n] = self.clip(clip, True, center=c, cycle=not opts.get("air"))
        if 8 not in have:
            raise ValueError(f"{name}: no forward clip for {fmt}")
        if not opts.get("air"):
            self.fix_strides(name, have, info, c)
        for n in DIRVEC:
            if n not in have:
                src = next((k for k in FILL[n] if k in have), 8)
                have[n], info[n] = have[src], dict(info[src], filled=src)
                self.report.append(f"  {name}: dir {n} missing, using {src}")
        lengths = sorted(i["frames"] for i in info.values())
        have[0] = self.pose(centre, 0, c, lengths[len(lengths) // 2])
        files = [self.rel(have[n]) for n in GRID]
        self.seqs.append(self.seq_line(f"mpm_{name}", [files[r * 3:r * 3 + 3] for r in range(3)], True,
                                       self.layer_for(name),
                                       ["\tblendwidth 3", f'\tblend "{PY}" -1 1', f'\tblend "{PX}" -1 1'], name))
        self.data[name] = {"seq": f"mpm_{name}", "kind": "blend8", "dirs": info}
        if opts.get("air"):
            self.data[name]["air"] = True

    def fix_strides(self, name, have, info, center):
        """Directions whose single stride came out far off the blend's median (notes missing or doubled): too short
        -> rebuilt spanning at least 70% of the median; too long (~2 strides kept) -> cut in half."""
        lens = sorted(i["frames"] for i in info.values())
        med = lens[len(lens) // 2]
        for n in list(have):
            f = info[n]["frames"]
            if f < 0.6 * med:
                have[n], info[n] = self.clip(info[n]["from"], True, center=center, cycle=True,
                                             min_gap=int(0.7 * med))
                g = info[n]["frames"]
                if not 0.6 * med <= g <= 1.6 * med:
                    del have[n], info[n]  # still no clean stride: the neighbouring direction stands in
                    self.report.append(f"  {name}: dir {n} stride {f} fr << median {med}: no clean stride, dropped")
                else:
                    self.report.append(f"  {name}: dir {n} stride {f} fr << median {med}: rebuilt -> {g} fr")
            elif f > 1.6 * med:
                smd = prep.read_smd(have[n])
                prep.fill_frames(smd)
                half = (f - 1) // 2 + 1
                smd.frames = smd.frames[:half]
                prep.write_smd(have[n], smd)
                i = dict(info[n], frames=half, dur=round((half - 1) / FPS, 3))
                i["lplant"], i["rplant"] = [0, 1], [r * 2 for r in i["rplant"] if r <= 0.5] or [0.5]
                info[n] = i
                self.report.append(f"  {name}: dir {n} stride {f} fr >> median {med}: halved -> {half} fr")

    def fwd3(self, name, fmt):
        have, info = {}, {}
        for n in (7, 8, 9):
            clip = self.find_dir(fmt, n)
            if clip:
                have[n], info[n] = self.clip(clip, True, cycle=True)
        if 8 not in have:
            raise ValueError(f"{name}: no forward clip for {fmt}")
        for n in (7, 9):
            if n not in have:
                have[n], info[n] = have[8], dict(info[8], filled=8)
        self.seqs.append(self.seq_line(f"mpm_{name}", [[self.rel(have[n]) for n in (9, 8, 7)]], True,
                                       self.layer_for(name), ["\tblendwidth 3", f'\tblend "{PY}" -1 1'], name))
        self.data[name] = {"seq": f"mpm_{name}", "kind": "fwd3", "dirs": info}

    def oneshot(self, name, fmt, dirs, opts=None):
        """One sequence per numpad direction (starts / stops): mpm_<name>_<n>, with distance curves."""
        opts = opts or {}
        info = {}
        for n in dirs:
            clip = self.find_dir(fmt, n)
            if not clip:
                continue
            path, i = self.clip(clip, False, center=opts.get("center", True))
            seq = f"mpm_{name}_{n}"
            self.seqs.append(self.seq_line(seq, self.rel(path), False, self.layer_for(name), None, name))
            i["seq"] = seq
            info[n] = i
        if not info:
            raise ValueError(f"{name}: no clips for {fmt}")
        self.data[name] = {"seq": f"mpm_{name}", "kind": "oneshot", "dirs": info}

    def single(self, name, clip, opts):
        loop = opts.get("loop", True)
        path, info = self.clip(clip, loop, center=opts.get("center", True))
        self.seqs.append(self.seq_line(f"mpm_{name}", self.rel(path), loop, self.layer_for(name), None, name))
        self.data[name] = dict({"seq": f"mpm_{name}", "kind": "single"}, **info)

    def mantles(self, clips):
        ref = self.idle_ankle()
        made = 0
        for clip in clips:
            if clip.endswith("_up_run") and clip[len("mp_mantle_"):].split("_")[0] in ("56", "64"):
                continue
            if not exists(self.m, clip):
                continue
            key = "mantle_" + clip[len("mp_mantle_"):]
            path, info = self.clip(clip, False, center=True)
            anim = prep.read_seanim(tmb.src_path(self.m, clip))
            rt = prep.root_track(anim)
            n = min(len(rt), info["frames"])
            idx = list(range(0, n, 2))
            if idx[-1] != n - 1:
                idx.append(n - 1)
            ft = []
            for _f, W in smd_world(path, [0, info["frames"] - 1]):
                la, ra = W["ValveBiped.Bip01_L_Foot"][:3, 3], W["ValveBiped.Bip01_R_Foot"][:3, 3]
                cod = prep.mat_vec(prep.SMD_TO_COD, [float(la[0] + ra[0]) / 2, float(la[1] + ra[1]) / 2, 0.0])
                ft.append([round(cod[0], 2), round(cod[1], 2), round(float(min(la[2], ra[2])) - ref, 2)])
            mtn = re.match(r"^(far_)?(?:(step|climb|boost)_)?(\d+)_(up|over)(?:_(idle|run))?$", key[len("mantle_"):])
            far, style, nh, ov, gait = mtn.groups()
            mt = [[round(rt[i][0], 2), round(rt[i][1], 2), round(rt[i][2], 2)] for i in idx]
            info.update({"kind": "mantle", "seq": f"mpm_{key}", "f0": ft[0], "fe": ft[-1], "mt": mt,
                         "nh": int(nh), "over": ov == "over", "far": bool(far), "style": style or "ledge",
                         "run": gait == "run" or (gait is None and bool(far)),
                         "peak": round(max(v[2] for v in mt), 1), "reach": round(mt[-1][0], 1)})
            self.seqs.append(self.seq_line(f"mpm_{key}", self.rel(path), False, None, None, key))
            self.data[key] = info
            made += 1
        self.report.append(f"mantles: {made} clips")

    def idle_ankle(self):
        if getattr(self, "_ankle", None) is None:
            p = self.pose(HOLD_IDLE["stand"][0], 0, True, 2)
            W = smd_world(p, [0])[0][1]
            self._ankle = float(min(W["ValveBiped.Bip01_L_Foot"][2, 3], W["ValveBiped.Bip01_R_Foot"][2, 3]))
        return self._ankle

    def slope_layer(self, name, base_fmt, lean_fmt):
        anims = {}
        for n in DIRVEC:
            b, l = self.find_dir(base_fmt, n), self.find_dir(lean_fmt, n)
            if b and l:
                anims[n] = (self.pose(b, 0, True, 2), self.pose(l, 0, True, 2))
        if 8 not in anims:
            raise ValueError(f"{name}: no forward lean")
        lines = []
        for n in DIRVEC:
            bp, lp = anims.get(n) or anims[next((k for k in FILL[n] if k in anims), 8)]
            lines.append(f'$animation "a_{name}_b{n}" "{self.rel(bp)}" fps {FPS}')
            lines.append(f'$animation "a_{name}_{n}" "{self.rel(lp)}" fps {FPS} subtract "a_{name}_b{n}" 0')
        lines.append(f'$animation "a_{name}_c" "{self.rel(anims[8][0])}" fps {FPS} subtract "a_{name}_b8" 0')
        cells = [f"a_{name}_c" if n == 0 else f"a_{name}_{n}" for n in GRID]
        rows = "\n".join("\t" + " ".join(f'"{c}"' for c in cells[r * 3:r * 3 + 3]) for r in range(3))
        lines.append(f'$sequence "mpm_{name}" {{\n{rows}\n\tblendwidth 3\n\tblend "{PY}" -1 1\n\tblend "{PX}" -1 1\n'
                     f'\tdelta\n\tfps {FPS} loop\n}}')
        self.seqs.extend(lines)
        self.data[name] = {"seq": f"mpm_{name}", "kind": "layer"}
        self.report.append(f"slope layer {name}: {len(anims)} directions")

    def pains(self, stances):
        import glob as _glob
        names = set()
        for d in [self.m["SOURCE"]] + list(self.m.get("EXTRA_SOURCES", [])):
            for f in _glob.glob(os.path.join(d, "sdr_mp_pain_sub_*.seanim")):
                names.add(os.path.basename(f)[:-len(".seanim")])
        rx = re.compile(r"^sdr_mp_pain_sub_(stand|strafe_crouch|prone)_([a-z]+?)(?:_([a-z_]+?))?_(\d\d)(_noarm)?$")
        pick = {}
        for nm in sorted(names):
            mt = rx.match(nm)
            if not mt:
                continue
            st, part, dr, num, noarm = mt.groups()
            k = (st, part, dr or "c", num)
            if noarm or k not in pick:
                pick[k] = nm
        table, made = {}, 0
        for (st, part, dr, num), clip in sorted(pick.items()):
            idle = stances.get(st)
            if not idle or not exists(self.m, idle):
                continue
            try:
                src = prep.read_seanim(tmb.src_path(self.m, clip))
                delta = dict(src, bones={bn: {"rot": b["rot"]} for bn, b in src["bones"].items()
                                         if b.get("rot") and not bn.startswith(("tag_", "j_gun"))})
                anim = tmb.additive_on(tmb.hold_pose(prep.read_seanim(tmb.src_path(self.m, idle)), 0), delta,
                                       self.ctx.rest_quat)
                anim = dict(anim, frames=max(2, anim["frames"]), looped=False)
                key = f"pn_{st}_{part}_{dr}_{num}"
                path, info = self.clip(idle, False, anim, key, True, cached=True, src_tag=f"{idle}+{clip}")
            except Exception as ex:
                self.report.append(f"  pain {clip}: skipped ({ex})")
                continue
            rel = self.rel(path)
            seq = f"mpm_{key}"
            self.gun_seqs.setdefault("~pain", []).append(
                f'$animation "a_{key}_ref" "{rel}" fps {FPS} frames 0 0\n'
                f'$animation "a_{key}" "{rel}" fps {FPS} subtract "a_{key}_ref" 0\n'
                f'$sequence "{seq}" {{\n\t"a_{key}"\n\tdelta\n\tfps {FPS}\n}}')
            table.setdefault(st, {}).setdefault(part, {}).setdefault(dr, []).append(
                {"seq": seq, "dur": info["dur"], "from": clip})
            made += 1
        self.data["pain"] = table
        self.report.append(f"pains: {made} flinch clips")

    def run(self):
        m = self.m
        jobs = ([("aim", k, v) for k, v in m.get("AIMS", {}).items()]
                + [("blend8", k, v) for k, v in m.get("BLEND8", {}).items()]
                + [("fwd3", k, v) for k, v in m.get("FWD3", {}).items()]
                + [("single", k, v) for k, v in m.get("SINGLE", {}).items()]
                + [("oneshot", k, v) for k, v in m.get("ONESHOT", {}).items()]
                + [("guns", k, v) for k, v in m.get("GUNS", {}).items()])
        failed = 0
        for kind, name, v in jobs:
            try:
                if kind == "aim":
                    self.aim_grid(name, v[0], v[1], v[2] if len(v) > 2 else None)
                elif kind == "blend8":
                    self.blend8(name, v[0], v[1], v[2] if len(v) > 2 else None)
                elif kind == "fwd3":
                    self.fwd3(name, v)
                elif kind == "guns":
                    self.guns(v)
                elif kind == "oneshot":
                    self.oneshot(name, v[0], v[1], v[2] if len(v) > 2 else None)
                else:
                    self.single(name, v[0], v[1] if len(v) > 1 else {})
            except Exception as ex:  # noqa: BLE001
                failed += 1
                self.report.append(f"{name}: FAILED {ex}")
        for job, fn in (("mantles", lambda: self.mantles(m.get("MANTLES", []))),
                        ("slopes", lambda: [self.slope_layer(k, *v) for k, v in m.get("SLOPE_DOWN", {}).items()]),
                        ("pains", lambda: self.pains(m.get("PAIN", {})))):
            try:
                fn()
            except Exception as ex:
                failed += 1
                self.report.append(f"{job}: FAILED {ex}")
        self.class_sets()
        return failed

    def class_sets(self):
        """CLASS_SETS: every rifle ("_ar") sequence set cloned for another weapon class with that class's aim layers
        (MW reuses the same legs for every gun and swaps the upper body additively: a pistol's hold offset on the
        shared base is a two-handed pistol grip). Same $animations, new sequences, so the model barely grows.
        Sets the class has its own clips for (e.g. sprint_pi) are kept."""
        import fnmatch
        rx = re.compile(r"_ar(?=_|$)")
        for cls, cfg in self.m.get("CLASS_SETS", {}).items():
            lay = cfg.get("layers", {})
            inc = cfg.get("include", ["*_ar"])
            made = 0
            for sp in list(self.specs):
                sn = sp["set"]
                if not sn or not sn.endswith("_ar") or not any(fnmatch.fnmatch(sn, p) for p in inc):
                    continue
                new_set = rx.sub("_" + cls, sn)
                if new_set in self.data and not self.data[new_set].get("_clone"):
                    continue  # the class has its own clips for this set
                self.seqs.append(self.seq_line(rx.sub("_" + cls, sp["seq"]), sp["files"], sp["loop"],
                                               lay.get(sp["layer"], sp["layer"]), sp["blend"], None))
                made += 1
            for sn in list(self.data):
                if sn.endswith("_ar") and any(fnmatch.fnmatch(sn, p) for p in inc):
                    new_set = rx.sub("_" + cls, sn)
                    if new_set in self.data:
                        continue
                    e = copy.deepcopy(self.data[sn])

                    def fix(v):
                        if isinstance(v, dict):
                            return {k: (rx.sub("_" + cls, x) if k == "seq" and isinstance(x, str) else fix(x))
                                    for k, x in v.items()}
                        return v
                    e = fix(e)
                    e["_clone"] = True
                    self.data[new_set] = e
            self.report.append(f"class set {cls}: {made} sequences cloned from the rifle set")

    def qc_head(self, modelname, body):
        lines = ["// Generated by mpm_build.py (Modern Player Motion). Do not edit by hand.",
                 f'$modelname "{modelname}"', f'$body "body" "{body}"', '$surfaceprop "flesh"']
        if self.gun:
            lines.append('$bonemerge "j_gun"')
        wl = tmb.weightlist(self.ctx.tgt.nodes + ([("j_gun", -1)] if self.gun else []))
        wl[0] = wl[0].replace('"tif_upper"', f'"{UPPER}"')
        lines += [""] + wl
        lines += ["", f'$poseparameter "{PX}" -1 1', f'$poseparameter "{PY}" -1 1',
                  f'$poseparameter "{AY}" -90 90', f'$poseparameter "{AP}" -90 90',
                  f'$poseparameter "{ADS}" 0 1', ""]
        return lines

    def write_gun_qcs(self, body, parts=3):
        """The per-gun actions + holds split over several models (32-bit studiomdl ran out of memory on one): each
        carries its own copy of the aim layers (a sequence's addlayer / blendlayer must be in the same model)."""
        guns = sorted(self.gun_seqs)
        if not guns:
            return []
        size = (len(guns) + parts - 1) // parts
        out = []
        for i in range(parts):
            chunk = guns[i * size:(i + 1) * size]
            if not chunk:
                continue
            name = f"mpm_guns{i + 1}"
            lines = self.qc_head(f"mpm/{name}.mdl", body)
            lines += [f'$sequence "{name}_ref" "{body}" fps 1', ""] + self.aims + [""] + self.hold_lines + [""]
            for g in chunk:
                lines += self.gun_seqs[g]
            qc = os.path.join(self.build, f"{name}.qc")
            with open(qc, "w", encoding="utf-8", newline="\n") as f:
                f.write("\n".join(lines) + "\n")
            out.append((qc, f"mpm/{name}.mdl"))
        return out

    def write_qc(self):
        tgt = self.m.get("TARGET", tmb.DEFAULT_TARGET)
        body = "reference.smd"
        tmb.copy_with_gun(tgt, os.path.join(self.build, body), self.gun)
        self.gun_qcs = self.write_gun_qcs(body)
        lines = ["// Generated by mpm_build.py (Modern Player Motion). Do not edit by hand.",
                 '$modelname "mpm/mpm_anims.mdl"', f'$body "body" "{body}"', '$surfaceprop "flesh"']
        if self.gun:
            lines.append('$bonemerge "j_gun"')
        wl = tmb.weightlist(self.ctx.tgt.nodes + ([("j_gun", -1)] if self.gun else []))
        wl[0] = wl[0].replace('"tif_upper"', f'"{UPPER}"')
        lines += [""] + wl
        lines += ["", f'$poseparameter "{PX}" -1 1', f'$poseparameter "{PY}" -1 1',
                  f'$poseparameter "{AY}" -90 90', f'$poseparameter "{AP}" -90 90',
                  f'$poseparameter "{ADS}" 0 1', "",
                  f'$sequence "mpm_ref" "{body}" fps 1', ""] + self.aims + [""] + self.anim_lines + [""] \
            + self.seqs + [""] + [f'$includemodel "{mdl}"' for _, mdl in self.gun_qcs]
        qc = os.path.join(self.build, "mpm_anims.qc")
        with open(qc, "w", encoding="utf-8", newline="\n") as f:
            f.write("\n".join(lines) + "\n")
        return qc

    def write_lua(self, addon):
        path = os.path.join(addon, "lua", "mpm", "data", "clips.lua")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        lines = ["-- Generated by mpm_build.py: MW clips retargeted to ValveBiped. Do not edit by hand.",
                 "-- speed u/s, dir deg (0 fwd, + left), dur s, lplant/rplant 0..1 of the cycle.",
                 "MPM.Clips = MPM.Clips or {}",
                 f"MPM.ClipParams = {{ mx = \"{PX}\", my = \"{PY}\" }}"]
        for name in sorted(self.data):
            e = {k: v for k, v in self.data[name].items() if k != "_clone"}
            if "dirs" in e:
                dirs = ", ".join(f"[{n}] = {tmb.lua_val(d)}" for n, d in sorted(e["dirs"].items()))
                lines.append(f'MPM.Clips["{name}"] = {{ seq = "{e["seq"]}", kind = "{e["kind"]}", dirs = {{ {dirs} }} }}')
            else:
                lines.append(f'MPM.Clips["{name}"] = {tmb.lua_val(e)}')
        if self.gun_table:
            lines.append("-- per-gun weapon actions (mpm_g_<gun>_<act>_<stance>): rel / emp / insp / raise x stand / crouch / prone")
            lines.append("MPM.Guns = MPM.Guns or {};")
            for g in sorted(self.gun_table):
                # own function per gun: LuaJIT allows 65536 constants per function (TIF hit it once)
                lines.append(f'(function() MPM.Guns["{g}"] = {tmb.lua_val(self.gun_table[g])} end)();')
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write("\n".join(lines) + "\n")
        return path


def compile_qc(qc, addon):
    r = subprocess.run([tmb.STUDIOMDL, "-game", GAMEDIR, "-nop4", "-nox360", qc], capture_output=True, text=True,
                       errors="replace")
    ok = any(l.startswith("Completed") for l in r.stdout.splitlines())
    bad = [l for l in r.stdout.splitlines() if "ERROR" in l or "WARNING" in l]
    print(f"compile {os.path.basename(qc)}: {'ok' if ok else 'FAILED'}" + "".join("\n   " + l for l in bad[:10]))
    if not ok:
        print(r.stdout[-3000:])
        sys.exit(1)
    src = os.path.join(GAMEDIR, "models", "mpm")
    dst_dir = os.path.join(addon, "models", "mpm")
    os.makedirs(dst_dir, exist_ok=True)
    for fn in os.listdir(src):
        dst = os.path.join(dst_dir, fn)
        if os.path.exists(dst):
            os.remove(dst)
        shutil.move(os.path.join(src, fn), dst)
    os.rmdir(src)
    print(f"models -> {dst_dir}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("manifest")
    ap.add_argument("--compile", action="store_true")
    ap.add_argument("--no-patch", action="store_true", help="don't write the patched m_anm / f_anm")
    args = ap.parse_args()
    m = runpy.run_path(args.manifest)
    os.makedirs(m["BUILD"], exist_ok=True)
    b = Builder(m)
    failed = b.run()
    print("\n".join(b.report))
    qc = b.write_qc()
    lua = b.write_lua(m["ADDON"])
    with open(os.path.join(m["BUILD"], "report.txt"), "w", encoding="utf-8") as f:
        f.write("\n".join(b.report) + "\n")
    print(f"{len(b.data)} sequences ({failed} failed) -> {qc}, {lua}")
    if not args.no_patch:
        patch_anm(m["ADDON"])
    if args.compile:
        for gqc, _ in b.gun_qcs:
            compile_qc(gqc, m["ADDON"])
        compile_qc(qc, m["ADDON"])


if __name__ == "__main__":
    main()
