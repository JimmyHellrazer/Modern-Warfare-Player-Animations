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
anim_data = os.path.join(addon, "lua", "mpm", "data", "clips.lua")
if os.path.exists(anim_data):
    lua.execute(lua_file(anim_data))
    lua.execute(lua_file(os.path.join(addon, "lua", "mpm", "sh_anim.lua")))
    lua.execute(lua_file(os.path.join(addon, "lua", "mpm", "sh_anim_trans.lua")))
    lua.execute(lua_file(os.path.join(addon, "lua", "mpm", "sh_anim_guns.lua")))
    lua.execute(lua_file(os.path.join(addon, "lua", "mpm", "sh_flinch.lua")))
    for tf in ("anim_tests.lua", "trans_tests.lua", "guns_tests.lua", "p789_tests.lua"):
        extra = lua.execute(lua_file(os.path.join(here, tf)))
        for i in range(1, len(extra) + 1):
            tests[len(tests) + 1] = extra[i]
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
print(f"{passed}/{total}")
