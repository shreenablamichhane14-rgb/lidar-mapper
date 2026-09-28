"""Python port of GuidanceEngine.swift (same rules, same order of operations)."""
import math

T1 = ['trackingLost', 'trackingLow', 'lightingPoor', 'moveSlower', 'tooClose', 'tooFar', 'deviceHot', 'objectMoved']
T2 = ['moveCloser', 'scanCorner', 'pointAtFloor', 'scanCeiling', 'scanDoorwayBothSides', 'needsAnotherPass',
      'objectMoveAround', 'objectCaptureLeft', 'objectCaptureRight', 'objectCaptureBack', 'objectCaptureTop',
      'objectKeepInView', 'objectMoveCloserToArea', 'objectNeedsDetail']
T3 = ['windowDetected', 'doorDetected', 'wallDetected', 'openingDetected', 'stairsDetected', 'roomLooksComplete',
      'objectLooksComplete']
MSG = {}
for k in T1: MSG[k] = (1, 3.0, True)
for k in T2: MSG[k] = (2, 2.5, False)
for k in T3: MSG[k] = (3, 1.5, False)
ORDER = T1 + T2 + T3

GAP = 3.0; HOLD = 0.75; COOLDOWN = 10.0; QUIET3 = 5.0; MAX3 = 4; HAPTIC_CD = 5.0

def min_secs(tier): return {1: 3.0, 2: 2.5}.get(tier, 1.5)
def can_interrupt(inc, cur, shown):
    if not inc < cur: return False
    if inc == 1: return True
    return shown >= min_secs(cur)

INIT_GRACE = 3.0; FAST_ANG = 1.5; FAST_LIN = 1.0; LUX = 300.0; CLOSE = 0.3; FAR = 5.0; CLOSER = 3.0
LOWCOV = 0.3; LOWCOV_HOLD = 4.0; EVENT_EXP = 4.0; HYST = 0.1; WIN3 = 60.0

def rank(k): return (MSG[k][0], ORDER.index(k))

def inp(t, **kw):
    d = dict(conf=None, time=t, tracking='normal', ang=0.0, lin=0.0, center=None, lux=None, cov=None, missing=[],
             doors=0, windows=0, walls=0, hot=False, complete=False)
    d.update(kw); return d

