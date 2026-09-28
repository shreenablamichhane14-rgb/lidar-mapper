# Coverage numpy prototype: results

Files in this folder: `coverage_proto.py` (grid, quality, frustum, mesh, samples, union-find, scan quality; float32),
`scenario.py` (the self-test scenario), `variants.py` (pose robustness sweep), `search.py`/`search_fine.py`
(strict-scenario search), `pitfalls.py`, `splat.py`, `normalgate.py`, `timing.py`, `frustum_bench.c`.
Raw output of the scenario at margins 0, 16, 32, -16 px: `scenario_out.txt`.

## 1. Model used (matches the contract)

- quality = distanceTerm * incidenceTerm * confidenceTerm.
  distance: 0 below 0.2; (d-0.2)/0.3 on 0.2..0.5; 1 on 0.5..2.5; (5-d)/2.5 on 2.5..5; 0 at or beyond 5.
  incidence: clamp((cos-0.17)/0.53, 0, 1). confidence: nil -> 0.8, else 0.4 + 0.6*clamp(c).
- d is the Euclidean camera-to-centroid distance. viewCosine = dot(normal, normalize(camPos - centroid)).
- Frustum: pc = R^T (p - t); depth = -pc.z > 0; u = fx*pc.x/depth + cx; v = fy*(-pc.y)/depth + cy;
  -m <= u <= W+m and -m <= v <= H+m. Plus 0.2 <= d <= 5.0 and viewCosine > 0.
- Intrinsics: fx = fy = 1440, cx = 960, cy = 720, imageResolution (1920, 1440). As simd_float3x3 (column-major):
  columns (1440,0,0), (0,1440,0), (960,720,1). Half FOV: 33.69 deg horizontal, 26.57 deg vertical.
- observationCount counts obs with quality > 0; good = quality >= 0.5; state: green if good >= 3 or best >= 0.85,
  yellow if good >= 1 or obs >= 1, else gray.
- Voxel update: ONCE per integrate call per voxel, using the best-quality face whose centroid falls in it
  (see pitfall 6).
- Scenario uses depthConfidenceMean = nil, so max quality = 0.8 < 0.85: green only via 3 good observations.

## 2. Synthetic room and mesh (exact recipe for Swift)

Room: floorPolygon (0,0),(4,0),(4,5),(0,5) in (x,z); floorY 0; ceilingY 2.5; ceilingPolygon empty or same.
Walls in this order (element index = wall index):
- wall 0: (0,0)->(4,0), plane z=0 ("south"), inward normal (0,0,+1)
- wall 1: (4,0)->(4,5), plane x=4, inward normal (-1,0,0)
- wall 2: (4,5)->(0,5), plane z=5, inward normal (0,0,-1)
- wall 3: (0,5)->(0,0), plane x=0, inward normal (+1,0,0)
Inward normal = left normal (-dz, dx)/L of the segment direction for this winding; compute it with a
point-in-polygon test of midpoint + 0.01*n and flip if outside, so either winding works.

Mesh: each rectangle (wall: along = end-start, up = (0,height,0); floor/ceiling: x 0..4, z 0..5) is split into
nu = ceil(L/0.2 - 1e-3) by nv equal cells (walls 20 or 25 by 13 with cell height 2.5/13 = 0.19231; floor and
ceiling 20 by 25). Per cell (i,j) two triangles a=(i,j), b=(i+1,j), c=(i+1,j+1), d=(i,j+1): (a,b,c) and (a,c,d);
centroids at cell coords (i+2/3, j+1/3) and (i+1/3, j+2/3); area = cellArea/2. Normals: walls inward as above,
floor (0,1,0), ceiling (0,-1,0). Face order used: wall0, wall1, wall2, wall3, floor, ceiling; within a rectangle
j outer, i inner, two triangles per cell.
Face counts: wall0 520, wall1 650, wall2 520, wall3 650, floor 1000, ceiling 1000, total 4340.

Expected samples at s = 0.2: walls ceil(L/s - 1e-3) by ceil(h/s - 1e-3) cells. Chosen rule for the partial last
row: the cell spans [j*s, min((j+1)*s, h)], sample at the MIDPOINT of that span (y = 2.45, not 2.5) and weight =
true area (0.2 x 0.1 = 0.02 m2). This makes wall areas exact (10.0 and 12.5 m2). Sample counts: wall0 260,
wall1 325, wall2 260, wall3 325, floor 500, ceiling 500, total 2170. Expected areas: walls 45.0, floor 20.0,
ceiling 20.0 m2.

