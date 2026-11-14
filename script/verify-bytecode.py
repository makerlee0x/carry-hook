#!/usr/bin/env python3
"""Check that this repo builds the exact bytecode deployed on Robinhood Chain mainnet.

Run `forge build` first, then: python3 script/verify-bytecode.py [RPC]
Masked before comparing: immutables (constructor values such as the PoolManager), the CarryBooks link address,
and the library's own address (Solidity's call guard). Everything else must match byte for byte.
"""
import json, subprocess, sys

RPC = sys.argv[1] if len(sys.argv) > 1 else "https://rpc.mainnet.chain.robinhood.com"
CONTRACTS = [
    ("CarryStrategy", "0x5800dd5c9D56C1DC9e6eB05892a6BA8e039B2A88"),
    ("CarryBooks", "0xda9313469414432b21edcfdd874ba448153901e2"),
    ("CarryStrategyAdapter", "0xF8746E93eA69D8DE73b9D141e3552B1d84BaF185"),
    ("CarryLens", "0x25A1971df57D4848d7c7a5ED4880cAbaDBDE2fBa"),
]

def code(addr):
    out = subprocess.check_output(["cast", "code", addr, "--rpc-url", RPC]).decode().strip()
    return bytearray.fromhex(out[2:])

ok = True
for name, addr in CONTRACTS:
    art = json.load(open(f"out/{name}.sol/{name}.json"))["deployedBytecode"]
    local = bytearray.fromhex(art["object"][2:].replace("__$", "000").replace("$__", "000")) if "__$" in art["object"] \
        else bytearray.fromhex(art["object"][2:])
    chain = code(addr)
    masks = [(p["start"], p["length"]) for r in (art.get("immutableReferences") or {}).values() for p in r]
    masks += [(p["start"], 20) for f in (art.get("linkReferences") or {}).values() for ps in f.values() for p in ps]
    if name == "CarryBooks":
        masks.append((chain.find(bytes.fromhex(addr[2:].lower())), 20))
    for s, n in masks:
        local[s:s + n] = b"\0" * n
        chain[s:s + n] = b"\0" * n
    same = len(local) == len(chain) and local == chain
    ok &= same
    print(f"{name:22} {addr}  {len(chain):6} bytes  {'MATCH' if same else 'DIFFERENT'}")
sys.exit(0 if ok else 1)
