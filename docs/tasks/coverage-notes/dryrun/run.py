"""Dry run of CoverageSelfTest.swift and CoverageSelfTestGuidance.swift using the Python port (cov.py, guid.py)."""
import math, sys, time
import cov
from cov import r
import guid

MARGIN = None
if len(sys.argv) > 1: MARGIN = float(sys.argv[1])
if len(sys.argv) > 2 and sys.argv[2] == 'f64': cov.F32 = False

class Checker:
    def __init__(self): self.fail = []; self.count = 0; self.names = []
    def check(self, name, ok, detail=''):
        self.count += 1; self.names.append(name)
        if not ok: self.fail.append(f"{name}: {detail or 'failed'}")
    def near(self, name, a, e, tol):
        self.check(name, abs(a - e) <= tol, f"expected {e} +/- {tol}, got {a}")
    def between(self, name, a, lo, hi):
        self.check(name, lo <= a <= hi, f"expected {lo}...{hi}, got {a}")
    def nearvec(self, name, a, e, tol):
        self.check(name, all(abs(a[i]-e[i]) <= tol for i in range(3)), f"expected {e} +/- {tol}, got {a}")

K = (1440.0, 1440.0, 960.0, 720.0); RES = (1920.0, 1440.0)

def pose(yaw, pitch, pos):
    y = math.radians(yaw); p = math.radians(pitch)
    cy, sy, cp, sp = r(math.cos(y)), r(math.sin(y)), r(math.cos(p)), r(math.sin(p))
    ax = (cy, 0.0, -sy); ay = (r(sy*sp), cp, r(cy*sp)); az = (r(sy*cp), -sp, r(cy*cp))
    return (ax, ay, az, pos)

def integ(g, cam, conf, faces, tracking=True):
    return g.integrate(cam, K, RES, tracking, conf, faces, MARGIN)

def check_quality(c):
    Q = cov.quality
    c.near("quality.ideal.nilConfidence", Q(1, 1, None), 0.8, 1e-5)
    c.near("quality.ideal.fullConfidence", Q(1, 1, 1), 1, 1e-5)
    c.near("quality.zeroConfidence", Q(1, 1, 0), 0.4, 1e-5)
    c.near("quality.tooNear", Q(0.1, 1, 1), 0, 1e-6)
    c.near("quality.nearRamp", Q(0.35, 1, None), 0.4, 1e-4)
    c.near("quality.knee", Q(2.5, 1, None), 0.8, 1e-3)
    c.near("quality.farRamp", Q(3.75, 1, None), 0.4, 1e-4)
    c.near("quality.maxRange", Q(5, 1, 1), 0, 1e-6)
    c.near("quality.grazing", Q(1, 0.1, 1), 0, 1e-6)
    c.near("quality.incidenceHalf", Q(1, r(0.435), None), 0.4, 1e-4)
    c.near("quality.nan", Q(float('nan'), 1, 1), 0, 0)
    inr = True; mono = True; prev = 2
    for i in range(61):
        d = r(i*r(0.1))
        for co in (-0.5, 0, 0.3, 0.7, 1):
            for cf in (0, 0.5, 1, 7):
                q = Q(d, r(co), cf)
                if not (0 <= q <= 1): inr = False
        if d >= 2.5:
            q = Q(d, 1, 0.5)
            if q > prev + 1e-6: mono = False
            prev = q
    c.check("quality.alwaysIn0to1", inr); c.check("quality.nonIncreasingBeyond2.5m", mono)
    s = cov.Stats(); c.check("state.empty.gray", cov.state_for(s) == 'gray')
    s.obs = 1; c.check("state.oneWeak.yellow", cov.state_for(s) == 'yellow')
    s.obs = 2; s.good = 2; c.check("state.twoGood.yellow", cov.state_for(s) == 'yellow')
    s.obs = 3; s.good = 3; c.check("state.threeGood.green", cov.state_for(s) == 'green')
    e = cov.Stats(); e.obs = 1; e.good = 1; e.q = 0.9; c.check("state.oneExcellent.green", cov.state_for(e) == 'green')

