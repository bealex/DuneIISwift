#!/usr/bin/env python3
"""One-off generator: emit the Swift UnitInfo / StructureInfo table literals from the OpenDUNE
golden fixtures. Not part of the build — the committed Swift is golden-tested against these same
fixtures (and spot-checked against hand-known values). Re-run if the tables ever change:
    python3 .gen_tables.py units    > /tmp/units.swift
    python3 .gen_tables.py structs  > /tmp/structs.swift
"""
import json, sys, os

DIR = os.path.dirname(os.path.abspath(__file__))

OBJ_FLAGS = ["hasShadow","factory","notOnConcrete","busyStateIsIncoming","blurTile","hasTurret",
             "conquerable","canBePickedUp","noMessageOnDeath","tabSelectable","scriptNoSlowdown",
             "targetAir","priority"]
UNIT_FLAGS = ["isBullet","explodeOnDeath","sonicProtection","canWobble","isTracked","isGroundUnit",
              "mustStayInMap","firesTwice","impactOnSand","isNotDeviatable","hasAnimationSet",
              "notAccurate","isNormalUnit"]
ACTION = ["attack","move","retreat","guard_","areaGuard","harvest","`return`","stop","ambush",
          "sabotage","die","hunt","deploy","destruct"]
MOVEMENT = ["foot","tracked","harvester","wheeled","winger","slither"]
DISPLAY = ["singleFrame","unit","rocket","infantry3Frames","infantry4Frames","ornithopter"]
LAYOUT = ["layout1x1","layout2x1","layout1x2","layout2x2","layout2x3","layout3x2","layout3x3"]

def load(name):
    with open(os.path.join(DIR, name)) as f:
        return [json.loads(line) for line in f if line.strip()]

def flag_set(d, names):
    on = [".%s" % n for i, n in enumerate(names) if d[n]]
    return "[%s]" % ", ".join(on)

def actions(arr):
    return "[%s]" % ", ".join(".%s" % ACTION[a] for a in arr)

def swift_str(s):
    return '"%s"' % s

def obj(d):
    wsa = swift_str(d["wsa"]) if d["wsa"] is not None else "nil"
    return (
        "        o: makeObjectInfo({sa}, {nm}, {sf}, {wsa}, {fl},\n"
        "            spawnChance: {spawnChance}, hitpoints: {hitpoints}, "
        "fogUncoverRadius: {fog}, spriteID: {spriteID},\n"
        "            buildCredits: {buildCredits}, buildTime: {buildTime}, "
        "availableCampaign: {avC},\n"
        "            structuresRequired: {strReq}, sortPriority: {sortPriority}, "
        "upgradeLevelRequired: {upLvl},\n"
        "            actionsPlayer: {act}, available: {available}, hintStringID: {hint},\n"
        "            priorityBuild: {priorityBuild}, priorityTarget: {priorityTarget}, "
        "availableHouse: {avH})"
    ).format(sa=d["stringID_abbrev"], nm=swift_str(d["name"]), sf=d["stringID_full"], wsa=wsa,
             fl=flag_set(d["objectFlags"], OBJ_FLAGS), spawnChance=d["spawnChance"],
             hitpoints=d["hitpoints"], fog=d["fogUncoverRadius"], spriteID=d["spriteID"],
             buildCredits=d["buildCredits"], buildTime=d["buildTime"], avC=d["availableCampaign"],
             strReq=d["structuresRequired"], sortPriority=d["sortPriority"], upLvl=d["upgradeLevelRequired"],
             act=actions(d["actionsPlayer"]), available=d["available"], hint=d["hintStringID"],
             priorityBuild=d["priorityBuild"], priorityTarget=d["priorityTarget"], avH=d["availableHouse"])

def gen_units():
    rows = load("unitinfo-golden.jsonl")
    out = []
    for d in rows:
        out.append("    /* %d %s */ UnitInfo(\n%s,\n"
                   "        indexStart: %d, indexEnd: %d, flags: %s,\n"
                   "        dimension: %d, movementType: .%s, animationSpeed: %d, "
                   "movingSpeedFactor: %d,\n"
                   "        turningSpeed: %d, groundSpriteID: %d, turretSpriteID: %d, "
                   "actionAI: %d, displayMode: .%s,\n"
                   "        destroyedSpriteID: %d, fireDelay: %d, fireDistance: %d, damage: %d, "
                   "explosionType: %d,\n"
                   "        bulletType: %d, bulletSound: %d)" % (
                       d["index"], d["name"], obj(d), d["indexStart"], d["indexEnd"],
                       flag_set(d["unitFlags"], UNIT_FLAGS), d["dimension"], MOVEMENT[d["movementType"]],
                       d["animationSpeed"], d["movingSpeedFactor"], d["turningSpeed"],
                       d["groundSpriteID"], d["turretSpriteID"], d["actionAI"], DISPLAY[d["displayMode"]],
                       d["destroyedSpriteID"], d["fireDelay"], d["fireDistance"], d["damage"],
                       d["explosionType"], d["bulletType"], d["bulletSound"]))
    print(",\n".join(out))

def gen_structs():
    rows = load("structureinfo-golden.jsonl")
    out = []
    for d in rows:
        bu = "[%s]" % ", ".join(str(x) for x in d["buildableUnits"])
        ai = "[%s]" % ", ".join(str(x) for x in d["animationIndex"])
        uc = "[%s]" % ", ".join(str(x) for x in d["upgradeCampaign"])
        out.append("    /* %d %s */ StructureInfo(\n%s,\n"
                   "        enterFilter: %d, creditsStorage: %d, powerUsage: %d, layout: .%s,\n"
                   "        iconGroup: %d, animationIndex: %s, buildableUnits: %s, "
                   "upgradeCampaign: %s)" % (
                       d["index"], d["name"], obj(d), d["enterFilter"], d["creditsStorage"],
                       d["powerUsage"], LAYOUT[d["layout"]], d["iconGroup"], ai, bu, uc))
    print(",\n".join(out))

if sys.argv[1] == "units":
    gen_units()
else:
    gen_structs()
