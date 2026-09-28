"""Faithful Python port of ios/Sources/Coverage (grid, expected surfaces, scan quality,
measurement confidence) used to dry-run CoverageSelfTest without a Swift compiler.
Float32 rounding is emulated at the key points via f32()."""
import math, struct

def f32(x):
    return struct.unpack('f', struct.pack('f', x))[0]

F32 = True
def r(x):
    return f32(x) if F32 else x

def dot(a, b): return r(r(a[0]*b[0]) + r(a[1]*b[1]) + r(a[2]*b[2]))
def sub(a, b): return (r(a[0]-b[0]), r(a[1]-b[1]), r(a[2]-b[2]))
def add(a, b): return (r(a[0]+b[0]), r(a[1]+b[1]), r(a[2]+b[2]))
def mul(a, s): return (r(a[0]*s), r(a[1]*s), r(a[2]*s))
def length(a): return r(math.sqrt(dot(a, a)))

# ---------------- CoverageGrid ----------------
GOOD = 0.5; EXC = 0.85; GREEN_N = 3; MAXR = 5.0; MINR = 0.2; CAP = 60000
MARGIN_FRAC = r(1.0/120.0); MIN_DEPTH = 0.05; LARGE_R = 0.075

class Stats:
    __slots__ = ('obs', 'good', 'cos', 'dist', 'q')
    def __init__(self):
        self.obs = 0; self.good = 0; self.cos = 0.0; self.dist = math.inf; self.q = 0.0
    def add(self, q, c, d):
        if q > 0: self.obs += 1
        if q >= GOOD: self.good += 1
        if c > self.cos: self.cos = c
        if q > self.q: self.q = q; self.dist = d
    def empty(self):
        return self.obs == 0 and self.good == 0 and self.cos == 0 and self.dist == math.inf and self.q == 0

def quality(d, c, conf):
    if not (math.isfinite(d) and math.isfinite(c)): return 0.0
    if d < MINR: dt = 0.0
    elif d < 0.5: dt = r((d - MINR) / r(0.5 - MINR))
    elif d <= 2.5: dt = 1.0
    elif d < MAXR: dt = r((MAXR - d) / (MAXR - 2.5))
    else: dt = 0.0
    it = min(max(r(r(c - r(0.17)) / r(r(0.7) - r(0.17))), 0.0), 1.0)
    if conf is not None and math.isfinite(conf):
        ct = r(0.4 + r(0.6 * min(max(conf, 0), 1)))
    else:
        ct = r(0.8)
    return min(max(r(r(dt * it) * ct), 0.0), 1.0)

def state_for(s):
    if s.good >= GREEN_N or s.q >= EXC: return 'green'
    if s.good >= 1 or s.obs >= 1: return 'yellow'
    return 'gray'

