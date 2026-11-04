import math, os, sys
OUT = sys.argv[1]
DEEP, JADE, PORC = "#04443F", "#299B8D", "#F2F8F7"
DK_BG, DK_REAR, DK_FRONT = "#062F2B", "#E3F1EE", "#3FB8A8"

def f(v): return ("%.2f" % v).rstrip("0").rstrip(".")

def rounded(poly, radii):
    """Closed convex polygon (clockwise in y-down) with a true arc at each vertex."""
    n = len(poly); segs = []
    for i in range(n):
        P, V, N = poly[i-1], poly[i], poly[(i+1) % n]
        r = radii[i]
        ux, uy = P[0]-V[0], P[1]-V[1]; lu = math.hypot(ux, uy); ux, uy = ux/lu, uy/lu
        wx, wy = N[0]-V[0], N[1]-V[1]; lw = math.hypot(wx, wy); wx, wy = wx/lw, wy/lw
        th = math.acos(max(-1, min(1, ux*wx + uy*wy)))
        t = r / math.tan(th/2) if r else 0
        segs.append(((V[0]+ux*t, V[1]+uy*t), (V[0]+wx*t, V[1]+wy*t), r))
    d = "M%s %s" % (f(segs[0][1][0]), f(segs[0][1][1]))
    for i in range(1, n+1):
        a, b, r = segs[i % n]
        d += " L%s %s" % (f(a[0]), f(a[1]))
        if r: d += " A%s %s 0 0 1 %s %s" % (f(r), f(r), f(b[0]), f(b[1]))
    return d + " Z"

def para(x, y, length, h, ang, r, left_slant=True, right_slant=True, rl=None):
    """Bar whose top edge starts at x; slanted ends lean right (top further right)."""
    dx = h / math.tan(math.radians(ang))
    tl = (x, y); tr = (x+length, y)
    br = (x+length-dx, y+h) if right_slant else (x+length, y+h)
    bl = (x-dx, y+h) if left_slant else (x, y+h)
    rad = [r]*4 if rl is None else rl
    return rounded([tl, tr, br, bl], rad)

def bbox_center(bars):
    pass

# Each variant: list of (path_d, role) in a 256 symbol box, built then centred.
def A1():  # faithful: equal-height 60° slabs, rear 87%, rightward stagger
    h, g, L, ang, r = 54, 34, 170, 60, 12
    rear = (0, 0, L*0.87, h, ang, r)
    front = (34, h+g, L, h, ang, r)
    return [rear, front], {}
def A2():  # card slabs: rounded-rect ends, only the right end leans forward
    h, g, L, ang, r = 54, 34, 168, 60, 13
    rear = (0, 0, L*0.80, h, ang, r, False, True)
    front = (30, h+g, L, h, ang, r, False, True)
    return [rear, front], {}
def A3():  # depth: steeper 68°, rear thinner + shorter (recedes), bigger stagger
    hr, hf, g, L, ang, r = 40, 56, 34, 172, 68, 11
    rear = (6, 0, L*0.78, hr, ang, r)
    front = (40, hr+g, L, hf, ang, r)
    return [rear, front], {}

def build(spec, box, pad_frac):
    bars, _ = spec
    paths = []
    # compute raw extents
    xs, ys = [], []
    for b in bars:
        x, y, L, h, ang = b[:5]
        dx = h / math.tan(math.radians(ang))
        ls = b[6] if len(b) > 6 else True
        xs += [x-dx if ls else x, x+L]; ys += [y, y+h]
    w, hgt = max(xs)-min(xs), max(ys)-min(ys)
    avail = box * (1 - 2*pad_frac)
    s = avail / max(w, hgt)
    ox = (box - w*s)/2 - min(xs)*s
    oy = (box - hgt*s)/2 - min(ys)*s - box*0.01  # optical: slightly above centre
    out = []
    for b in bars:
        x, y, L, h, ang, r, *rest = b
        ls = rest[0] if len(rest) > 0 else True
        rs = rest[1] if len(rest) > 1 else True
        out.append(para(ox + x*s, oy + y*s, L*s, h*s, ang, r*s, ls, rs))
    return out

def svg(box, body, extra=""):
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {box} {box}" width="{box}" height="{box}"{extra}>\n  <title>Remvel</title>\n{body}\n</svg>\n'

def glyph(spec, name, box=18, pad=1.0/18):
    # menu bar cut: shorter bars (more square footprint), same slant, gap kept open
    bars, _ = spec
    tb = []
    for b in bars:
        b = list(b); b[2] = b[2]*0.72; b[0] = b[0]*0.75; b[3] = b[3]*0.62; b[5] = b[5]*0.8
        tb.append(tuple(b))
    paths = build((tb, {}), box, pad)
    body = "\n".join(f'  <path d="{d}" fill="#000"/>' for d in paths)
    open(f"{OUT}/{name}-menubar.svg", "w").write(svg(box, body))

for name, fn in [("a1", A1), ("a2", A2), ("a3", A3)]:
    spec = fn()
    sym = build(spec, 256, 0.06)
    open(f"{OUT}/{name}-symbol-black.svg", "w").write(svg(256, "\n".join(f'  <path d="{d}" fill="#000"/>' for d in sym)))
    open(f"{OUT}/{name}-symbol.svg", "w").write(svg(256, f'  <path d="{sym[0]}" fill="{DEEP}"/>\n  <path d="{sym[1]}" fill="{JADE}"/>'))
    # icon layers on 1024 canvas, artwork inset (system mask supplies the squircle)
    ic = build(spec, 1024, 0.13)
    open(f"{OUT}/{name}-icon-bg.svg", "w").write(svg(1024, f'  <rect width="1024" height="1024" fill="{PORC}"/>'))
    open(f"{OUT}/{name}-icon-rear.svg", "w").write(svg(1024, f'  <path d="{ic[0]}" fill="{DEEP}"/>'))
    open(f"{OUT}/{name}-icon-front.svg", "w").write(svg(1024, f'  <path d="{ic[1]}" fill="{JADE}"/>'))
    # flattened previews (light + dark) with a squircle-ish mask for viewing only
    mask = '<rect x="0" y="0" width="1024" height="1024" rx="230" fill="{}"/>'
    open(f"{OUT}/{name}-icon-preview.svg", "w").write(svg(1024, mask.format(PORC) + f'\n  <path d="{ic[0]}" fill="{DEEP}"/>\n  <path d="{ic[1]}" fill="{JADE}"/>'))
    open(f"{OUT}/{name}-icon-preview-dark.svg", "w").write(svg(1024, mask.format(DK_BG) + f'\n  <path d="{ic[0]}" fill="{DK_REAR}"/>\n  <path d="{ic[1]}" fill="{DK_FRONT}"/>'))
    glyph(spec, name)
print("ok")
