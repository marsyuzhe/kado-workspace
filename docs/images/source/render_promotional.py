"""Original KADO layouts composed from real screenshots and the existing logo.
Requires Pillow. Does not generate or repaint application UI pixels.
"""
from pathlib import Path
import argparse
from PIL import Image, ImageDraw, ImageFont

ROOT=Path(__file__).resolve().parents[3]
IMAGES=ROOT/'docs/images'
FONT=ROOT/'apps/client/assets/fonts/NotoSansSC.ttf'
BG='#101318';FG='#E6EBF2';MUTED='#9AA8B9';ACCENT='#93A9C7';LINE='#303A47'


def text(draw, pos, value, size, fill=FG, bold=False):
    draw.text(pos,value,font=ImageFont.truetype(str(FONT),size),fill=fill,
              stroke_width=1 if bold else 0,stroke_fill=fill)


def logo(image,x,y,size):
    mark=Image.open(IMAGES/'logo.png').convert('RGB').resize((size,size),Image.Resampling.LANCZOS)
    image.paste(mark,(x,y))


def panel(image,shot,x,y,width):
    source=Image.open(shot).convert('RGB')
    height=round(source.height*width/source.width)
    source=source.resize((width,height),Image.Resampling.LANCZOS)
    draw=ImageDraw.Draw(image)
    draw.rounded_rectangle((x-1,y-1,x+width+1,y+height+1),radius=8,outline=LINE,width=2)
    image.paste(source,(x,y))
    return height


def canvas(w,h):
    image=Image.new('RGB',(w,h),BG)
    return image,ImageDraw.Draw(image)


def save(image,name):
    image.save(IMAGES/name,optimize=True)


def main():
    p=argparse.ArgumentParser();p.add_argument('--captures',type=Path,default=IMAGES);args=p.parse_args()
    shots=args.captures
    for name in ['01_dashboard','03_developer_tools','04_pixel_office']:
        if not (shots/f'{name}.png').exists():raise ValueError('Real screenshot missing: '+name)
    im,d=canvas(1600,600)
    logo(im,64,58,82);text(d,(168,59),'KADO Desk',66,bold=True)
    text(d,(68,201),'Your workspace,',46);text(d,(68,264),'your way.',46)
    d.line((68,360,573,360),fill=LINE,width=2)
    text(d,(68,387),'LOCAL FIRST  /  MODULAR  /  FLUTTER',19,ACCENT)
    text(d,(68,442),'Developer tools. Notes. AI workflows.',23,MUTED)
    text(d,(68,526),'Created and maintained by Links Tam',17,MUTED)
    panel(im,shots/'01_dashboard.png',670,61,862)
    save(im,'hero-banner.png')
    im,d=canvas(1280,640)
    logo(im,56,57,70);text(d,(146,56),'KADO Desk',58,bold=True)
    text(d,(58,191),'Your workspace,',43);text(d,(58,250),'your way.',43)
    text(d,(58,356),'A modular, local-first workspace',21,MUTED)
    text(d,(58,395),'for people who build things.',21,MUTED)
    panel(im,shots/'01_dashboard.png',610,172,614)
    d.line((56,550,1224,550),fill=LINE,width=2)
    text(d,(58,576),'FLUTTER  /  DEVELOPER TOOLS  /  PIXEL OFFICE',17,ACCENT)
    text(d,(1073,576),'Links Tam',17,MUTED)
    save(im,'social-preview.png')
    im,d=canvas(1600,1000)
    logo(im,60,46,60);text(d,(140,47),'A place for your daily tools',46,bold=True)
    items=[('WORKSPACE','Saved navigation and compact launchers'),('DEVELOPER TOOLS','API / JSON / YAML / regex / hashes'),
           ('AI & AGENTS','Configured providers and reviewed artifacts'),('FILES & MEDIA','Preview-based operations; optional engines'),
           ('KNOWLEDGE','Local notes, projects and context'),('WEB & SYSTEM','Bookmarks and explicit diagnostics')]
    for i,(title,desc) in enumerate(items):
        y=172+i*120;text(d,(64,y),f'0{i+1}',19,ACCENT);text(d,(112,y-3),title,24)
        text(d,(112,y+38),desc,18,MUTED)
    panel(im,shots/'01_dashboard.png',680,188,858)
    text(d,(680,720),'Actual Windows UI. Synthetic demo data.',21,ACCENT)
    text(d,(680,764),'Windows tested / Android built / iOS unverified',19,MUTED)
    text(d,(64,937),'KADO Desk 2.4  ·  Created by Links Tam',18,MUTED)
    save(im,'features-overview.png')
    im,d=canvas(1600,1100)
    text(d,(60,38),'Pixel Office',46,bold=True)
    text(d,(464,57),'A real Flame scene with local tasks and review',22,MUTED)
    panel(im,shots/'04_pixel_office.png',60,133,1480)
    text(d,(64,1000),'Local demo characters. No live external AI tasks are claimed in this capture.',23,ACCENT)
    text(d,(64,1045),'Original pixel artwork / CC0 declaration preserved / Links Tam',18,MUTED)
    save(im,'pixel-office-showcase.png')
    im,d=canvas(1600,1080)
    text(d,(60,36),'Developer Tools',44,bold=True)
    text(d,(524,54),'API Studio · actual loopback HTTP response',22,MUTED)
    panel(im,shots/'03_developer_tools.png',60,126,1480)
    text(d,(64,992),'Format data. Check files. Inspect requests. Keep small tasks close.',23,ACCENT)
    text(d,(64,1035),'Real UI capture / Synthetic content / No external API credentials',18,MUTED)
    save(im,'developer-tools-showcase.png')
    print('Generated five original compositions from real captures.')


if __name__=='__main__':main()
