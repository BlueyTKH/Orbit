# AirPods connection artwork

The app plays one three-second sequence of offline 3D frames, then stops its timeline and **holds the final open pose while connected**. Closing plays only for a disconnection event. The card still uses its configured dismissal duration. Reduce Motion uses the existing static device symbol. No live 3D renderer or new helper runs in the app.

## AirPods 4: accepted product model

The user approved the detailed replacement preview on 16 October 2026 ("much better"). AirPods 4 uses **AirPods 4 by Falah3D / 3dFalah**, **CC BY 4.0**:

- Original: https://sketchfab.com/3d-models/airpods-4-e44730974131402eb496352cab19c82e
- Author: https://sketchfab.com/3dFalah
- License: https://creativecommons.org/licenses/by/4.0/
- Public source redistribution: https://github.com/andre94/clawd-airpods4-anc-case/tree/main/assets/reference/airpods-4
- Provenance: https://github.com/andre94/clawd-airpods4-anc-case/blob/main/THIRD_PARTY_NOTICES.md

Only that original AirPods asset is used, not the Clawd protective cover. Attribution/changes are recorded in root NOTICE, bundled AirPodsArtworkCredits.txt and Settings → About. The redistribution documents title/date/vertex/triangle identification rather than a fresh Sketchfab download checksum; local source hashes are in `.build/diagnostics/airpods-artwork-revision/source-sha256.json`.

Changes: closed/seated and lifted poses, hinge animation, adjusted materials, studio lighting and a fixed orthographic camera. Offline Blender rendering produces product frames; these are scaled and packed into the app atlas. There is no new live renderer/framework in the app.

The original FBX, textures and license are kept in `.build/references/AirPods4-Falah3D/` (source/AirPods 4.fbx, textures/*, CC-BY-4.0.txt). Use the credited public source above if recreating that authoring input. Run from the project root:

```sh
/Applications/Blender.app/Contents/MacOS/Blender --background --python scripts/render_airpods4_product.py
swift scripts/pack_airpods4_artwork.swift
```

The 2.3.50 atlas is packed from the exact 64 approved preview frames in `.build/diagnostics/airpods-artwork-revision/frames/`, using the packer's optional frame-directory argument. That preserves the approved lighting/framing without an unnecessary rerender.

## Other model families

Classic (1/2), Third, Pro and ProThird retain the original procedural illustrations from `render_airpods_artwork.swift`; they are not the newly accepted AirPods 4 model. Max retains its headphone symbol. The legacy renderer skips Fourth to prevent overwriting the licensed product artwork:

```sh
swiftc scripts/render_airpods_artwork.swift -o /private/tmp/render-airpods-artwork
/private/tmp/render-airpods-artwork --atlas
```

Historical proportion/presentation references for those original illustrations: [Apple model identification](https://support.apple.com/en-ie/109525) and [geevisual55's AirPods Pro visual reference](https://sketchfab.com/models/ce731a7f8e15476c8487a264ea8c675f/embed). No third-party geometry is used for those families.

## Frame contract

Each AirPodsCase*.imageset is an 8×8 RGBA atlas: 64 frames of 192×258 pixels. Runtime artwork geometry is 16×21.6 points in Small and, since 2.3.51, 40×54 points in Expanded, inside the existing card/camera-safe lanes. NSCache holds two recently used families. Keep the model frameCount, tile count, crop orientation and renderer output synchronized. Battery-reading updates must not restart playback. Shared Atoll, Mac battery and notch/window animations are unrelated and must remain unchanged.
