"""Read a finger recording from mpm_track_finger (garrysmod/data/mpm_booth/finger_*.json; newest by default) and
show what the right fingers did: per joint the bend (+ = backwards) as the animation gave it vs after MPM, frame-to-frame
jumps, and a plot (out/finger_track.png).
Usage: python finger_track.py [file.json]"""
import glob
import json
import os
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

BOOTH = r"K:/SteamLibrary/steamapps/common/GarrysMod/garrysmod/data/mpm_booth"
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")
os.makedirs(OUT, exist_ok=True)
JOINTS = ["R_Finger1", "R_Finger11", "R_Finger12"]


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else max(glob.glob(os.path.join(BOOTH, "finger_*.json")), key=os.path.getmtime)
    d = json.load(open(path))
    fr = d["frames"]
    print(f"{os.path.basename(path)}: {len(fr)} frames, {d.get('weapon')} on {d.get('model')}")
    t = [f["t"] for f in fr]
    fig, axes = plt.subplots(len(JOINTS) + 1, 1, figsize=(12, 3 * (len(JOINTS) + 1)), sharex=True)
    worst = []
    for ax, j in zip(axes, JOINTS):
        for ph, col in (("anim", "tab:orange"), ("final", "tab:blue")):
            ys = [f.get(ph, {}).get(j, {}).get("bend") for f in fr]
            ax.plot(t, [y if y is not None else float("nan") for y in ys], color=col, label=f"{j} {ph}")
            for i in range(1, len(ys)):
                if ys[i] is not None and ys[i - 1] is not None and abs(ys[i] - ys[i - 1]) > 25:
                    worst.append((abs(ys[i] - ys[i - 1]), j, ph, t[i], ys[i - 1], ys[i], fr[i].get("action")))
        ax.axhline(0, color="k", lw=0.5)
        ax.set_ylabel("bend deg (+ back)")
        ax.legend(loc="upper right", fontsize=7)
    ax = axes[-1]
    for k, col in (("act_w", "k"), ("right_fingers", "tab:green"), ("letgo", "tab:red"), ("right_ik", "tab:purple")):
        ax.plot(t, [f.get(k) if f.get(k) is not None else float("nan") for f in fr], color=col, label=k)
    ax.plot(t, [(f.get("action") or {}).get("cycle", float("nan")) for f in fr], color="0.6", ls="--", label="cycle")
    ax.legend(loc="upper right", fontsize=7)
    ax.set_xlabel("seconds")
    fig.tight_layout()
    out = os.path.join(OUT, "finger_track.png")
    fig.savefig(out, dpi=70)
    print("plot:", out)
    print("biggest one-frame jumps:")
    for w in sorted(worst, reverse=True)[:12]:
        print(f"  {w[1]:11s} {w[2]:5s} t {w[3]:6.3f}  {w[4]:7.1f} -> {w[5]:7.1f}  ({w[0]:.0f} deg)  action {w[6]}")
    # layer changes over the recording (what was layered on the player when the fingers moved)
    prev = None
    print("layer / main sequence changes:")
    for f in fr:
        cur = (f.get("main"), tuple((l[1], round(l[2], 1)) for l in f.get("layers") or []))
        if cur != prev:
            print(f"  t {f['t']:6.3f}  main {cur[0]}  layers {list(cur[1])}")
            prev = cur
    back = [(f["t"], j, f["final"][j]["bend"]) for f in fr for j in JOINTS
            if f.get("final", {}).get(j, {}).get("bend", 0) > 5]
    print(f"frames with a joint bent backwards after MPM: {len(back)}", back[:8])


if __name__ == "__main__":
    main()
