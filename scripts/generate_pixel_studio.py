"""Original integer-grid pixel art. No downloaded or AI-sampled game assets.

Run with Python + Pillow. Layers, animation tags and palette are editable inputs.
32x48 actors; 32px world tiles; nearest-neighbour only. Author: Links Toolbox.
"""
from pathlib import Path
from PIL import Image, ImageDraw
import json
import math

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / 'apps/client/assets/pixel_studio'
SOURCE = ROOT / 'source_assets/pixel_studio'
TAGS = ['idle','walk_up','walk_down','walk_left','walk_right','sit','typing',
        'reading','thinking','talking','waiting','success','error','stand','meeting','rest','deliver']
PEOPLE = {
 'links': dict(hair='#23252d', coat='#353c49', trim='#879bb7', skin='#e2b99d', style=0),
 'byte': dict(hair='#222d40', coat='#242b3a', trim='#769fc8', skin='#d8ab91', style=1),
 'nova': dict(hair='#636578', coat='#384a68', trim='#b7c7d7', skin='#edd1b0', style=2),
 'ink': dict(hair='#6e4e44', coat='#4c4446', trim='#c6a97e', skin='#e9bca2', style=3),
 'pix': dict(hair='#b4a9a4', coat='#45414f', trim='#b6a1c6', skin='#ecc5ad', style=4),
 'patch': dict(hair='#4a4b51', coat='#949caa', trim='#dce0df', skin='#d9b49c', style=5),
}

def rect(d, xy, fill): d.rectangle(tuple(int(v) for v in xy), fill=fill)