class Grid:
    def __init__(self, vs=0.1):
        self.vs = r(vs); self.voxels = {}; self.expected = set(); self.faces = []; self.cursor = 0
    def key(self, p):
        return tuple(int(math.floor(r(v / self.vs))) for v in p)
    def center(self, k):
        return tuple(r(r(k[i] + 0.5) * self.vs) for i in range(3))
    def integrate(self, cam, K, res, tracking, conf, faces, margin_override=None):
        n = len(faces)
        if not tracking or n == 0: return (0, 0, False)
        while len(self.faces) < n: self.faces.append(Stats())
        ax, ay, az, org = cam
        fx, fy, cx, cy = K
        W, H = res
        margin = r(W * MARGIN_FRAC) if margin_override is None else margin_override
        uMin, uMax, vMin, vMax = -margin, W + margin, -margin, H + margin
        hits = {}
        tested = updated = 0; trunc = False
        idx = self.cursor if self.cursor < n else 0
        while tested < n:
            i = idx; idx += 1
            if idx == n: idx = 0
            tested += 1
            f = faces[i]
            d = sub(f[0], org)
            d2 = dot(d, d)
            if d2 < r(MINR*MINR) or d2 > r(MAXR*MAXR): continue
            depth = -dot(az, d)
            if depth <= MIN_DEPTH: continue
            inv = r(1/depth)
            u = r(r(r(fx * dot(ax, d)) * inv) + cx)
            if u < uMin or u > uMax: continue
            v = r(r(r(fy * -dot(ay, d)) * inv) + cy)
            if v < vMin or v > vMax: continue
            dist = r(math.sqrt(d2))
            vc = r(-dot(f[1], d) / dist)
            if not (vc > 0): continue
            q = quality(dist, vc, conf)
            self.faces[i].add(q, vc, dist)
            updated += 1
            hit = (q, vc, dist)
            self._rec(hit, self.key(f[0]), hits)
            area = f[2]
            if area > 0:
                rad = r(math.sqrt(r(area / r(math.pi))))
                if rad > LARGE_R:
                    self._large(f, rad, hit, hits)
            if updated >= CAP:
                trunc = tested < n; break
        self.cursor = idx
        for k, h in hits.items():
            s = self.voxels.get(k)
            if s is None: s = Stats(); self.voxels[k] = s
            s.add(*h)
        return (tested, updated, trunc)
    def _rec(self, hit, k, hits):
        old = hits.get(k)
        if old is None: hits[k] = hit; return
        q, c, d = old
        if hit[0] > q: q = hit[0]; d = hit[2]
        if hit[1] > c: c = hit[1]
        hits[k] = (q, c, d)
    def _large(self, f, rad, hit, hits):
        steps = min(int(rad / self.vs), 3)
        if steps < 1: return
        raise RuntimeError("large face path not expected in scenario")
    def face_stats(self, i):
        if i < 0 or i >= len(self.faces): return None
        s = self.faces[i]
        return None if s.empty() else s
    def state_face(self, i):
        if i < 0 or i >= len(self.faces): return 'gray'
        return state_for(self.faces[i])
    def state_voxel(self, k):
        s = self.voxels.get(k)
        st = state_for(s) if s is not None else 'gray'
        if st == 'gray' and k in self.expected: return 'red'
        return st
    def is_observed(self, p, radius):
        r2 = r(radius*radius)
        lo = self.key(sub(p, (radius,)*3)); hi = self.key(add(p, (radius,)*3))
        for z in range(lo[2], hi[2]+1):
            for y in range(lo[1], hi[1]+1):
                for x in range(lo[0], hi[0]+1):
                    k = (x, y, z)
                    s = self.voxels.get(k)
                    if s is not None and s.obs > 0:
                        dd = sub(self.center(k), p)
                        if dot(dd, dd) <= r2: return True
        return False
    def mark_expected(self, pts):
        for p in pts: self.expected.add(self.key(p))
    def state_counts(self):
        c = {'gray': 0, 'red': 0, 'yellow': 0, 'green': 0}
        for k in self.voxels: c[self.state_voxel(k)] += 1
        for k in self.expected:
            if k not in self.voxels: c['red'] += 1
        return c
    def good_face_area_fraction(self, faces):
        tot = good = 0.0
        for i, f in enumerate(faces):
            if f[2] > 0:
                tot += f[2]
                if i < len(self.faces) and self.faces[i].good >= 1: good += f[2]
        return min(good / tot, 1) if tot > 0 else 0
    def observed_area_fraction(self, faces, surface):
        tot = seen = 0.0
        for i, f in enumerate(faces):
            if f[2] > 0:
                if surface is not None and f[3] != surface: continue
                tot += f[2]
                if i < len(self.faces) and state_for(self.faces[i]) in ('yellow', 'green'): seen += f[2]
        return min(seen / tot, 1) if tot > 0 else 0

# ---------------- ExpectedSurfaces ----------------
SPACING = 0.2; OBS_R = 0.15; MIN_MISS = 0.08; EYE = 1.4; VIEWD = 1.5; INSET = 0.3