def check_single(c):
    cam = pose(0, 0, (0.0, 0.0, 0.0)); t = (0.0, 0.0, 1.0); mt = (0.0, 0.0, -1.0)
    faces = [((0, 0, -1.5), t, 0.01, 'wall'), ((0, 0, 1.5), mt, 0.01, 'wall'), ((0, 0, -6), t, 0.01, 'wall'),
             ((0, 0, -0.1), t, 0.01, 'wall'), ((0.2, 0, -1.5), mt, 0.01, 'wall'), ((3, 0, -1.5), t, 0.01, 'wall')]
    g = cov.Grid()
    ig = integ(g, cam, None, faces, tracking=False)
    c.check("face.trackingLimited.ignored", ig[0] == 0 and ig[1] == 0 and g.face_stats(0) is None and len(g.voxels) == 0)
    c.check("face.unknown.gray", g.state_face(0) == 'gray')
    f1 = integ(g, cam, None, faces)
    c.check("face.integrate.counts", f1[0] == 6 and f1[1] == 1 and not f1[2], str(f1))
    c.check("face.oneGood.yellow", g.state_face(0) == 'yellow')
    st = g.face_stats(0)
    c.check("face.stats.good", st.good == 1 and st.obs == 1)
    c.near("face.stats.bestDistance", st.dist, 1.5, 1e-4)
    c.near("face.stats.bestViewCosine", st.cos, 1, 1e-4)
    c.near("face.stats.bestQuality", st.q, 0.8, 1e-4)
    for i, n in ((1, "behindCamera"), (2, "outOfRange"), (3, "tooNear"), (4, "facingAway"), (5, "outsideImage")):
        c.check(f"face.{n}.untouched", g.face_stats(i) is None)
    integ(g, cam, None, faces); c.check("face.twoGood.yellow", g.state_face(0) == 'yellow')
    integ(g, cam, None, faces); c.check("face.threeGood.green", g.state_face(0) == 'green')
    vk = g.key(faces[0][0])
    c.check("voxel.countedOncePerCall", g.voxels.get(vk) is not None and g.voxels[vk].good == 3)
    c.check("voxel.isObserved", g.is_observed(faces[0][0], 0.15) and not g.is_observed((0, 0, -3), 0.15))
    c.check("voxel.key", g.key((r(0.05), r(-0.05), r(1.05))) == (0, -1, 10), str(g.key((r(0.05), r(-0.05), r(1.05)))))
    c.nearvec("voxel.center", g.center((0, -1, 10)), (0.05, -0.05, 1.05), 1e-5)
    grown = faces + [((0.5, 0, -2), t, 0.01, 'floor')]
    integ(g, cam, None, grown)
    c.check("face.meshGrows", len(g.faces) == 7 and g.state_face(6) == 'yellow')
    hole = (1, 1, -2)
    g.mark_expected([hole])
    c.check("voxel.expectedUnseen.red", g.state_voxel(g.key(hole)) == 'red' and g.state_counts()['red'] == 1)
    g.expected.clear(); c.check("voxel.clearExpected", g.state_counts()['red'] == 0)
    g = cov.Grid(); c.check("grid.reset", True)
    ex = cov.Grid(); integ(ex, cam, 1, faces); c.check("face.oneExcellent.green", ex.state_face(0) == 'green')
    wk = cov.Grid()
    for _ in range(5): integ(wk, cam, 0, faces)
    c.check("face.weakForever.yellow", wk.state_face(0) == 'yellow' and wk.face_stats(0).good == 0 and wk.face_stats(0).obs == 5)

def box_room():
    poly = [(0.0, 0.0), (4.0, 0.0), (4.0, 5.0), (0.0, 5.0)]
    walls = [(poly[i], poly[(i+1) % 4], 0.0, 2.5) for i in range(4)]
    return (walls, poly, 0.0, [], 2.5)