class Engine:
    def __init__(self):
        self.current = None; self.shownAt = 0.0; self.isEvent = False; self.lastHidden = None
        self.lastVisible = {}; self.condStart = {}; self.initSince = None; self.lowCovSince = None
        self.t3times = []; self.lastT1 = None; self.lastHaptic = None; self.pending = []; self.run = set()

    def conditions(self, i):
        out = set(); h = HYST
        tr = i['tracking']
        if tr == 'relocalizing': out.add('trackingLost')
        elif tr == 'insufficientFeatures': out.add('trackingLow')
        elif tr == 'initializing':
            if self.initSince is not None and i['time'] - self.initSince > INIT_GRACE: out.add('trackingLow')
        elif tr == 'excessiveMotion': out.add('moveSlower')
        sf = 1 - h if self.current == 'moveSlower' else 1
        if i['ang'] > FAST_ANG*sf: out.add('moveSlower')
        if i['lin'] > FAST_LIN*sf: out.add('moveSlower')
        if i['lux'] is not None:
            lim = LUX*(1 + h if self.current == 'lightingPoor' else 1)
            if i['lux'] < lim: out.add('lightingPoor')
        far_cov = False
        d = i['center']
        if d is not None and d > 0:
            cl = CLOSE*(1 + h if self.current == 'tooClose' else 1)
            fl = FAR*(1 - h if self.current == 'tooFar' else 1)
            ml = CLOSER*(1 - h if self.current == 'moveCloser' else 1)
            if d < cl: out.add('tooClose')
            elif d > fl: out.add('tooFar')
            elif d > ml: far_cov = True
        if i['hot']: out.add('deviceHot')
        if tr != 'normal': return out
        if far_cov: out.add('moveCloser')
        cf = i.get('conf')
        if cf is not None:
            lim = 0.3*(1 + h if self.current == 'moveCloser' else 1)
            center = i['center'] if i['center'] is not None else math.inf
            if cf < lim and not (center <= 1.5): out.add('moveCloser')
        for a in i['missing']: out.add(a)  # already mapped kinds in this port
        if self.lowCovSince is not None and i['time'] - self.lowCovSince >= LOWCOV_HOLD: out.add('needsAnotherPass')
        if i['complete'] and not i['missing']: out.add('roomLooksComplete')
        return out

    def update_timers(self, i):
        if i['tracking'] == 'initializing':
            if self.initSince is None: self.initSince = i['time']
        else: self.initSince = None
        lim = LOWCOV*(1 + HYST if self.current == 'needsAnotherPass' else 1)
        v = i['cov']
        if i['tracking'] == 'normal' and v is not None and v < lim:
            if self.lowCovSince is None: self.lowCovSince = i['time']
        else: self.lowCovSince = None

    def enqueue(self, i):
        exp = i['time'] + EVENT_EXP
        for cnt, k in ((i['windows'], 'windowDetected'), (i['doors'], 'doorDetected'), (i['walls'], 'wallDetected')):
            if cnt > 0:
                for e in self.pending:
                    if e[0] == k: e[1] = exp; break
                else: self.pending.append([k, exp])

    def t3blocked(self, now):
        if self.lastT1 is not None and now - self.lastT1 < QUIET3: return True
        return len(self.t3times) >= MAX3

    def eligible(self, k, now):
        if k == self.current: return False
        lv = self.lastVisible.get(k)
        if lv is not None and now - lv < COOLDOWN: return False
        if MSG[k][0] >= 3 and self.t3blocked(now): return False
        return True

    def show(self, k, ev, now):
        tier, ms, hap = MSG[k]
        self.current = k; self.shownAt = now; self.isEvent = ev
        self.pending = [e for e in self.pending if e[0] != k]
        if tier == 1: self.lastT1 = now; self.pending = []
        if tier >= 3: self.t3times.append(now)
        if tier >= 3 and not ev: self.run.add(k)
        if not (hap and tier == 1): return False
        if self.lastHaptic is not None and now - self.lastHaptic < HAPTIC_CD: return False
        self.lastHaptic = now; return True

    def update(self, i):
        now = i['time']
        self.update_timers(i)
        active = self.conditions(i)
        for k in active:
            if k not in self.condStart: self.condStart[k] = now
        self.condStart = {k: v for k, v in self.condStart.items() if k in active}
        self.run &= active
        self.t3times = [t for t in self.t3times if not (now - t >= WIN3)]
        if self.current is not None and MSG[self.current][0] == 1: self.lastT1 = now
        self.enqueue(i)
        self.pending = [e for e in self.pending if not (e[1] <= now)]
        if self.t3blocked(now): self.pending = []
        best = None; br = (math.inf, math.inf)
        for k in active:
            if k in self.run: continue
            st = self.condStart.get(k)
            if st is None or not (now - st >= HOLD) or not self.eligible(k, now): continue
            rk = rank(k)
            if rk < br: br = rk; best = (k, False)
        for e in self.pending:
            if not self.eligible(e[0], now): continue
            rk = rank(e[0])
            if rk < br: br = rk; best = (e[0], True)
        if self.current is not None:
            c = self.current; tier, ms, _ = MSG[c]
            shown = now - self.shownAt
            holds = (not self.isEvent) and tier < 3 and c in active
            replaced = best is not None and can_interrupt(MSG[best[0]][0], tier, shown)
            if shown >= ms and not holds and not replaced:
                self.lastVisible[c] = now; self.lastHidden = now; self.current = None; self.isEvent = False
        fire = False
        if best is not None:
            tier = MSG[best[0]][0]
            if self.current is not None:
                if can_interrupt(tier, MSG[self.current][0], now - self.shownAt):
                    self.lastVisible[self.current] = now
                    fire = self.show(best[0], best[1], now)
            else:
                gap_ok = True if self.lastHidden is None else (now - self.lastHidden >= GAP)
                if gap_ok or tier == 1:
                    fire = self.show(best[0], best[1], now)
        return (self.current, fire)

class Trace:
    STEP = 0.25
    def __init__(self, ticks, fn):
        e = Engine(); self.out = [e.update(fn(i*Trace.STEP)) for i in range(ticks)]
    def at(self, t):
        i = int(round(t/Trace.STEP))
        return self.out[i] if 0 <= i < len(self.out) else (None, False)
    def msg(self, t): return self.at(t)[0]
    def haptics(self): return sum(1 for o in self.out if o[1])
    def changes(self):
        n = 0; prev = None
        for o in self.out:
            if o[0] != prev: n += 1
            prev = o[0]
        return n
    def appearances(self, t):
        n = 0; prev = None
        for i, o in enumerate(self.out):
            if i*Trace.STEP >= t: break
            if o[0] is not None and o[0] != prev: n += 1
            prev = o[0]
        return n
