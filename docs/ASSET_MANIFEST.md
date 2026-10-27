# 像素资产与许可

权威机器清单：apps/client/assets/pixel_studio/atlases/manifest.json。

作者Links Toolbox / Links Tam，来源scripts/generate_pixel_studio.py，视觉资源CC0-1.0。1.6起六人各256×816图集、136帧（17动作×8），保留原13动作并增加起身/会议/休息/交付，总816帧；6个家具96×96，室内640×448。人物32×48、tile32。Manifest包含type、dimensions、frameCount、frameDuration、origin、license、version；坐下/起身50ms、走路100ms、其他160ms。没有下载商业游戏素材。

source_assets/pixel_studio 含各人物 shadow/body/face/hair/accessory 图层、palette.json、README 和美术预览。没有 Aseprite 可执行程序，不声称存在 .aseprite 文件。脚本可重复重建全部 PNG/帧 JSON；真实场景截图另在 artifacts/v2-studio，不能用美术预览冒充原生运行截图。

Flame MIT 与依赖许可在发布时从实际包补充到第三方许可清单。