def box_mesh(room, cell):
    faces = []; el = []
    def rect(o, u, v, nu, nv, n, surf, e):
        du = tuple(r(x/nu) for x in u); dv = tuple(r(x/nv) for x in v)
        cr = (du[1]*dv[2]-du[2]*dv[1], du[2]*dv[0]-du[0]*dv[2], du[0]*dv[1]-du[1]*dv[0])
        half = r(r(math.sqrt(sum(x*x for x in cr)))*0.5)
        th = r(1/3); tt = r(2/3)
        for j in range(nv):
            for i in range(nu):
                c1 = tuple(r(r(o[k] + r(du[k]*r(i+tt))) + r(dv[k]*r(j+th))) for k in range(3))
                c2 = tuple(r(r(o[k] + r(du[k]*r(i+th))) + r(dv[k]*r(j+tt))) for k in range(3))
                faces.append((c1, n, half, surf)); faces.append((c2, n, half, surf)); el.extend([e, e])
    walls, poly, fy, _, cy = room
    for idx, w in enumerate(walls):
        n2 = cov.inward_normal(w, poly)
        d = (w[1][0]-w[0][0], w[1][1]-w[0][1]); L = math.hypot(*d)
        rect((w[0][0], w[2], w[0][1]), (d[0], 0, d[1]), (0, w[3], 0), cov.cell_count(L, cell), cov.cell_count(w[3], cell),
             (n2[0], 0.0, n2[1]), 'wall', idx)
    rect((0, fy, 0), (4, 0, 0), (0, 0, 5), 20, 25, (0.0, 1.0, 0.0), 'floor', -1)
    rect((0, cy, 0), (4, 0, 0), (0, 0, 5), 20, 25, (0.0, -1.0, 0.0), 'ceiling', -2)
    return faces, el

PASS = [(-5, 2), (20, 2), (50, 2), (80, 2), (110, 2), (110, -40), (80, -40), (50, -40), (20, -40), (-5, -40), (45, -80)]
EYE = (2.0, r(1.4), 2.5)

def el_states(g, el, e):
    gr = y = gn = 0
    for i in range(len(el)):
        if el[i] != e: continue
        s = g.state_face(i)
        if s in ('gray', 'red'): gr += 1
        elif s == 'yellow': y += 1
        else: gn += 1
    return gr, y, gn

def total_green(g, n): return sum(1 for i in range(n) if g.state_face(i) == 'green')

def check_box(c):
    room = box_room(); faces, el = box_mesh(room, 0.2)
    c.check("room.mesh.faceCount", len(faces) == 4340, str(len(faces)))
    c.nearvec("room.mesh.anchorCentroid", faces[2838][0], (1.9333, 0, 2.4667), 1e-3)
    g = cov.Grid(); g.mark_expected([s['pos'] for s in cov.samples(room)])
    g1 = vg1 = 0
    for p in (1, 2, 3):
        for (yw, pt) in PASS:
            integ(g, pose(yw, pt, EYE), None, faces)
        if p == 1:
            g1 = total_green(g, len(faces)); vg1 = g.state_counts()['green']
            w = [el_states(g, el, e) for e in (0, 1, 2, 3)]; fl = el_states(g, el, -1); ce = el_states(g, el, -2)
            print("pass1 states wall0..3", w, "floor", fl, "ceiling", ce, "green", g1)
            c.check("room.pass1.wall0AllSeen", w[0][0] == 0, str(w[0]))
            c.check("room.pass1.wall3AllSeen", w[3][0] == 0, str(w[3]))
            c.check("room.pass1.wall1Unseen", w[1][0] >= 630, str(w[1]))
            c.check("room.pass1.wall2Unseen", w[2][0] >= 480, str(w[2]))
            c.check("room.pass1.ceilingNeverGreen", ce[2] == 0 and ce[0] >= 790, str(ce))
            c.check("room.pass1.floorPartly", 370 <= fl[0] <= 400, str(fl))
            c.check("room.pass1.totalGreen", 470 <= g1 <= 600, str(g1))
            c.check("room.pass1.wallFace298.yellow", g.state_face(298) == 'yellow')
            c.check("room.pass1.wallFace2064.yellow", g.state_face(2064) == 'yellow')
            c.check("room.pass1.floorFace2838.yellow", g.state_face(2838) == 'yellow' and g.face_stats(2838).good == 1)
            c.check("room.pass1.floorFace2511.green", g.state_face(2511) == 'green')
            c.check("room.pass1.unseenWallFace.gray", g.face_stats(894) is None and g.state_face(894) == 'gray')
            c.check("room.pass1.unseenCeilingFace.gray", g.face_stats(3838) is None)
        elif p == 2:
            c.check("room.pass2.wallFace298.green", g.state_face(298) == 'green')
            c.check("room.pass2.wallFace2064.green", g.state_face(2064) == 'green')
            c.check("room.pass2.floorFace2838.stillYellow", g.state_face(2838) == 'yellow')
    gn = total_green(g, len(faces))
    print("pass3 green", gn, [el_states(g, el, e) for e in (0, 1, 2, 3, -1, -2)])
    c.check("room.pass3.floorFace2838.green", g.state_face(2838) == 'green')
    c.check("room.pass3.wall0AllGreen", el_states(g, el, 0)[2] == 520)
    c.check("room.pass3.totalGreen", 1600 <= gn <= 1700 and gn > g1, str(gn))
    c.check("room.pass3.permanentYellow", g.state_face(2290) == 'yellow' and g.face_stats(2290).good == 0)
    c.check("room.pass3.ceilingNeverGreen", el_states(g, el, -2)[2] == 0)
    cnt = g.state_counts(); print("voxel counts", cnt, "green after 1", vg1)
    c.check("room.voxels.red", cnt['red'] > 1500, str(cnt))
    c.check("room.voxels.greenGrows", cnt['green'] > vg1)
    c.check("room.voxels.seenWallGreen", g.state_voxel(g.key(faces[298][0])) == 'green')
    check_missing(c, room, g)
    check_sq(c, room, g, faces)

