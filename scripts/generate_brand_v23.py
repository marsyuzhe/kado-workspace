"""Original editable geometric icons. One shape list renders SVG and PNG (Pillow)."""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont
import json, hashlib
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'design/brand/v23';OUT.mkdir(parents=True,exist_ok=True)
CLIENT=ROOT/'apps/client'
SHAPES={
 'A': [('rect',(272,272,480,480,28),1),('rect',(544,272,752,480,28),2),('rect',(272,544,480,752,28),2),('rect',(544,544,752,752,28),1)],
 'B': [('poly',[(272,264),(400,264),(400,760),(272,760)],1),('poly',[(432,504),(616,264),(776,264),(548,544)],1),('poly',[(448,528),(564,480),(784,760),(624,760)],2)],
 'C': [('rect',(248,272,776,752,36),1),('rect',(304,384,720,696,4),0),('rect',(320,312,352,344,4),0),('rect',(384,312,416,344,4),0),('rect',(480,384,536,696,0),1),('rect',(576,432,672,528,12),2)],
}
PALETTES={'dark':['#12151B','#D0DBEA','#8EA5C7'],'light':['#E9EDF3','#34445C','#657FA4'],'mono':['#FFFFFF','#111111','#111111']}
def svg(letter,variant='dark',foreground=False):
 colors=PALETTES[variant];out=['<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">','<title>KADO Desk '+letter+' — original geometric mark</title>']
 if not foreground:out.append(f'<rect width="1024" height="1024" fill="{colors[0]}"/>')
 if foreground:out.append('<g transform="translate(512 512) scale(.84) translate(-512 -512)">')
 for kind,coords,idx in SHAPES[letter]:
  color=colors[idx]
  if kind=='rect':
   x,y,x2,y2,r=coords;out.append(f'<rect x="{x}" y="{y}" width="{x2-x}" height="{y2-y}" rx="{r}" fill="{color}"/>')
  else:out.append('<polygon points="'+' '.join(f'{x},{y}' for x,y in coords)+f'" fill="{color}"/>')
 if foreground:out.append('</g>')
 return '\n'.join(out+['</svg>'])
def render(letter,size,variant='dark',foreground=False):
 scale=4 if size<512 else 2;w=size*scale;colors=PALETTES[variant]
 im=Image.new('RGBA',(w,w),(0,0,0,0) if foreground else colors[0]);draw=ImageDraw.Draw(im)
 def n(v):return round(v*w/1024)
 for kind,c,i in SHAPES[letter]:
  if kind=='rect':draw.rounded_rectangle(tuple(n(v) for v in c[:4]),radius=n(c[4]),fill=colors[i])
  else:draw.polygon([(n(x),n(y)) for x,y in c],fill=colors[i])
 return im.resize((size,size),Image.Resampling.LANCZOS)
for letter in SHAPES:
 for variant in PALETTES:
  (OUT/f'candidate_{letter}_{variant}.svg').write_text(svg(letter,variant),encoding='utf-8')
  for size in [1024,256,64,32,16]:render(letter,size,variant).save(OUT/f'{letter}_{variant}_{size}.png',optimize=True)
canvas=Image.new('RGB',(1280,710),'#252A32');d=ImageDraw.Draw(canvas)
font=ImageFont.truetype('C:/Windows/Fonts/arial.ttf',20)
for row,letter in enumerate(SHAPES):
 y=16+row*230;d.text((16,y),f'{letter}  '+{'A':'Modular tiles','B':'Abstract K — selected','C':'Workspace window'}[letter],font=font,fill='#D0DBEA')
 for j,size in enumerate([160,64,32,16]):canvas.paste(render(letter,size),(20+j*185,y+44),render(letter,size))
 for j,variant in enumerate(['light','mono']):canvas.paste(render(letter,128,variant),(820+j*160,y+44))
canvas.save(OUT/'candidate_comparison.png',optimize=True)
# Final source and app resources: B, large silent mark; no text at small sizes.
(OUT/'kado_desk.svg').write_text(svg('B'),encoding='utf-8')
(OUT/'adaptive_foreground.svg').write_text(svg('B',foreground=True),encoding='utf-8')
assets=CLIENT/'assets/brand';assets.mkdir(parents=True,exist_ok=True)
for variant in PALETTES:render('B',1024,variant).convert('RGB').save(OUT/f'final_{variant}_1024.png',optimize=True)
render('B',1024).convert('RGB').save(assets/'app_icon_1024.png',optimize=True)
ico=CLIENT/'windows/runner/resources/app_icon.ico'
render('B',256).save(ico,format='ICO',sizes=[(n,n) for n in [16,24,32,48,64,128,256]])
(OUT/'kado_desk.ico').write_bytes(ico.read_bytes())
res=CLIENT/'android/app/src/main/res'
for density,size in {'mdpi':48,'hdpi':72,'xhdpi':96,'xxhdpi':144,'xxxhdpi':192}.items():
 folder=res/f'mipmap-{density}';folder.mkdir(parents=True,exist_ok=True);render('B',size).save(folder/'ic_launcher.png',optimize=True)