## 3. Camera path (deterministic)

Position for every pose: (2.0, 1.4, 2.5) (room center, eye height 1.4). R = Ry(yaw) * Rx(pitch), roll 0.
yaw 0 looks toward -Z (wall 0), yaw +90 looks toward -X (wall 3); pitch > 0 looks up.
Swift: forward = (-sin(yaw)*cos(pitch), sin(pitch), -cos(yaw)*cos(pitch)); columns:
col0 = (cos(yaw), 0, -sin(yaw), 0); col1 = (sin(yaw)*sin(pitch), cos(pitch), cos(yaw)*sin(pitch), 0);
col2 = (sin(yaw)*cos(pitch), -sin(pitch), cos(yaw)*cos(pitch), 0); col3 = (2, 1.4, 2.5, 1).

One pass = 11 poses, in this order:

| # | yaw | pitch | forward | cameraToWorld columns 0..3 (column-major) |
|---|---|---|---|---|
| 0 | -5 | 2 | (0.0871, 0.0349, -0.9956) | (0.996195, 0, 0.087156, 0), (-0.003042, 0.999391, 0.034767, 0), (-0.087103, -0.034899, 0.995588, 0), (2, 1.4, 2.5, 1) |
| 1 | 20 | 2 | (-0.3418, 0.0349, -0.9391) | (0.939693, 0, -0.342020, 0), (0.011936, 0.999391, 0.032795, 0), (0.341812, -0.034899, 0.939120, 0), (2, 1.4, 2.5, 1) |
| 2 | 50 | 2 | (-0.7656, 0.0349, -0.6424) | (0.642788, 0, -0.766044, 0), (0.026735, 0.999391, 0.022433, 0), (0.765578, -0.034899, 0.642396, 0), (2, 1.4, 2.5, 1) |
| 3 | 80 | 2 | (-0.9842, 0.0349, -0.1735) | (0.173648, 0, -0.984808, 0), (0.034369, 0.999391, 0.006060, 0), (0.984208, -0.034899, 0.173542, 0), (2, 1.4, 2.5, 1) |
| 4 | 110 | 2 | (-0.9391, 0.0349, 0.3418) | (-0.342020, 0, -0.939693, 0), (0.032795, 0.999391, -0.011936, 0), (0.939120, -0.034899, -0.341812, 0), (2, 1.4, 2.5, 1) |
| 5 | 110 | -40 | (-0.7198, -0.6428, 0.2620) | (-0.342020, 0, -0.939693, 0), (-0.604023, 0.766044, 0.219846, 0), (0.719846, 0.642788, -0.262003, 0), (2, 1.4, 2.5, 1) |
| 6 | 80 | -40 | (-0.7544, -0.6428, -0.1330) | (0.173648, 0, -0.984808, 0), (-0.633022, 0.766044, -0.111619, 0), (0.754407, 0.642788, 0.133022, 0), (2, 1.4, 2.5, 1) |
| 7 | 50 | -40 | (-0.5868, -0.6428, -0.4924) | (0.642788, 0, -0.766044, 0), (-0.492404, 0.766044, -0.413176, 0), (0.586824, 0.642788, 0.492404, 0), (2, 1.4, 2.5, 1) |
| 8 | 20 | -40 | (-0.2620, -0.6428, -0.7198) | (0.939693, 0, -0.342020, 0), (-0.219846, 0.766044, -0.604023, 0), (0.262003, 0.642788, 0.719846, 0), (2, 1.4, 2.5, 1) |
| 9 | -5 | -40 | (0.0668, -0.6428, -0.7631) | (0.996195, 0, 0.087156, 0), (0.056023, 0.766044, -0.640342, 0), (-0.066765, 0.642788, 0.763129, 0), (2, 1.4, 2.5, 1) |
| 10 | 45 | -80 | (-0.1228, -0.9848, -0.1228) | (0.707107, 0, -0.707107, 0), (-0.696364, 0.173648, -0.696364, 0), (0.122788, 0.984808, 0.122788, 0), (2, 1.4, 2.5, 1) |

Observation fields: trackingNormal true, depthConfidenceMean nil, timestamp = pose index * 0.5 (unused by grid).