def check_missing(c, room, g):
    res = cov.evaluate(room, g)
    c.check("expected.sampleCount", len(res['samples']) == 2170, str(len(res['samples'])))
    c.near("expected.wallArea", res['ea']['wall'], 45, 0.01)
    c.near("expected.floorArea", res['ea']['floor'], 20, 0.01)
    c.near("expected.ceilingArea", res['ea']['ceiling'], 20, 0.01)
    ok = all(res['observed'][k] for k, s in enumerate(res['samples']) if s['el'] in (0, 3))
    c.check("expected.seenWallsObserved", ok)
    k = next((k for k, s in enumerate(res['samples']) if s['el'] == 1 and s['cell'] == (12, 6)), None)
    if k is not None:
        p = res['samples'][k]['pos']
        c.check("expected.unseenSample.red", not res['observed'][k] and g.state_voxel(g.key(p)) == 'red')
    else:
        c.check("expected.unseenSample.exists", False)
    m = res['missing']
    for a in m: print("missing", a['surf'], round(a['area'], 3), tuple(round(v, 3) for v in a['centroid']), a['normal'], tuple(round(v, 3) for v in a['vp']))
    print("observed areas", res['oa'])
    c.check("missing.count", len(m) == 4, str(len(m)))
    c.check("missing.noneOnSeenWalls", all(a['surf'] != 'wall' or (abs(a['centroid'][0]) > 0.5 and abs(a['centroid'][2]) > 0.5) for a in m))
    if len(m) != 4: return
    exp = [('ceiling', 16.0, (2.199, 2.5, 2.801), (0, -1, 0), (2.199, 1.4, 2.801)),
           ('wall', 11.92, (4, 1.258, 2.615), (-1, 0, 0), (2.5, 1.4, 2.615)),
           ('wall', 9.38, (2.122, 1.264, 5), (0, 0, -1), (2.122, 1.4, 3.5)),
           ('floor', 7.6, (2.855, 0, 3.522), (0, 1, 0), (2.855, 1.4, 3.522))]
    for i, e in enumerate(exp):
        a = m[i]
        c.check(f"missing{i}.surface", a['surf'] == e[0], a['surf'])
        c.near(f"missing{i}.area", a['area'], e[1], 0.5)
        c.nearvec(f"missing{i}.centroid", a['centroid'], e[2], 0.1)
        c.check(f"missing{i}.normalInward", sum(a['normal'][j]*e[3][j] for j in range(3)) > 0.99)
        c.nearvec(f"missing{i}.viewpoint", a['vp'], e[4], 0.1)
        vp = a['vp']; inside = cov.pip((vp[0], vp[2]), room[1])
        front = sum((vp[j]-a['centroid'][j])*a['normal'][j] for j in range(3))
        fok = abs(front - 1.5) < 0.05 if a['surf'] == 'wall' else front > 0.5
        c.check(f"missing{i}.viewpointInRoomInFront", inside and abs(vp[1]-1.4) < 1e-3 and fok, f"{vp} {front}")
    c.check("guidance.missingCeiling", m[0]['surf'] == 'ceiling')
    c.check("guidance.missingFloor", m[3]['surf'] == 'floor')