values=res/'values';values.mkdir(exist_ok=True)
(values/'brand_colors.xml').write_text('<resources><color name="kado_icon_background">#12151B</color></resources>\n',encoding='utf-8')
drawable=res/'drawable';drawable.mkdir(exist_ok=True)
for mono in [False,True]:
 out=['<vector xmlns:android="http://schemas.android.com/apk/res/android" android:width="108dp" android:height="108dp" android:viewportWidth="1024" android:viewportHeight="1024">']
 out.append('<group android:pivotX="512" android:pivotY="512" android:scaleX="0.84" android:scaleY="0.84">')
 for _,coords,index in SHAPES['B']:
  data='M'+' L'.join(f'{x},{y}' for x,y in coords)+' Z';color='#FFFFFF' if mono else PALETTES['dark'][index]
  out.append(f'<path android:fillColor="{color}" android:pathData="{data}"/>')
 (drawable/('kado_monochrome.xml' if mono else 'kado_foreground.xml')).write_text('\n'.join(out+['</group>','</vector>']),encoding='utf-8')
for qualifier in ['mipmap-anydpi-v26','mipmap-anydpi-v33']:
 folder=res/qualifier;folder.mkdir(exist_ok=True)
 mono='<monochrome android:drawable="@drawable/kado_monochrome"/>' if qualifier.endswith('33') else ''
 (folder/'ic_launcher.xml').write_text('<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android"><background android:drawable="@color/kado_icon_background"/><foreground android:drawable="@drawable/kado_foreground"/>'+mono+'</adaptive-icon>\n',encoding='utf-8')
ios=CLIENT/'ios/Runner/Assets.xcassets/AppIcon.appiconset';contents=json.loads((ios/'Contents.json').read_text())
for item in contents['images']:
 size=round(float(item['size'].split('x')[0])*float(item.get('scale','1x')[:-1]));render('B',size).convert('RGB').save(ios/item['filename'],optimize=True)
# Appearance resources: optional dark and tinted marketing variants, no alpha.
for appearance,variant in [('dark','dark'),('tinted','mono')]:
 filename=f'Icon-Marketing-{appearance}-1024.png';render('B',1024,variant).convert('RGB').save(ios/filename,optimize=True)
 if not any(i.get('filename')==filename for i in contents['images']):contents['images'].append({'idiom':'universal','platform':'ios','size':'1024x1024','filename':filename,'appearances':[{'appearance':'luminosity','value':appearance}]})
(ios/'Contents.json').write_text(json.dumps(contents,indent=2)+'\n',encoding='utf-8')
mask=Image.new('RGB',(900,320),'#252A32')
for x,shape in [(20,'circle'),(320,'rounded'),(620,'square')]:
 im=render('B',256);alpha=Image.new('L',(256,256),0);g=ImageDraw.Draw(alpha)
 if shape=='circle':g.ellipse((0,0,255,255),fill=255)
 elif shape=='rounded':g.rounded_rectangle((0,0,255,255),radius=56,fill=255)
 else:g.rectangle((0,0,255,255),fill=255)
 mask.paste(im,(x,25),alpha)
mask.save(OUT/'adaptive_masks.png',optimize=True)
import math
assert max(math.hypot(x-512,y-512)*.84 for _,coords,_ in SHAPES['B'] for x,y in coords)<1024*33/108, 'Android foreground must remain within 66dp safe circle'
files={str(p.relative_to(ROOT)).replace('\\','/'):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(OUT.iterdir()) if p.is_file() and p.name!='SHA256.json'}
(OUT/'SHA256.json').write_text(json.dumps({'selected':'B','createdBy':'Links Tam project; original geometric source','files':files},indent=2)+'\n',encoding='utf-8')
print(json.dumps({'selected':'B','candidateFiles':len(files),'windowsIcoSizes':list(Image.open(ico).ico.sizes()),'iosAllRGB':all(Image.open(ios/i['filename']).mode=='RGB' for i in contents['images'])}))