### Strict "never see wall 1, wall 2 or ceiling" is not robustly achievable from the center
Searched yaw -30..130 and pitch -90..10 at 1 deg steps (greedy set cover, `search_fine.py`):
from (2, 2.5) even with zero margin two top samples of wall 3 near the (0,5) corner stay uncovered; from
(1.6, 2.1) it works only with zero pixel margin. Reasons: the wall-top row (centroid y 2.372) and the first
ceiling face (0.067 m in from the wall) are only about 3 deg apart as seen from 2.5 m; the last useful wall-0
column (x 3.867) and the first wall-1 face (z 0.067) are 2.6 deg apart in azimuth; and the top frustum edge
drops from 26.6 deg elevation at the image center column to 22.6 deg at the corners, so no single pitch fits.
So the recommended scenario is "effectively strict": walls 0 and 3 are fully observed, walls 1 and 2 are
observed only in a one-column strip at the shared corners (mostly corner bleed, pitfall 3; real faces seen:
29 faces of wall 2 at x < 0.34 near the (0,5) corner by poses 4 and 5 with q 0.50..0.60, and 3 faces of
wall 1 at z < 0.14, y < 0.33 near the (4,0) corner by pose 9 with q 0.41..0.43), and the ceiling only in low-quality strips along
walls 0 and 3 (never good). It is robust: identical cluster structure for frustum margins from -16 to +32 px.

## 4. Expected results (margin 0 px; ranges over margins -16..+32 px in brackets)

### Per-face states

| surface | faces | 1 pass gray/yellow/green | 3 passes gray/yellow/green |
|---|---|---|---|
| wall0 z=0 | 520 | 0 / 367 / 153 | 0 / 0 / 520 |
| wall3 x=0 | 650 | 0 / 479 / 171 | 0 / 32 / 618 |
| floor | 1000 | 391 / 417 / 192 | 391 / 132 / 477 |
| wall1 x=4 | 650 | 647 / 3 / 0 | 647 / 3 / 0 |
| wall2 z=5 | 520 | 491 / 29 / 0 | 491 / 0 / 29 |
| ceiling | 1000 | 832 / 168 / 0 | 832 / 168 / 0 |
| total | 4340 | 2361 / 1463 / 516 | 2361 / 335 / 1644 |

Ranges over margins: 1 pass total gray 2308..2385, green 482..570; wall1 non-gray 2..14; ceiling
non-gray 154..197 and ceiling good count always 0 (all ceiling observations have quality < 0.5, so those
faces stay yellow forever from this spot). Wall 0 always 520/520 green after 3 passes. The 32 wall-3 faces
still yellow after 3 passes are near the (0, *, 5) corner: distance about 3.3 m and incidence about 52 deg
give quality 0.47 < 0.5 (seen, never good).
Suggested self-test asserts: walls 0 and 3 have 0 gray faces after 1 pass; wall 0 all green after 3 passes;
wall1 gray >= 630; wall2 gray >= 480; ceiling green == 0; ceiling gray >= 800; floor gray 370..400;
total green after 3 passes in 1600..1700 and strictly more than after 1 pass (482..570).

Anchor faces (face index in the order above; quality per pose, "-" = not in view):
- wall0 face 298 centroid (1.9333, 1.4103, 0): q 0.7997 at poses 0 and 1 only -> after 1 pass yellow (good 2),
  after 2 passes green (good 4).
- wall3 face 2064 centroid (0, 1.4103, 2.4667): q 0.800 at poses 3 and 4 -> yellow after 1 pass, green after 2.
- floor face 2838 centroid (1.9333, 0, 2.4667), under the camera: q 0.800 at pose 10 only ->
  yellow (1 good) after 1 pass, yellow after 2, GREEN after 3. Best test of gray -> yellow -> green.
- floor face 2511 centroid (1.0667, 0, 0.9333): q 0.663 at poses 7, 8, 9 -> green after 1 pass.
- wall1 face 894 centroid (4, 1.4103, 2.5333) and ceiling face 3838 centroid (1.9333, 2.5, 2.4667): never in view
  (gray; after ExpectedSurfaces marking, the voxel is red).
- wall3 face 2290 centroid (0, 2.3718, 4.8667): q 0.472 at pose 4 only -> yellow forever.

### Samples observed (identical after 1 and 3 passes, since poses repeat)
wall0 260/260, wall3 325/325, floor 306/500 [304..312], wall1 14/325 [14..15], wall2 15/260 [14..17],
ceiling 95/500 [90..105].