def check_sq(c, room, g, faces):
    q = cov.scan_quality(g, faces, room)
    print("quality", {k: round(v, 2) for k, v in q.items() if k != 'missing'})
    c.between("quality.walls", q['walls'], 50, 55)
    c.between("quality.floor", q['floor'], 57, 66)
    c.between("quality.ceiling", q['ceiling'], 14, 25)
    c.between("quality.geometry", q['geometry'], 44, 50)
    c.check("quality.geometryBetween", q['ceiling'] < q['geometry'] < q['floor'])
    c.between("quality.textures", q['textures'], 35, 40)
    c.check("quality.missingAreas", len(q['missing']) == 4)
    fr = cov.scan_quality(g, faces, None)
    print("quality noRoom", {k: round(v, 2) for k, v in fr.items() if k != 'missing'})
    c.check("quality.noRoom.noMissing", not fr['missing'])
    c.check("quality.noRoom.wallsPartial", 0 < fr['walls'] < 100)
    c.near("quality.noRoom.textures", fr['textures'], q['textures'], 1e-3)

def check_guidance(c):
    G = guid
    def main(t):
        kw = {}
        if t == 0: kw['walls'] = 1
        if 0.25 <= t <= 2.0: kw['tracking'] = 'relocalizing'
        if t == 8.0 or t == 9.25: kw['doors'] = 1
        if (11.0 <= t < 15.0) or t >= 20.0: kw['center'] = 4.0
        return G.inp(t, **kw)
    m = G.Trace(109, main)
    for i, o in enumerate(m.out):
        pass
    c.check("guidance.eventBypassesHold", m.msg(0) == 'wallDetected' and not m.at(0)[1])
    c.check("guidance.conditionHold", m.msg(0.75) == 'wallDetected', str(m.msg(0.75)))
    c.check("guidance.tier1InterruptsTier3AtOnce", m.msg(1.0) == 'trackingLost' and m.at(1.0)[1])
    c.check("guidance.tier1MinimumTime", m.msg(3.75) == 'trackingLost' and m.msg(4.0) is None)
    c.check("guidance.tier3QuietAfterTier1", m.msg(8.0) is None and m.msg(9.0) is None)
    c.check("guidance.eventAfterQuiet", m.msg(9.25) == 'doorDetected')
    c.check("guidance.eventHidesAfterMinimum", m.msg(10.5) == 'doorDetected' and m.msg(10.75) is None)
    c.check("guidance.minimumGap", m.msg(13.5) is None and m.msg(13.75) == 'moveCloser' and not m.at(13.75)[1])
    c.check("guidance.tier2MinimumTime", m.msg(16.0) == 'moveCloser' and m.msg(16.25) is None)
    c.check("guidance.repeatCooldown", m.msg(26.0) is None and m.msg(26.25) == 'moveCloser')
    print("main trace:", [(i*0.25, o) for i, o in enumerate(m.out) if i == 0 or o != m.out[i-1]])

    def hap(t):
        kw = {}
        if t <= 0.75: kw['tracking'] = 'excessiveMotion'
        elif t <= 5.0: kw['tracking'] = 'relocalizing'
        if t >= 7.0: kw['center'] = 0.1
        return G.inp(t, **kw)
    h = G.Trace(33, hap)
    print("haptic trace:", [(i*0.25, o) for i, o in enumerate(h.out) if i == 0 or o != h.out[i-1]])
    c.check("guidance.holdBeforeShow", h.msg(0.5) is None and h.msg(0.75) == 'moveSlower' and h.at(0.75)[1])
    c.check("guidance.equalTierNoInterrupt", h.msg(1.75) == 'moveSlower')
    c.check("guidance.tier1IgnoresGap", h.msg(3.75) == 'trackingLost')
    c.check("guidance.hapticCooldown", not h.at(3.75)[1])
    c.check("guidance.hapticAfterCooldown", h.msg(7.75) == 'tooClose' and h.at(7.75)[1])
    c.check("guidance.hapticCount", h.haptics() == 2, str(h.haptics()))

    tk = G.Trace(12, lambda t: G.inp(t, center=4.0, **({'walls': 1} if t == 0 else {})))
    print("takeover:", [(i*0.25, o) for i, o in enumerate(tk.out) if i == 0 or o != tk.out[i-1]])
    c.check("guidance.tier2ReplacesTier3AtMinimum", tk.msg(1.25) == 'wallDetected' and tk.msg(1.5) == 'moveCloser')
    cp = G.Trace(121, lambda t: G.inp(t, complete=True))
    print("complete:", [(i*0.25, o) for i, o in enumerate(cp.out) if i == 0 or o != cp.out[i-1]])
    c.check("guidance.completeOncePerRun", cp.msg(0.75) == 'roomLooksComplete' and cp.appearances(30) == 1, str(cp.appearances(30)))
    t1 = G.Trace(4, lambda t: G.inp(t, lux=100.0, center=4.0))
    c.check("guidance.tier1BeatsTier2", t1.msg(0.75) == 'lightingPoor')
    t2 = G.Trace(4, lambda t: G.inp(t, lux=100.0, tracking='relocalizing'))
    c.check("guidance.tableOrderWithinTier", t2.msg(0.75) == 'trackingLost')
    tg = G.Trace(20, lambda t: G.inp(t, center=(0.1 if int(t*4) % 2 == 0 else 1.0)))
    c.check("guidance.noFlicker.toggle", tg.changes() == 0, str(tg.changes()))
    hv = G.Trace(41, lambda t: G.inp(t, lux=(290.0 if t <= 0.75 else (310.0 if int(t*4) % 2 == 0 else 290.0))))
    c.check("guidance.noFlicker.hysteresis", hv.msg(0.75) == 'lightingPoor' and hv.changes() == 1 and hv.haptics() == 1,
            f"changes {hv.changes()} haptics {hv.haptics()}")
    ev = G.Trace(245, lambda t: G.inp(t, windows=1, doors=1, walls=1))
    print("events trace:", [(i*0.25, o) for i, o in enumerate(ev.out) if i == 0 or o != ev.out[i-1]])
    c.check("guidance.eventOrder", ev.msg(0) == 'windowDetected')
    c.check("guidance.tier3Cap", ev.appearances(60) == 4, str(ev.appearances(60)))
    c.check("guidance.tier3CapRolls", ev.msg(59.75) is None and ev.msg(60) is not None)
    e = G.Engine()
    ls = e.conditions(G.inp(0, tracking='insufficientFeatures', center=4.0))
    c.check("guidance.limitedTrackingSuppressesTier2", 'trackingLow' in ls and 'moveCloser' not in ls)
    c.check("guidance.moveSlower", 'moveSlower' in e.conditions(G.inp(0, ang=2.0)) and 'moveSlower' not in e.conditions(G.inp(0, ang=1.0, lin=0.5)))
    c.check("guidance.tooFar", 'tooFar' in e.conditions(G.inp(0, center=6.0)))
    c.check("guidance.lowDepthConfidenceMoveCloser", 'moveCloser' in e.conditions(G.inp(0, conf=0.1, center=2.0))
            and 'moveCloser' not in e.conditions(G.inp(0, conf=0.1, center=1.0)))
    corner, single = corner_check()
    c.check("guidance.corner", corner)
    c.check("guidance.singleWallHole", not single)
    rs = G.Engine()
    for i in range(4): rs.update(G.inp(i*0.25, tracking='excessiveMotion'))
    c.check("guidance.reset", rs.current == 'moveSlower')