def actor(person, tag, frame):
    layers = {k:Image.new('RGBA',(32,48)) for k in ['shadow','body','face','hair','accessory']}
    s=person['style']; walk=tag.startswith('walk'); phase=frame*math.pi/4
    bounce = -1 if (walk and frame in [1,2,5,6]) or (tag=='idle' and frame in [3,4]) else 0
    if tag=='success' and frame in [2,3,4]: bounce-=2
    seated=tag in ['sit','typing','reading','rest']; y=bounce+(3 if seated else 0)
    if tag=='sit': y=bounce+min(3,frame//2)
    if tag=='stand': y=bounce+max(0,3-frame//2)
    d=ImageDraw.Draw(layers['shadow']); d.ellipse((6,41,26,46), fill='#11151b88')
    d=ImageDraw.Draw(layers['body'])
    # Four-pixel articulated legs with visible shoes and hem.
    left=int(round(math.sin(phase)*2)) if walk else 0
    right=-left
    rect(d,(10,32+y,14,41+left+y),'#222732'); rect(d,(18,32+y,22,41+right+y),'#242b36')
    rect(d,(9,40+left+y,14,43+left+y),'#171b24'); rect(d,(18,40+right+y,23,43+right+y),'#171b24')
    rect(d,(9,24+y,23,34+y),'#171d28'); rect(d,(10,24+y,22,33+y),person['coat'])
    rect(d,(10,25+y,12,31+y),person['trim']); rect(d,(20,25+y,22,31+y),'#343d4b')
    rect(d,(15,25+y,16,32+y),'#a3a6ab'); rect(d,(14,27+y,17,28+y),'#d2c9bb')
    arm=int(round(math.sin(phase)*2)) if walk else 0
    rect(d,(7,25+y+arm,10,33+y+arm),person['coat']); rect(d,(22,25+y-arm,25,33+y-arm),person['coat'])
    rect(d,(8,32+y+arm,10,35+y+arm),person['skin']);rect(d,(22,32+y-arm,24,35+y-arm),person['skin'])
    d=ImageDraw.Draw(layers['face'])
    rect(d,(13,21+y,19,25+y),'#b58071');rect(d,(8,11+y,24,20+y),'#302e38')
    rect(d,(9,10+y,23,20+y),person['skin']);rect(d,(11,20+y,21,23+y),person['skin'])
    rect(d,(9,18+y,10,20+y),'#c28f7e');rect(d,(22,18+y,23,20+y),'#c28f7e')
    if tag!='walk_up':
        eye_y=17+y
        if tag=='idle' and frame==6: eye_y+=1
        rect(d,(12,eye_y,13,eye_y+1),'#242632');rect(d,(19,eye_y,20,eye_y+1),'#242632')
        rect(d,(15,21+y,17,21+y),'#a36c66')
        if tag=='talking' and frame%2:rect(d,(15,20+y,17,21+y),'#754f56')
    d=ImageDraw.Draw(layers['hair'])
    rect(d,(8,8+y,24,13+y),'#171e2a');rect(d,(10,6+y,22,15+y),person['hair'])
    rect(d,(8,10+y,10,17+y),person['hair']);rect(d,(22,11+y,24,16+y),person['hair'])
    if s==0: # short side-part
        rect(d,(12,7+y,22,10+y),'#41444f');rect(d,(12,10+y,15,14+y),person['hair'])
    elif s==1: # swept-up hair and headset
        rect(d,(10,4+y,14,10+y),person['hair']);rect(d,(17,5+y,23,9+y),person['hair'])
        rect(d,(7,14+y,9,20+y),'#769fc8');rect(d,(23,15+y,25,19+y),'#769fc8')
    elif s==2: # rounded bob and spectacles
        rect(d,(7,9+y,10,24+y),person['hair']);rect(d,(22,9+y,25,24+y),person['hair'])
        a=ImageDraw.Draw(layers['accessory']);a.rectangle((10,16+y,15,19+y),outline='#343e54');a.rectangle((18,16+y,23,19+y),outline='#343e54');rect(a,(15,17+y,18,17+y),'#343e54')
    elif s==3: # longer braid, asymmetrical fringe, scarf
        rect(d,(21,15+y,24,30+y),'#69473f');rect(d,(21,27+y,25,29+y),'#c6a97e')
        rect(d,(9,8+y,15,15+y),'#80594a');a=ImageDraw.Draw(layers['accessory']);rect(a,(11,24+y,21,26+y),'#b09072')
    elif s==4: # beret and two locks
        rect(d,(7,5+y,25,9+y),'#655a76');rect(d,(10,3+y,22,6+y),'#655a76');rect(d,(8,8+y,24,10+y),'#9380a1')
        rect(d,(8,16+y,10,24+y),person['hair']);rect(d,(22,17+y,25,25+y),person['hair'])
    else: # laboratory cap, compact hair and badge
        rect(d,(9,5+y,23,9+y),'#c6cdd3');rect(d,(8,9+y,24,11+y),'#929eac');a=ImageDraw.Draw(layers['accessory']);rect(a,(18,27+y,21,31+y),'#e2e5e2')
    a=ImageDraw.Draw(layers['accessory'])
    if tag in ['typing','sit']:
        h=frame%3;rect(a,(9,30+y-h,13,32+y-h),person['skin']);rect(a,(19,30+y+h%2,23,32+y+h%2),person['skin'])
    if tag=='reading' or (s==3 and tag=='idle'):
        rect(a,(10,29+y,21,36+y),'#d3c4a3');rect(a,(15,30+y,16,35+y),'#9a8269');rect(a,(11,31+y,14,31+y),'#8d8271')
    if tag=='thinking':
        rect(a,(21,21+y,23,27+y),person['skin']);a.ellipse((23,1,29,7),fill='#bdc8d7');rect(a,(25,3,26,5),'#37455f')
    if tag=='waiting':
        rect(a,(25,2,29,8),'#c7b584');rect(a,(26,3,28,4),'#534b3e');rect(a,(27,6,28,7),'#534b3e')
    if tag=='success':
        rect(a,(23,20+y,25,30+y),person['coat']);rect(a,(24,18+y,26,22+y),person['skin']);a.line((25,8,27,10,30,5),fill='#b9cab6',width=2)
    if tag=='error':
        a.line((25,3,30,8),fill='#ce8f91',width=2);a.line((30,3,25,8),fill='#ce8f91',width=2)
    if tag=='meeting':
        rect(a,(10,29+y,21,36+y),'#d3c4a3');rect(a,(15,30+y,16,35+y),'#9a8269')
        rect(a,(23,23+y-frame%2,25,29+y-frame%2),person['skin'])
    if tag=='rest':
        rect(a,(19,29+y,24,34+y),'#d5c5a9');rect(a,(21,27+y,23,28+y),'#6f5849')
    if tag=='deliver':
        rect(a,(8,27+y,23,37+y),'#cbb58d');rect(a,(10,29+y,21,30+y),'#7b89a0');rect(a,(10,33+y,19,34+y),'#7b89a0')
    result=Image.new('RGBA',(32,48))
    for layer in layers.values():result.alpha_composite(layer)
    if tag=='walk_left': result=result.transpose(Image.Transpose.FLIP_LEFT_RIGHT)
    if tag=='walk_right': # side face; keep hair silhouette and visible nose
        q=ImageDraw.Draw(result);rect(q,(23,17+y,25,19+y),person['skin'])
    if tag=='walk_up':
        q=ImageDraw.Draw(result);rect(q,(9,11+y,23,20+y),person['hair']);rect(q,(11,20+y,21,21+y),person['hair'])
    return result,layers

def furniture(kind):
    im=Image.new('RGBA',(96,96));d=ImageDraw.Draw(im)
    def r(xy,c):rect(d,xy,c)
    d.ellipse((5,58,91,88),fill='#0c111c77')
    if kind=='desk':
        r((8,40,13,74),'#252e3d');r((80,40,85,74),'#252e3d');r((5,23,91,49),'#2c3141');r((5,21,91,42),'#756957');r((7,22,89,39),'#a38d6e');r((8,25,87,38),'#8e7b65')
        r((29,2,66,25),'#161e2e');r((32,4,63,20),'#405876');r((35,7,57,8),'#a0b3ce');r((35,11,51,12),'#7899b5');r((35,15,59,16),'#7990a4');r((45,26,50,29),'#333d50');r((38,29,57,30),'#485469');r((34,32,61,37),'#3d4655')
        for x in range(37,60,4):r((x,33,x+1,35),'#9fa9ad')
        r((74,29,79,35),'#c7b697');r((75,27,78,28),'#89785e');r((12,16,15,29),'#3c4352');r((11,16,28,18),'#d3b577');r((21,19,28,24),'#e5c78e')
        r((33,52,64,72),'#2c3446');r((35,50,62,68),'#4f5c73');r((39,72,57,82),'#344058');r((46,82,50,88),'#202a39')
    elif kind=='meeting':
        for x,y in [(4,26),(74,26),(4,61),(74,61)]:r((x,y,x+17,y+22),'#3e4b64');r((x+2,y+2,x+15,y+17),'#5b6981')
        r((22,22,74,80),'#282d3b');r((23,16,73,72),'#8a7964');r((26,18,70,68),'#b5a184');r((40,30,57,44),'#d8d5c3');r((43,34,54,35),'#6f7e8b');r((47,53,55,60),'#445d78')
    elif kind=='sofa':
        r((4,38,90,77),'#252c3d');r((6,28,88,61),'#526078');r((10,30,44,53),'#6b7790');r((48,30,84,53),'#606e86');r((10,55,83,69),'#66748c');r((3,45,13,70),'#46536d');r((83,45,93,70),'#46536d');r((13,76,18,81),'#1c2637');r((79,76,84,81),'#1c2637');r((17,38,30,50),'#b09580')
    elif kind=='plant':
        r((34,59,63,80),'#6d6059');r((31,55,66,61),'#a08a76');r((46,22,49,56),'#596956')
        for x,y in [(31,22),(51,16),(23,36),(56,34),(39,10)]:
            r((x,y,x+15,y+9),'#566c64');r((x+2,y-3,x+10,y+10),'#768879');r((x+2,y+2,x+9,y+5),'#95a28a')
    elif kind=='shelf':
        r((9,9,84,80),'#222b3d');r((12,8,81,77),'#796c5c')
        for y in [13,34,55]:
            r((16,y,77,y+16),'#343b4a')
            for i,c in enumerate(['#7e91b1','#ba9b79','#797b94','#a1a595','#98858a','#556b8c']):
                r((19+i*9,y+2,24+i*9,y+14),c);r((19+i*9,y+5,24+i*9,y+6),'#c5c3b1')
    elif kind=='coffee':
        r((13,34,82,76),'#526075');r((12,28,83,38),'#8f9ba9');r((25,3,68,30),'#242e40');r((29,5,65,15),'#6d7e91');r((38,17,56,29),'#181f2e');r((41,24,51,30),'#d0c2a6');r((57,9,61,12),'#c6ae79');r((17,43,78,45),'#37445b');r((44,49,49,55),'#b5bac0')
    im.save(ASSETS/'furniture'/f'{kind}.png')

def room():
    im=Image.new('RGBA',(640,448),'#111724');d=ImageDraw.Draw(im)
    # 3/4 wall, outlined panels, raised baseboards, oak-grey floor.
    for y in range(64,416,32):
        for x in range(32,608,32):
            c='#434550' if (x//32+y//32)%2 else '#484a55';rect(d,(x,y,x+31,y+31),c);rect(d,(x+1,y+30,x+30,y+31),'#3b3e49');rect(d,(x+16,y+3,x+16,y+26),'#4c4e58')
    rect(d,(18,15,621,65),'#343d50');rect(d,(18,65,621,70),'#6b7080');rect(d,(18,71,621,75),'#232d40');rect(d,(18,75,31,429),'#252f43');rect(d,(608,75,621,429),'#252f43');rect(d,(18,418,621,429),'#171f30')
    for x in [58,248,438]:
        rect(d,(x,23,x+111,55),'#19253d');rect(d,(x+4,26,x+107,50),'#536c92');rect(d,(x+8,28,x+55,48),'#6880a0');rect(d,(x+56,25,x+59,53),'#b2b3b0');rect(d,(x,54,x+111,58),'#8a8a86')
        rect(d,(x+12,50,x+99,51),'#c9b68c')
    # Entrance and rug, meeting whiteboard, clock and status monitor.
    rect(d,(295,414,351,447),'#756856');rect(d,(299,417,347,447),'#9b8a71');rect(d,(294,381,352,409),'#28374e')
    for x in range(300,348,5):rect(d,(x,386,x+1,405),'#52637a')
    rect(d,(537,83,592,131),'#a6afa9');rect(d,(541,87,588,127),'#d5d5be');d.line((546,118,557,106,568,111,581,94),fill='#5b7289',width=2)
    d.ellipse((198,25,223,50),fill='#b8b8b0');d.ellipse((201,28,220,47),fill='#30394d');d.line((211,31,211,38,217,41),fill='#dbceb0',width=1)
    rect(d,(363,25,415,51),'#131c2e');rect(d,(367,29,411,47),'#4c6381');rect(d,(370,32,390,34),'#a6b8cf');rect(d,(370,39,405,41),'#7e9bb9')
    # Ceiling strip lights use hard-edged warm accents, no blurry interpolation.
    for x in [44,222,400,578]:rect(d,(x,13,x+18,16),'#dfc493');rect(d,(x+2,17,x+16,19),'#8d8069')
    im.save(ASSETS/'rooms/office_shell.png')

def main():
    for name in ['characters','furniture','rooms','atlases','tiles','effects','ui','audio']:(ASSETS/name).mkdir(parents=True,exist_ok=True)
    SOURCE.mkdir(parents=True,exist_ok=True)
    manifest=[]
    for name,p in PEOPLE.items():
        atlas=Image.new('RGBA',(256,48*len(TAGS)));frames={}
        for row,tag in enumerate(TAGS):
            for frame in range(8):
                im,layers=actor(p,tag,frame);atlas.alpha_composite(im,(frame*32,row*48))
                frames[f'{tag}_{frame}']={'x':frame*32,'y':row*48,'w':32,'h':48,'durationMs':100 if tag.startswith('walk') else 50 if tag in ['sit','stand'] else 160}
                if row==0 and frame==0:
                    for key,layer in layers.items():
                        layerDir=SOURCE/name;layerDir.mkdir(exist_ok=True);layer.save(layerDir/f'{key}.png')
        atlas.save(ASSETS/'characters'/f'{name}.png')
        (ASSETS/'atlases'/f'{name}.json').write_text(json.dumps({'assetId':name,'frameWidth':32,'frameHeight':48,'frames':frames,'animationTags':TAGS},indent=2),encoding='utf-8')
        manifest.append(dict(assetId=name,type='spriteSheet',author='Links Toolbox / Links Tam',source='scripts/generate_pixel_studio.py',origin='original integer-grid drawing',license='CC0-1.0',dimensions=[256,48*len(TAGS)],frameCount=len(TAGS)*8,frameDuration={'walk':100,'sit':50,'stand':50,'default':160},animationTags=TAGS,version=2))
    for kind in ['desk','meeting','sofa','plant','shelf','coffee']:
        furniture(kind);manifest.append(dict(assetId=kind,type='furniture',author='Links Toolbox / Links Tam',source='scripts/generate_pixel_studio.py',origin='original integer-grid drawing',license='CC0-1.0',dimensions=[96,96],frameCount=1,frameDuration=0,animationTags=[],version=2))
    room();manifest.append(dict(assetId='office_shell',type='room',author='Links Toolbox / Links Tam',source='scripts/generate_pixel_studio.py',origin='original integer-grid drawing',license='CC0-1.0',dimensions=[640,448],frameCount=1,frameDuration=0,animationTags=[],version=2))
    (ASSETS/'atlases/manifest.json').write_text(json.dumps(manifest,indent=2,ensure_ascii=False),encoding='utf-8')
    (SOURCE/'palette.json').write_text(json.dumps(PEOPLE,indent=2),encoding='utf-8')
    (SOURCE/'README.md').write_text(f'# Original pixel source\n\nEdit the generator and palette; each actor also has separate shadow/body/face/hair/accessory PNG layers. No Aseprite file is claimed. Rebuild with `python scripts/generate_pixel_studio.py`. Runtime atlas contains {len(TAGS)} actions × 8 frames; character canvas 32×48, tile 32, nearest-neighbour rendering. License: CC0-1.0 for these original visual assets.\n',encoding='utf-8')
    preview=Image.new('RGBA',(640,448));preview.alpha_composite(Image.open(ASSETS/'rooms/office_shell.png'))
    for x,y in [(2,3),(7,3),(12,3),(2,6),(7,6),(12,6)]:preview.alpha_composite(Image.open(ASSETS/'furniture/desk.png'),(x*32,y*32-16))
    for i,name in enumerate(PEOPLE):
        frame,_=actor(PEOPLE[name],'idle',0);preview.alpha_composite(frame,(80+i*78,270))
    preview.resize((1280,896),Image.Resampling.NEAREST).save(SOURCE/'art_review.png')
    print(f'Generated {len(manifest)} original assets, {6*len(TAGS)*8} animation frames and 30 editable actor layers.')

if __name__=='__main__':main()