### Missing areas (minMissingArea 0.08, sorted by area desc). Exactly 4 clusters, none on walls 0 or 3.

| # | surface / element | samples | area m2 | centroid (area-weighted) | normal | suggestedViewpoint |
|---|---|---|---|---|---|---|
| 0 | ceiling / -2 | 405 [395..410] | 16.20 [15.80..16.40] | (2.185, 2.500, 2.789) | (0,-1,0) | (2.185, 1.400, 2.789) |
| 1 | wall / 1 (x=4) | 311 [310..311] | 11.96 [11.92..11.96] | (4.000, 1.254, 2.608) | (-1,0,0) | (2.500, 1.400, 2.608) |
| 2 | wall / 2 (z=5) | 245 [243..246] | 9.42 [9.36..9.46] | (2.115, 1.259, 5.000) | (0,0,-1) | (2.115, 1.400, 3.500) |
| 3 | floor / -1 | 194 [188..196] | 7.76 [7.52..7.84] | (2.827, 0.000, 3.525) | (0,1,0) | (2.827, 1.400, 3.525) |

Centroid ranges over margins: within 0.03 m of the values above. Bounding boxes of cluster samples:
ceiling x 0.3..3.9, z 0.3..4.9; wall1 y 0.1..2.45, z 0.3..4.9; wall2 x 0.3..3.9; floor x 0.5..3.9, z 0.5..4.9.
Suggested tolerances: area +-0.5 m2 (walls +-0.3), centroid +-0.1 m, normal exact (dot > 0.99), viewpoint
+-0.1 m; viewpoint of a wall cluster is exactly 1.5 m from the wall plane (x = 2.5 for wall 1, z = 3.5 for
wall 2), y = 1.4, and inside the floor polygon inset 0.3.
Note: an UNWEIGHTED centroid gives wall y about 1.30 instead of 1.25 (partial top row weight 0.5); use a
tolerance of 0.1 or document the weighting (area-weighted recommended).

### Scan quality (percent)
geometry 46.66 [46.28..47.53], walls 52.49 [52.40..52.71], floor 61.20 [60.80..62.40],
ceiling 19.00 [18.00..21.00], textures 37.63 [37.42..37.88] (area-weighted faces with >= 1 good obs:
wall0 10.00 + wall3 11.88 + floor 9.54 + wall2 0.56 = 31.98 of 85.0 m2).
Suggested asserts: walls 50..55, floor 57..66, ceiling 14..25, geometry 44..50, textures 35..40 (same after
3 passes). geometry = area-weighted: (23.62 + 12.24 + 3.80 m2) / 85 m2 = 39.66 / 85.

### Voxel state counts (stateCounts over voxels, after markExpected with all 2170 sample positions)
1 pass: red 1926, yellow 1438, green 516, gray 0. 3 passes: red 1926, yellow 314, green 1640.
These depend on implementation details (voxel update policy, which voxels exist), so assert only
red > 1500 and green(3 passes) > green(1 pass).

## 5. Pitfalls found

1. Level camera at 1.4 m does not see the floor nearby: first floor hit at 2.80 m (image center column),
   3.37 m (image corners). In a 4 x 5 room seen from the center a level camera sees no floor at all
   toward wall 0. Floor from pitch -10: 1.89 m out; -20: 1.33 m; -30: 0.92 m; -40: 0.61..5.86 m.
   It does see the ceiling beyond 2.20 m horizontal (center column) / 2.64 m (corners).
2. Wall top vs ceiling separation is about 3 deg from 2.5 m, so any pose that sees the wall top row also sees
   some ceiling unless it sits on a 1 to 2 deg band (see section 3).
3. Corner bleed: observedRadius 0.15 with 0.1 voxels means a sample 0.1 m from a corner is within 0.071 m of
   the voxel center of the ADJACENT surface. Result: the first sample column of an unseen wall next to a seen
   wall, and the first ceiling row along a seen wall top, count as observed. Missing clusters stop 0.2 to 0.3 m
   short of corners (wall1 cluster z 0.3..4.9). Shrinking the radius does not help (the needed on-surface radius
   is 0.087). Optional fix (tested, `normalgate.py`): keep a normal sum per voxel and only count voxels whose
   mean normal has dot >= 0.5 with the sample normal (as an added overload); wall1 bleed goes 14 -> 2.
   Not required for the scenario above; the numbers above are WITHOUT the gate.