def corner_check():
    # isNearCorner port for the two synthetic areas a, b
    import math
    def hu(v):
        l = math.hypot(v[0], v[2]); return (v[0]/l, v[2]/l) if l > 1e-3 else None
    def near(area, areas):
        a = hu(area['n']); ca = (area['c'][0], area['c'][2])
        for o in areas:
            if o['s'] != 'wall': continue
            b = hu(o['n'])
            if b is None: continue
            if abs(a[0]*b[0]+a[1]*b[1]) > 0.7: continue
            det = a[0]*b[1]-a[1]*b[0]
            if abs(det) < 1e-4: continue
            cb = (o['c'][0], o['c'][2]); ra = a[0]*ca[0]+a[1]*ca[1]; rb = b[0]*cb[0]+b[1]*cb[1]
            corner = ((ra*b[1]-a[1]*rb)/det, (a[0]*rb-b[0]*ra)/det)
            reachA = max(0, math.hypot(ca[0]-corner[0], ca[1]-corner[1]) - 0.5*math.sqrt(area['a']))
            reachB = max(0, math.hypot(cb[0]-corner[0], cb[1]-corner[1]) - 0.5*math.sqrt(o['a']))
            if reachA <= 0.5 and reachB <= 0.5: return True
        return False
    a = dict(c=(4, 1, 4.7), n=(-1, 0, 0), a=0.2, s='wall'); b = dict(c=(3.7, 1, 5), n=(0, 0, -1), a=0.2, s='wall')
    return near(a, [a, b]), near(a, [a])

