// Original procedural artwork for Classic, Third and Pro families.
// Fourth uses the separately credited Blender product renderer; do not overwrite it.
import AppKit
import SceneKit
import Metal

struct Profile {
    let name: String
    let height: CGFloat
    let depth: CGFloat
    let longStem: Bool
    let silicone: Bool
    static let all: [Self] = [
        .init(name: "Classic", height: 1.20, depth: 0.49, longStem: true, silicone: false),
        .init(name: "Third", height: 0.85, depth: 0.40, longStem: false, silicone: false),
        .init(name: "Fourth", height: 0.922, depth: 0.423, longStem: false, silicone: false),
        .init(name: "Pro", height: 0.745, depth: 0.36, longStem: false, silicone: true),
        .init(name: "ProThird", height: 0.76, depth: 0.38, longStem: false, silicone: true)
    ]
}
func material(_ color: NSColor, roughness: CGFloat = 0.22, metal: CGFloat = 0) -> SCNMaterial {
    let m = SCNMaterial(); m.lightingModel = .physicallyBased
    m.diffuse.contents = color; m.roughness.contents = roughness; m.metalness.contents = metal
    return m
}
func node(_ geometry: SCNGeometry, _ material: SCNMaterial, at p: SCNVector3) -> SCNNode {
    geometry.materials = [material]; let n = SCNNode(geometry: geometry); n.position = p; return n
}
func roundedBox(_ w: CGFloat, _ h: CGFloat, _ d: CGFloat, radius: CGFloat) -> SCNBox {
    let b = SCNBox(width: w, height: h, length: d, chamferRadius: radius)
    b.chamferSegmentCount = 12; return b
}
func shell(_ w: CGFloat, _ h: CGFloat, _ d: CGFloat, top: CGFloat, bottom: CGFloat) -> SCNShape {
    let p = NSBezierPath(), k: CGFloat = 0.55228475
    p.flatness = 0.0005
    let l = -w/2, r = w/2, b = -h/2, t = h/2
    p.move(to:.init(x:l+top,y:t));p.line(to:.init(x:r-top,y:t))
    p.curve(to:.init(x:r,y:t-top),controlPoint1:.init(x:r-top+k*top,y:t),controlPoint2:.init(x:r,y:t-top+k*top))
    p.line(to:.init(x:r,y:b+bottom))
    p.curve(to:.init(x:r-bottom,y:b),controlPoint1:.init(x:r,y:b+bottom-k*bottom),controlPoint2:.init(x:r-bottom+k*bottom,y:b))
    p.line(to:.init(x:l+bottom,y:b))
    p.curve(to:.init(x:l,y:b+bottom),controlPoint1:.init(x:l+bottom-k*bottom,y:b),controlPoint2:.init(x:l,y:b+bottom-k*bottom))
    p.line(to:.init(x:l,y:t-top))
    p.curve(to:.init(x:l+top,y:t),controlPoint1:.init(x:l,y:t-top+k*top),controlPoint2:.init(x:l+top-k*top,y:t));p.close()
    let shape=SCNShape(path:p,extrusionDepth:d);shape.chamferRadius=0.032
    let profile=NSBezierPath();profile.flatness=0.0005
    profile.move(to:.init(x:0,y:1));profile.curve(to:.init(x:1,y:0),controlPoint1:.init(x:0.55228475,y:1),controlPoint2:.init(x:1,y:0.55228475))
    shape.chamferProfile=profile
    return shape
}
func centered(_ shape:SCNGeometry,_ mat:SCNMaterial,at position:SCNVector3)->SCNNode {
    let n=node(shape,mat,at:position);let bounds=shape.boundingBox
    n.position.z -= (bounds.min.z+bounds.max.z)/2
    return n
}
// Open, concave charging wells, rather than a dark line drawn across the case.
func well(_ rx: CGFloat, _ rz: CGFloat, depth: CGFloat) -> SCNGeometry {
    let rings = 10, segments = 48
    var vertices: [SCNVector3] = [], normals: [SCNVector3] = [], indices: [Int32] = []
    for ring in 0...rings {
        let r = CGFloat(ring) / CGFloat(rings)
        for j in 0...segments {
            let a = CGFloat(j) / CGFloat(segments) * 2 * .pi
            let x = rx * r * cos(a), z = rz * r * sin(a)
            vertices.append(SCNVector3(x, -depth * (1-r*r), z))
            let dx = -2 * depth * x / (rx*rx), dz = -2 * depth * z / (rz*rz)
            let length = sqrt(dx*dx + 1 + dz*dz); normals.append(SCNVector3(dx/length, 1/length, dz/length))
        }
    }
    for r in 0..<rings { for j in 0..<segments {
        let a = Int32(r * (segments+1) + j), b = a + Int32(segments+1)
        indices += [a,b,a+1,a+1,b,b+1]
    }}
    let g = SCNGeometry(sources: [.init(vertices: vertices), .init(normals: normals)],
                        elements: [.init(indices: indices, primitiveType: .triangles)])
    return g
}
func scene(_ profile: Profile, progress: CGFloat) -> SCNScene {
    let s = SCNScene(); s.background.contents = NSColor.clear
    let white = material(NSColor(white: 0.79, alpha: 1)), inner = material(NSColor(white: 0.75, alpha: 1), roughness: 0.32)
    let dark = material(NSColor(white: 0.025, alpha: 1), roughness: 0.6)
    let clear = SCNMaterial(); clear.diffuse.contents = NSColor.clear; clear.transparency = 0
    let assembly = SCNNode(); s.rootNode.addChildNode(assembly)
    assembly.eulerAngles.y = -0.12 + CGFloat(progress) * 0.08
    let h = profile.height * 0.72, lidH = profile.height - h, top: CGFloat = 0.04
    let body = shell(1,h,profile.depth,top:0.075,bottom:min(0.27,h*0.48))
    assembly.addChildNode(centered(body,white,at:SCNVector3(0,top-h/2,0)))
    for side in [CGFloat(-1),CGFloat(1)] {
        let bowl = node(well(0.15,0.095,depth:0.085),inner,at:SCNVector3(side*0.22,top+0.082,0))
        bowl.opacity = smooth(min(progress/0.16,1));assembly.addChildNode(bowl)
    }
    let ledMaterial = material(NSColor(calibratedRed: 0.12, green: 0.70, blue: 0.26, alpha: 1))
    ledMaterial.emission.contents = NSColor(calibratedRed:0.01,green:0.12,blue:0.02,alpha:1)
    let led = node(SCNSphere(radius:0.009),ledMaterial,at:SCNVector3(0,CGFloat(top-h*0.38),CGFloat(profile.depth/2)+0.001))
    led.scale.z = 0.25; assembly.addChildNode(led)
    // True hinge pivot, solid lid and inset underside: it never becomes a flat
    // capsule stretching through the earbuds at the open pose.
    let lidProgress = smooth(min(progress / 0.48, 1))
    let hinge = SCNNode(); hinge.position = SCNVector3(0,CGFloat(top),-CGFloat(profile.depth/2)+0.035)
    hinge.eulerAngles.x = CGFloat(-1.88 * lidProgress)
    let lid = centered(shell(1,lidH,profile.depth,top:min(0.24,lidH*0.85),bottom:0.025),white,
                   at:SCNVector3(0,lidH/2+0.002,profile.depth/2-0.035))
    hinge.addChildNode(lid)
    for side in [CGFloat(-1),CGFloat(1)] {
        let recess = node(well(0.145,0.09,depth:0.025),inner,
            at:SCNVector3(side*0.22,-0.012,profile.depth/2-0.035))
        recess.eulerAngles.x = .pi
        hinge.addChildNode(recess)
    }
    assembly.addChildNode(hinge)
    let rise = smooth(max(0,min((progress-0.28)/0.72,1)))
    for side in [CGFloat(-1),CGFloat(1)] {
        let bud = SCNNode()
        bud.opacity = smooth(max(0,min((progress-0.10)/0.20,1)))
        let stemH: CGFloat = profile.longStem ? 0.47 : 0.31
        let stem = node(SCNCapsule(capRadius:0.047,height:stemH),white,at:SCNVector3(0,-CGFloat(stemH/2),0))
        bud.addChildNode(stem)
        let head = node(SCNSphere(radius:0.135),white,at:SCNVector3(-side*0.035,0.015,0))
        head.scale = SCNVector3(1.0,profile.longStem ? 0.87 : 1.12,1.03); assembly.name = profile.name
        bud.addChildNode(head)
        // Dark acoustic apertures follow the outward-facing earpiece, instead
        // of painting a generic SF symbol on a flat plane.
        let grille = node(SCNSphere(radius:0.055),dark,at:SCNVector3(-side*0.082,0.02,0.137))
        grille.scale = SCNVector3(0.63,1.05,0.09); grille.eulerAngles.z = CGFloat(side*0.20)
        bud.addChildNode(grille)
        let vent = node(SCNSphere(radius:0.022),dark,at:SCNVector3(side*0.025,0.107,0.092))
        vent.scale = SCNVector3(1.35,0.40,0.25); bud.addChildNode(vent)
        let mic = node(SCNSphere(radius:0.016),dark,at:SCNVector3(0,-CGFloat(stemH)+0.043,0.049))
        mic.scale = SCNVector3(0.65,1.5,0.18); bud.addChildNode(mic)
        if profile.silicone {
            let tip = node(SCNSphere(radius:0.077),material(NSColor(white:0.82,alpha:1),roughness:0.62),
                           at:SCNVector3(-side*0.142,0.006,0.022))
            tip.scale = SCNVector3(0.93,0.93,1.16); bud.addChildNode(tip)
        }
        bud.position = SCNVector3(side*(0.22+CGFloat(rise)*0.025), CGFloat(top)+0.12+CGFloat(rise)*0.46, 0.008+CGFloat(rise)*0.028)
        bud.eulerAngles.z = CGFloat(-side*CGFloat(rise)*0.18)
        bud.eulerAngles.y = CGFloat(-side*(0.25+CGFloat(rise)*0.30))
        assembly.addChildNode(bud)
    }
    let camera = SCNNode(); camera.camera = SCNCamera(); camera.camera!.usesOrthographicProjection = true
    camera.camera!.orthographicScale = profile.longStem ? 1.10 : 0.88; camera.camera!.zNear = 0.1; camera.camera!.zFar = 30
    camera.camera!.wantsHDR = false
    camera.position = SCNVector3(2.3,1.55,7.5); camera.look(at:SCNVector3(0,0.12,0))
    s.rootNode.addChildNode(camera)
    func light(_ kind: SCNLight.LightType, at position: SCNVector3, intensity: CGFloat, color: NSColor) {
        let n=SCNNode();n.light=SCNLight();n.light!.type=kind;n.light!.intensity=intensity;n.light!.color=color
        n.position=position;n.look(at:SCNVector3(0,0,0));s.rootNode.addChildNode(n)
    }
    light(.omni,at:SCNVector3(-3,5,6),intensity:220,color:NSColor(white:1,alpha:1))
    light(.omni,at:SCNVector3(4,1,2),intensity:85,color:NSColor(calibratedRed:0.79,green:0.87,blue:1,alpha:1))
    light(.omni,at:SCNVector3(0,3,-4),intensity:200,color:NSColor(white:1,alpha:1))
    light(.ambient,at:SCNVector3Zero,intensity:100,color:NSColor(white:1,alpha:1))
    return s
}
func smooth(_ x:CGFloat)->CGFloat{x*x*(3-2*x)}
func save(_ image:CGImage,to path:URL) throws {
    let bitmap=NSBitmapImageRep(cgImage:image)
    try bitmap.representation(using:.png,properties:[:])!.write(to:path)
}
let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
let diagnostics=root.appendingPathComponent(".build/diagnostics/release-2.3.49")
try FileManager.default.createDirectory(at:diagnostics,withIntermediateDirectories:true)
let renderer=SCNRenderer(device:MTLCreateSystemDefaultDevice(),options:nil)
func render(_ p:Profile,_ phase:CGFloat)->CGImage {
    renderer.scene=scene(p,progress:phase)
    renderer.pointOfView=renderer.scene!.rootNode.childNodes.first{$0.camera != nil}
    let image=renderer.snapshot(atTime:0,with:CGSize(width:192,height:258),antialiasingMode:.multisampling4X)
    return image.cgImage(forProposedRect:nil,context:nil,hints:nil)!
}
if CommandLine.arguments.contains("--atlas") {
    for p in Profile.all where p.name != "Fourth" {
        let directory=root.appendingPathComponent("DynamicIsland/Assets.xcassets/AirPodsCase\(p.name).imageset")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let context=CGContext(data:nil,width:192*8,height:258*8,bitsPerComponent:8,bytesPerRow:0,
            space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        for frame in 0..<64 {
            autoreleasepool {
                let image=render(p,CGFloat(frame)/63)
                context.draw(image,in:CGRect(x:(frame%8)*192,y:(7-frame/8)*258,width:192,height:258))
            }
        }
        try save(context.makeImage()!,to:directory.appendingPathComponent("frames.png"))
        try Data("{\"images\":[{\"filename\":\"frames.png\",\"idiom\":\"universal\"}],\"info\":{\"author\":\"xcode\",\"version\":1}}\n".utf8).write(to:directory.appendingPathComponent("Contents.json"))
        print("Rendered",p.name);fflush(stdout)
    }
} else {
    for p in Profile.all where p.name != "Fourth" {for (index,phase) in [CGFloat(0),0.45,1].enumerated() {
        try save(render(p,phase),to:diagnostics.appendingPathComponent("\(p.name)-\(index).png"))
    }}
    print("Rendered reference poses")
}