4. Mesh resolution vs radius: 0.2 m triangles put 2 centroids per 0.2 cell on the diagonal voxels; the
   farthest sample-to-observed-voxel-center distance is 0.087 < 0.15, fine. With 0.3 m triangles walls drop to
   218/260 observed, 0.4 m to 150/260 and false missing clusters appear on fully seen walls (large flat ARKit
   triangles do happen). Fix tested (`splat.py`): when sqrt(area/pi) > 0.75 * voxelSize, also update voxels at
   points of a voxel-spaced grid inside a disk of radius sqrt(area/pi) in the face plane (tangents from the
   normal), cap 25 points. Restores 260/260 up to 0.4 m triangles; no change at 0.2 m.
5. Faces exactly on voxel borders: planes x=0, y=0, z=0 land in key 0 (voxel inside the room), but x=4, z=5,
   y=2.5 land in keys 40, 50, 25 (voxel entirely OUTSIDE the room). Float32 floor(v/0.1f) matched floor(v*10)
   for all tested values (0.3, 0.6, 0.7, 1.4, 2.3, 2.5, 4, 5), but do not rely on it; the radius 0.15 absorbs
   either choice. Overlays should draw at face positions, not voxel centers. isObserved must scan keys
   floor((p - r)/vs) ... floor((p + r)/vs) per axis (up to 4 per axis, 64 lookups), not only the 27 neighbors.
6. Voxel counting: if a voxel's count is incremented once per FACE rather than once per observation, a voxel
   holding several centroids (always, with a dense ARKit mesh) turns green after one frame. Update each touched
   voxel once per integrate call with the best face quality (prototype does this).
7. Sample grid float issues: ceil(5/0.2f) = 25 and ceil(4/0.2f) = 20 in float32 here, but use
   ceil(L/s - 1e-3). With the naive (j+0.5)*s rule the last wall row lands at y = 2.5 on the ceiling line and
   overcounts area (wall 10.4 instead of 10.0 m2).
8. Walls seen from the wrong side: viewCosine must use inward normals; a clockwise polygon with a fixed
   "left normal" rule would flip them and nothing on walls is observed. Use the midpoint interior test.
9. Yellow can be permanent: faces seen only at quality 0 < q < 0.5 (ceiling from this spot, far corners) stay
   yellow however many passes. The self-test must not expect "all seen faces green after N passes".
10. Distance knee: a wall 2.5 m away sits on the 2.5 m knee (q 0.7997 vs 0.8); assert with tolerance.
11. With depthConfidenceMean nil the best possible quality is 0.8 < excellentQuality 0.85; excellence needs
    confidence >= 0.75 (0.75 gives exactly 0.85; use 1.0 to test the one-excellent-observation rule).

## 6. Recommended thresholds
- Keep voxel 0.10, observedRadius 0.15, sampleSpacing 0.20, minMissingArea 0.08, good 0.5, excellent 0.85,
  greenGoodCount 3. They behave as intended on this scenario.
- Frustum margin: 16 px (0.8 % of width) at 1920 x 1440; scale as 0.0083 * width. Results are stable for
  -16..+32 px. Require depth > 0.05 before dividing.
- Add the large-triangle splat (pitfall 4) in integrate; optionally the normal gate (pitfall 3).
- Partial-row rule: midpoint of the partial cell, weighted by its true area; area-weighted cluster centroid.

## 7. Timing
- numpy (vectorized with temporaries, 2.1 GHz Xeon) for 200k faces: 24 ms projection only, 48 ms full
  frustum + range + facing test. Not representative of Swift.
- C scalar loop with early outs (`frustum_bench.c`, 200k faces, random layout, 6.5 % in view, 16 B aligned
  centroid and normal): 2.6 ms per call at -O2, 4.2 ms at -O0, same Xeon, single thread.
- A15 estimate for Swift -O with contiguous [CoverageFace] (32 B stride) and the same early-out order
  (depth test, squared-range test, then projection, then facing only for survivors, sqrt only for survivors):
  about 1.5 to 3 ms per call for 200k faces (6.4 MB streamed, well under memory bandwidth; branch-bound),
  so 3 to 9 ms per second at 2 to 3 Hz. Scoring (quality + stats) of the capped 60k faces adds about 1 ms.
  Debug (-Onone) Swift is 20 to 50x slower; the self-test scenario is only 4340 faces x 33 integrates
  (143k face tests) plus 2170 samples x 64 hash lookups, well under 100 ms even in Debug.
