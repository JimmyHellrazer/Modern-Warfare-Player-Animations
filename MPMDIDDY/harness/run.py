"""Offline harness for addons/modern_player_motion: LuaJIT (lupa) + mocked GMod. Usage: python -I run.py <addon_dir>"""
import os
import sys
from lupa.luajit21 import LuaRuntime

here = os.path.dirname(os.path.abspath(__file__))
addon = sys.argv[1]

lua = LuaRuntime(unpack_returned_tuples=True)
g = lua.globals()


def lua_file(p):
    with open(p, encoding="utf-8") as f:
        return f.read()


lua.execute(lua_file(os.path.join(here, "env.lua")))
g.MPM = lua.table()
for f in ["sh_config.lua", "sh_state.lua", "sh_input.lua", "sh_move.lua", "sh_mantle.lua"]:
    lua.execute(lua_file(os.path.join(addon, "lua", "mpm", f)))

tests = lua.execute(lua_file(os.path.join(here, "tests.lua")))
data_dir = os.path.join(addon, "lua", "mpm", "data")
parts = sorted(f for f in os.listdir(data_dir) if f.startswith("clips_p") and f.endswith(".lua")) if os.path.isdir(data_dir) else []
if not parts and os.path.exists(os.path.join(data_dir, "clips.lua")):
    parts = ["clips.lua"]
if parts:
    for f in parts:
        lua.execute(lua_file(os.path.join(data_dir, f)))
    lua.execute(lua_file(os.path.join(addon, "lua", "mpm", "sh_anim.lua")))
    lua.execute(lua_file(os.path.join(addon, "lua", "mpm", "sh_anim_trans.lua")))
    lua.execute(lua_file(os.path.join(addon, "lua", "mpm", "sh_anim_guns.lua")))
    lua.execute(lua_file(os.path.join(addon, "lua", "mpm", "sh_flinch.lua")))
    for tf in ("anim_tests.lua", "trans_tests.lua", "guns_tests.lua", "p789_tests.lua"):
        extra = lua.execute(lua_file(os.path.join(here, tf)))
        for i in range(1, len(extra) + 1):
            tests[len(tests) + 1] = extra[i]
LUA_LIMIT = 200 * 1024
big = []
for root, _, files in os.walk(os.path.join(addon, "lua")):
    for f in files:
        if f.endswith(".lua") and os.path.getsize(os.path.join(root, f)) > LUA_LIMIT:
            big.append(f"{f} {os.path.getsize(os.path.join(root, f)) // 1024} KB")
size_ok = not big
print(("PASS" if size_ok else "FAIL"), "every addon Lua file <= 200 KB (big files never reach MP clients)", "|",
      ", ".join(big) or f"{sum(1 for _ in os.walk(addon))} dirs checked")
passed = 0
total = len(tests)
for i in range(1, total + 1):
    name, fn = tests[i][1], tests[i][2]
    try:
        ok, detail = fn()
    except Exception as e:  # noqa: BLE001
        ok, detail = False, "ERROR " + str(e)
    passed += bool(ok)
    print(("PASS" if ok else "FAIL"), name, "|", detail)
print(f"{passed + size_ok}/{total + 1}")