def pip(p, poly):
    n = len(poly)
    if n < 3: return False
    inside = False; j = n - 1
    for i in range(n):
        a = poly[i]; b = poly[j]
        if (a[1] > p[1]) != (b[1] > p[1]):
            t = (p[1]-a[1])/(b[1]-a[1]); x = a[0] + t*(b[0]-a[0])
            if p[0] < x: inside = not inside
        j = i
    return inside

def cell_count(L, s):
    if not (L > 0 and s > 0): return 0
    n = min(math.ceil(r(r(L/s) - r(0.001))), 2000)
    return max(int(n), 1)

def cell_span(i, L, s):
    st = r(i*s); e = min(r(st+s), L)
    return st, max(r(e-st), 0)

def inward_normal(wall, poly):
    s, e = wall[0], wall[1]
    d = (e[0]-s[0], e[1]-s[1]); L = math.hypot(*d)
    if L <= 1e-4: return None
    dr = (d[0]/L, d[1]/L); left = (-dr[1], dr[0]); right = (-left[0], -left[1])
    if len(poly) < 3: return left
    mid = ((s[0]+e[0])*0.5, (s[1]+e[1])*0.5)
    li = pip((mid[0]+left[0]*0.05, mid[1]+left[1]*0.05), poly)
    ri = pip((mid[0]+right[0]*0.05, mid[1]+right[1]*0.05), poly)
    if li and not ri: return left
    if ri and not li: return right
    c = (sum(p[0] for p in poly)/len(poly), sum(p[1] for p in poly)/len(poly))
    return left if (c[0]-mid[0])*left[0] + (c[1]-mid[1])*left[1] >= 0 else right

def samples(room, s=SPACING):
    walls, fpoly, fy, cpoly, cy = room
    out = []
    for idx, w in enumerate(walls):
        n2 = inward_normal(w, fpoly)
        if n2 is None: continue
        d = (w[1][0]-w[0][0], w[1][1]-w[0][1]); L = r(math.hypot(*d)); dr = (d[0]/L, d[1]/L)
        h = w[3]; cols = cell_count(L, s); rows = cell_count(h, s)
        for j in range(rows):
            rs, rw = cell_span(j, h, s)
            if rw <= 0: continue
            y = r(w[2] + rs + rw*0.5)
            for i in range(cols):
                cs, cw = cell_span(i, L, s)
                if cw <= 0: continue
                t = r(cs + cw*0.5)
                p2 = (r(w[0][0] + dr[0]*t), r(w[0][1] + dr[1]*t))
                out.append(dict(pos=(p2[0], y, p2[1]), n=(n2[0], 0.0, n2[1]), surf='wall', el=idx, cell=(i, j), area=r(cw*rw)))
    def horiz(poly, y, n, surf, el):
        if len(poly) < 3: return
        lo = (min(p[0] for p in poly), min(p[1] for p in poly)); hi = (max(p[0] for p in poly), max(p[1] for p in poly))
        sx, sz = r(hi[0]-lo[0]), r(hi[1]-lo[1])
        nx, nz = cell_count(sx, s), cell_count(sz, s)
        for j in range(nz):
            zs, zw = cell_span(j, sz, s)
            if zw <= 0: continue
            for i in range(nx):
                xs, xw = cell_span(i, sx, s)
                if xw <= 0: continue
                c = (r(lo[0]+xs+xw*0.5), r(lo[1]+zs+zw*0.5))
                if not pip(c, poly): continue
                out.append(dict(pos=(c[0], y, c[1]), n=n, surf=surf, el=el, cell=(i, j), area=r(xw*zw)))
    horiz(fpoly, fy, (0.0, 1.0, 0.0), 'floor', -1)
    horiz(cpoly if len(cpoly) >= 3 else fpoly, cy, (0.0, -1.0, 0.0), 'ceiling', -2)
    return out

def signed_area(poly):
    s = 0
    for i in range(len(poly)):
        a = poly[i]; b = poly[(i+1) % len(poly)]
        s += a[0]*b[1] - b[0]*a[1]
    return s*0.5

