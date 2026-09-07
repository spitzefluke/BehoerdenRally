// Amtsstempel — classic German office rubber stamp, built from primitives.
// Used by the site's stamp-overlay animation (see behoerdenrallye.html).
export function buildStamp(THREE) {
  const g = new THREE.Group();
  g.name = 'amtsstempel';

  const walnut = new THREE.MeshStandardMaterial({ name: 'walnut', color: 0x6b3f24, roughness: 0.58, metalness: 0.0 });
  const brass = new THREE.MeshStandardMaterial({ name: 'brass', color: 0xc9a34e, roughness: 0.34, metalness: 0.35 });
  const rubber = new THREE.MeshStandardMaterial({ name: 'rubber', color: 0x22222a, roughness: 0.92, metalness: 0.0 });
  const ink = new THREE.MeshStandardMaterial({ name: 'ink_red', color: 0xc8102e, roughness: 0.45, metalness: 0.0 });
  const paper = new THREE.MeshStandardMaterial({ name: 'label_paper', color: 0xe8e2d4, roughness: 0.85, metalness: 0.0 });

  const add = (geo, mat, name, y) => {
    const m = new THREE.Mesh(geo, mat);
    m.name = name;
    m.position.y = y;
    m.castShadow = true;
    m.receiveShadow = true;
    g.add(m);
    return m;
  };

  // rubber die plate + inked rim
  add(new THREE.CylinderGeometry(0.052, 0.052, 0.009, 48), rubber, 'die_plate', 0.0045);
  const rim = new THREE.Mesh(new THREE.TorusGeometry(0.0485, 0.0028, 16, 64), ink);
  rim.name = 'ink_rim';
  rim.rotation.x = Math.PI / 2;
  rim.position.y = 0.0016;
  rim.castShadow = true;
  g.add(rim);
  // raised type bars on the die face (what prints)
  for (let i = 0; i < 3; i++) {
    const w = [0.066, 0.078, 0.056][i];
    const bar = new THREE.Mesh(new THREE.BoxGeometry(w, 0.0024, 0.009), ink);
    bar.name = 'type_bar_' + (i + 1);
    bar.position.set(0, 0.0012, (i - 1) * 0.015);
    g.add(bar);
  }

  // wooden mount disc, chamfered by a second thinner disc
  add(new THREE.CylinderGeometry(0.058, 0.0572, 0.016, 48), walnut, 'mount_disc', 0.017);
  add(new THREE.CylinderGeometry(0.0552, 0.058, 0.004, 48), walnut, 'mount_chamfer', 0.027);
  // paper index label glued to the disc edge
  const label = new THREE.Mesh(new THREE.CylinderGeometry(0.0582, 0.0574, 0.007, 48, 1, true), paper);
  label.name = 'index_label';
  label.position.y = 0.0165;
  g.add(label);

  // brass collar between disc and turned handle
  add(new THREE.CylinderGeometry(0.026, 0.0305, 0.008, 40), brass, 'collar', 0.033);

  // turned handle: profile of revolution, neck into mushroom knob
  const profile = [
    [0.0012, 0.0360], [0.0248, 0.0372], [0.0168, 0.0440], [0.0102, 0.0532],
    [0.0090, 0.0645], [0.0098, 0.0722], [0.0168, 0.0782], [0.0288, 0.0852],
    [0.0322, 0.0916], [0.0302, 0.0972], [0.0228, 0.1012], [0.0118, 0.1033],
    [0.0012, 0.1038]
  ].map(p => new THREE.Vector2(p[0], p[1]));
  const handle = new THREE.Mesh(new THREE.LatheGeometry(profile, 48), walnut);
  handle.name = 'handle';
  handle.castShadow = true;
  handle.receiveShadow = true;
  g.add(handle);

  // brass accent rings on the neck
  [[0.0112, 0.0510], [0.0104, 0.0708]].forEach((r, i) => {
    const ring = new THREE.Mesh(new THREE.TorusGeometry(r[0], 0.0016, 12, 48), brass);
    ring.name = 'neck_ring_' + (i + 1);
    ring.rotation.x = Math.PI / 2;
    ring.position.y = r[1];
    ring.castShadow = true;
    g.add(ring);
  });

  return g;
}