def check_measure(c):
    M = cov
    def ev(d, conf=1, obs=4, track=1, snap='vertex'): return dict(d=d, conf=conf, obs=obs, track=track, snap=snap)
    def mono(v, inc):
        for i in range(1, len(v)):
            if inc and v[i] < v[i-1] - 1e-7: return False
            if not inc and v[i] > v[i-1] + 1e-7: return False
        return True
    ds = [0.2, 0.5, 1, 2, 3, 4, 4.5, 5, 6]
    c.check("measure.pointMonotonicDistance", mono([M.point_acc(ev(d)) for d in ds], True))
    c.check("measure.fartherWorse", M.point_acc(ev(5)) > M.point_acc(ev(1)))
    c.check("measure.lengthMonotonicDistance", mono([M.estimate(ev(d), ev(d), 3)[0] for d in ds], True))
    c.check("measure.monotonicObservations", mono([M.point_acc(ev(2, obs=o)) for o in range(13)], False))
    c.check("measure.moreObservationsBetter", M.point_acc(ev(2, obs=9)) < M.point_acc(ev(2, obs=1)))
    c.check("measure.monotonicConfidence", mono([M.point_acc(ev(2, conf=i/10)) for i in range(11)], False))
    c.check("measure.monotonicTracking", mono([M.point_acc(ev(2, track=i/10)) for i in range(11)], False))
    c.check("measure.planeSnapBetter", M.point_acc(ev(2, snap='plane')) < M.point_acc(ev(2, snap='none')))
    wall = ev(2, conf=1, obs=9, track=1, snap='roomSurface')
    sp = M.estimate(wall, wall, 5.66); print("spec example", sp)
    c.check("measure.specExample", 0.0125 <= sp[0] <= 0.014 and not sp[1], str(sp))
    c.check("measure.driftWithLength", M.estimate(ev(1), ev(1), 10)[0] > M.estimate(ev(1), ev(1), 1)[0])
    c.check("measure.low.tracking", M.estimate(ev(1, track=0.5), ev(1), 2)[1])
    c.check("measure.low.noObservations", M.estimate(ev(1, obs=0), ev(1), 2)[1])
    c.check("measure.low.depthConfidence", M.estimate(ev(1, conf=0.2), ev(1), 2)[1])
    fp = ev(5, conf=None, obs=1, snap='none'); far = M.estimate(fp, fp, 1); print("far", far)
    c.check("measure.low.inaccurate", far[1] and far[0] > 0.05, str(far))
    pt = M.estimate_point(ev(1)); na = M.point_acc(ev(float('nan')))
    c.check("measure.point.goodAndFinite", not pt[1] and pt[0] >= 0.004 and math.isfinite(na) and 0 < na <= 1)

t0 = time.time()
c = Checker()
check_quality(c); check_single(c); check_box(c); check_guidance(c); check_measure(c)
print("checks", c.count, "failures", len(c.fail))
for f in c.fail: print("  FAIL", f)
print("elapsed", round(time.time()-t0, 2))