def nearest_boundary(p, poly):
    best = (p, math.inf, 0)
    for i in range(len(poly)):
        a = poly[i]; b = poly[(i+1) % len(poly)]
        e = (b[0]-a[0], b[1]-a[1]); l2 = e[0]**2 + e[1]**2
        t = 0
        if l2 > 1e-12: t = min(max(((p[0]-a[0])*e[0] + (p[1]-a[1])*e[1])/l2, 0), 1)
        q = (a[0]+e[0]*t, a[1]+e[1]*t); d = math.hypot(p[0]-q[0], p[1]-q[1])
        if d < best[1]: best = (q, d, i)
    return best

def clamp_inside(p, poly, inset):
    ccw = signed_area(poly) >= 0
    q = p
    for _ in range(8):
        inside = pip(q, poly); nb = nearest_boundary(q, poly)
        if inside and nb[1] >= inset - 1e-4: return q
        a = poly[nb[2]]; b = poly[(nb[2]+1) % len(poly)]
        e = (b[0]-a[0], b[1]-a[1]); el = math.hypot(*e)
        if el <= 1e-6: return None
        left = (-e[1]/el, e[0]/el); inw = left if ccw else (-left[0], -left[1])
        q = (nb[0][0]+inw[0]*inset, nb[0][1]+inw[1]*inset)
    nb = nearest_boundary(q, poly)
    return q if pip(q, poly) and nb[1] >= inset - 1e-4 else None

def viewpoint(c, n, room):
    p = (c[0], c[2]); h = (n[0], n[2]); hl = math.hypot(*h)
    if abs(n[1]) < 0.7 and hl > 1e-4: p = (p[0] + h[0]/hl*VIEWD, p[1] + h[1]/hl*VIEWD)
    y = room[2] + EYE; poly = room[1]
    if len(poly) < 3: return (p[0], y, p[1])
    for ins in (INSET, INSET*0.5, 0.05):
        q = clamp_inside(p, poly, ins)
        if q is not None: return (q[0], y, q[1])
    if pip(p, poly): return (p[0], y, p[1])
    nb = nearest_boundary(p, poly)
    return (nb[0][0], y, nb[0][1])

def evaluate(room, grid, s=SPACING):
    al = samples(room, s)
    obs = [False]*len(al)
    ea = {'wall': 0.0, 'floor': 0.0, 'ceiling': 0.0}; oa = dict(ea)
    cell = {}
    for k, sm in enumerate(al):
        seen = grid.is_observed(sm['pos'], OBS_R)
        obs[k] = seen; ea[sm['surf']] += sm['area']
        if seen: oa[sm['surf']] += sm['area']
        else: cell[(sm['el'], sm['cell'][0], sm['cell'][1])] = k
    parent = list(range(len(al)))
    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]; x = parent[x]
        return x
    def union(a, b):
        ra, rb = find(a), find(b)
        if ra == rb: return
        if ra < rb: parent[rb] = ra
        else: parent[ra] = rb
    for k, sm in enumerate(al):
        if obs[k]: continue
        rt = cell.get((sm['el'], sm['cell'][0]+1, sm['cell'][1]))
        up = cell.get((sm['el'], sm['cell'][0], sm['cell'][1]+1))
        if rt is not None: union(k, rt)
        if up is not None: union(k, up)
    cl = {}; order = []
    for k, sm in enumerate(al):
        if obs[k]: continue
        rt = find(k)
        if rt not in cl:
            cl[rt] = dict(first=k, surf=sm['surf'], area=0.0, wp=[0, 0, 0], wn=[0, 0, 0], n=sm['n']); order.append(rt)
        c = cl[rt]; a = sm['area']; c['area'] += a
        for i in range(3): c['wp'][i] += sm['pos'][i]*a; c['wn'][i] += sm['n'][i]*a
    built = []
    for rt in order:
        c = cl[rt]
        if not (c['area'] + 1e-5 >= MIN_MISS and c['area'] > 0): continue
        cen = tuple(v / c['area'] for v in c['wp'])
        nl = math.sqrt(sum(v*v for v in c['wn']))
        nrm = tuple(v/nl for v in c['wn']) if nl > 1e-6 else c['n']
        built.append((dict(centroid=cen, normal=nrm, area=c['area'], surf=c['surf'], vp=viewpoint(cen, nrm, room)), c['first']))
    built.sort(key=lambda t: (-t[0]['area'], t[1]))
    return dict(samples=al, observed=obs, missing=[b[0] for b in built], ea=ea, oa=oa)

