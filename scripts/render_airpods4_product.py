import bpy, math, sys
from pathlib import Path
from mathutils import Vector, Matrix
# Adapted renders of AirPods 4 by Falah3D, CC BY 4.0. See AIRPODS_ARTWORK.md.
# Run only as an offline authoring tool, never in the app.
ROOT=Path(__file__).resolve().parents[1]
SOURCE=ROOT/'.build/references/AirPods4-Falah3D'
OUT=ROOT/'.build/airpods4-product'
OUT.mkdir(parents=True,exist_ok=True)
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.fbx(filepath=str(SOURCE/'source/AirPods 4.fbx'))
scene=bpy.context.scene
# Start from the original model's closed lid transform.
lid=bpy.data.objects['nJoEOlgGwcdXBHJ'];lid.location=(0,0,0);lid.rotation_euler=(0,0,0)
bpy.context.view_layer.update()
for image in bpy.data.images:
 if image.source=='FILE':
  p=SOURCE/'textures'/Path(image.filepath).name
  if p.exists():image.filepath=str(p); image.reload()
# Bake original world geometry into independently movable product parts.
groups={'nJoEOlgGwcdXBHJ':'lid','MSpBhwzeYpJKGDV':'right','oTgukKFHsbAaGBa':'left'}
for o in list(bpy.data.objects):
 if o.type!='MESH': continue
 ancestor=o; part='case'
 while ancestor:
  if ancestor.name in groups: part=groups[ancestor.name];break
  ancestor=ancestor.parent
 matrix=o.matrix_world.copy();o.parent=None;o.matrix_world=Matrix.Identity(4)
 o.data.transform(matrix);o['part']=part
for o in list(bpy.data.objects):
 if o.type!='MESH':bpy.data.objects.remove(o,do_unlink=True)
for m in bpy.data.materials:
 if not m.use_nodes:continue
 for n in m.node_tree.nodes:
  if n.type=='BSDF_PRINCIPLED' and m.name.startswith(('LKPK','LpOJ')):
   n.inputs['Base Color'].default_value=(.82,.84,.87,1)
   n.inputs['Roughness'].default_value=.19
   n.inputs['Coat Weight'].default_value=.27
   n.inputs['Coat Roughness'].default_value=.13
# Orthographic product view, slight turn and downward angle, no spinning.
target=Vector((0,0,.013))
camData=bpy.data.cameras.new('Product camera');cam=bpy.data.objects.new('Product camera',camData);scene.collection.objects.link(cam)
cam.location=(.026,-.150,.059);cam.rotation_euler=(target-cam.location).to_track_quat('-Z','Y').to_euler()
camData.type='ORTHO';camData.ortho_scale=.093;camData.lens=70;camData.clip_start=.001;camData.clip_end=10;scene.camera=cam
world=bpy.data.worlds.new('Soft studio');scene.world=world;world.use_nodes=True
world.node_tree.nodes['Background'].inputs[0].default_value=(.65,.7,.8,1)
world.node_tree.nodes['Background'].inputs[1].default_value=.35

def light(name,pos,power,size,color):
 d=bpy.data.lights.new(name,'AREA');d.energy=power;d.shape='DISK';d.size=size;d.color=color
 o=bpy.data.objects.new(name,d);scene.collection.objects.link(o);o.location=pos;o.rotation_euler=(target-o.location).to_track_quat('-Z','Y').to_euler()
light('Large softbox',(-.065,-.080,.12),2.0,.10,(1,.97,.94))
light('Cool rim',(.07,.05,.10),2.3,.08,(.83,.9,1))
light('Front fill',(.06,-.09,.025),.5,.10,(1,1,1))
scene.render.engine='CYCLES';scene.cycles.samples=64;scene.cycles.use_denoising=True
scene.render.resolution_x=512;scene.render.resolution_y=688;scene.render.resolution_percentage=100
scene.render.film_transparent=True;scene.render.image_settings.file_format='PNG';scene.render.image_settings.color_mode='RGBA'
scene.view_settings.view_transform='AgX';# Capture a deliberate opening/lift; the last pose is held, never looped shut.
parts=[o for o in bpy.data.objects if o.type=='MESH']
base={o.name:[v.co.copy() for v in o.data.vertices] for o in parts}
hinge=Vector((0,.009593735,.010952774))
def pose(progress):
 def ease(t):
  t=max(0,min(t,1));return t*t*t*(t*(t*6-15)+10)
 lidProgress=ease(progress/.58)
 lift=ease((progress-.26)/.74)
 rotation=Matrix.Rotation(math.radians(-115)*lidProgress,4,'X')
 for o in parts:
  kind=o['part']
  for v,co in zip(o.data.vertices,base[o.name]):
   if kind=='lid':v.co=hinge+rotation@(co-hinge)
   elif kind in ['left','right']:v.co=co+Vector((0,.012*(1-lift),-.037*(1-lift)))
   else:v.co=co
  o.data.update()
 bpy.context.view_layer.update()
scene.cycles.samples=48
scene.render.resolution_x=384;scene.render.resolution_y=516
(OUT/'frames').mkdir(exist_ok=True)
for index in range(64):
 pose(index/63);scene.render.filepath=str(OUT/'frames'/f'{index:02d}.png');bpy.ops.render.render(write_still=True)

bpy.ops.wm.save_as_mainfile(filepath=str(OUT/'product.blend'))