# ---------------- ScanQuality ----------------
def clampp(v): return min(max(v, 0), 100) if math.isfinite(v) else 0
def ratio(o, e): return 100.0 if e <= 1e-6 else clampp(100*o/e)

def scan_quality(grid, faces, room):
    tex = clampp(100*grid.good_face_area_fraction(faces))
    if room is None:
        return dict(geometry=clampp(100*grid.observed_area_fraction(faces, None)),
                    walls=clampp(100*grid.observed_area_fraction(faces, 'wall')),
                    floor=clampp(100*grid.observed_area_fraction(faces, 'floor')),
                    ceiling=clampp(100*grid.observed_area_fraction(faces, 'ceiling')), textures=tex, missing=[])
    res = evaluate(room, grid)
    et = ot = 0
    for s in ('wall', 'floor', 'ceiling'):
        e = res['ea'][s]; o = min(res['oa'][s], e); et += e; ot += o
    return dict(geometry=ratio(ot, et), walls=ratio(res['oa']['wall'], res['ea']['wall']),
                floor=ratio(res['oa']['floor'], res['ea']['floor']), ceiling=ratio(res['oa']['ceiling'], res['ea']['ceiling']),
                textures=tex, missing=res['missing'])

# ---------------- MeasurementConfidence ----------------
def c01(x): return 0 if math.isnan(x) else min(max(x, 0), 1)
def base_sigma(d):
    d = math.inf if math.isnan(d) else max(0, d)
    if d <= 0.5: return 0.005
    if d <= 4: return 0.005 + 0.004*(d-0.5)
    return 0.005 + 0.004*3.5 + 0.012*(d-4)
def conf_factor(c):
    if c is None: return 1.5
    c = c01(c)
    return 3 - 3*c if c <= 0.5 else 1.5 - (c-0.5)
def track_factor(f): return 1 + 2*(1-c01(f))
SNAP = {'none': 1.2, 'vertex': 1.0, 'edge': 0.9, 'plane': 0.7, 'roomSurface': 0.7}
def bound(x, lo):
    if math.isnan(x): return 1.0
    return min(max(x, lo), 1.0)
def point_acc(e):
    n = min(max(e['obs'], 1), 9)
    raw = base_sigma(e['d'])*conf_factor(e['conf'])*track_factor(e['track'])*SNAP[e['snap']]/math.sqrt(n)
    return bound(raw, 0.004)
def weak(e):
    if e['obs'] <= 0: return True
    if c01(e['track']) < 0.7: return True
    if e['conf'] is not None and c01(e['conf']) < 0.34: return True
    return False
def estimate(a, b, L):
    L = 0 if math.isnan(L) else max(0, L)
    pa, pb = point_acc(a), point_acc(b)
    wt = min(c01(a['track']), c01(b['track']))
    drift = (0.002 + 0.018*(1-wt))*min(L, 1000)
    acc = math.sqrt(pa*pa + pb*pb + drift*drift)
    if a['snap'] == 'roomSurface' and b['snap'] == 'roomSurface': acc = max(acc, 0.0125)
    acc = bound(acc, 0.004)
    thr = max(0.05, 0.03*L)
    return acc, (acc > thr or weak(a) or weak(b))
def estimate_point(e):
    acc = point_acc(e)
    return acc, (acc > 0.05 or weak(e))
