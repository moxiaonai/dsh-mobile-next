# Monochrome Whale / NEXT

基于用户文字描述重绘：近圆形鲸身、宽面腹部留白、右上扬双叶尾。当前上下文无法读取最初上传的聊天原图，因此不是精确描摹或官方标志复刻。

## 推荐

推荐白底黑鲸（black）：黑色体块的轮廓更稳定，腹部留白更接近用户描述的参考方向。黑底白鲸（white）为同一轮廓反色，用于暗色背景。

- 仅使用 #000000 / #FFFFFF；抗锯齿像素为中性灰，不含蓝色。
- 删除眼睛和嘴部，不使用笑脸、腹部箭头、手机框、阴影或渐变。
- 腹部从鲸身左侧开放延伸，形成宽面留白，不是封闭笑嘴或笑脸弧线；透明 SVG 使用矢量 mask 真挖空。
- NEXT 是自绘矢量字形，字高 28 / 母版 1024，字标框 164 × 58，圆角 15，线宽 3；在鲸鱼右上方独立定位，不与尾鳍粘连。不依赖系统字体。
- SVG 主标为透明背景；角标自身带对比底色。PNG 为 1024 × 1024、不透明 RGB、完整方形背景，不预先烘焙平台圆角。

## 文件

所有文件完整目录：design/logo/monochrome-next/

- [白底适用黑鲸 SVG logo](design/logo/monochrome-next/logo-black.svg)
- [黑底适用白鲸 SVG logo](design/logo/monochrome-next/logo-white.svg)
- [推荐 1024px PNG app icon](design/logo/monochrome-next/app-icon-black-1024.png)
- [反色 1024px PNG app icon](design/logo/monochrome-next/app-icon-white-1024.png)
- [推荐 app icon SVG](design/logo/monochrome-next/app-icon-black-1024.svg)
- [反色 app icon SVG](design/logo/monochrome-next/app-icon-white-1024.svg)
- [双配色及实际小尺寸 PNG 视觉预览](design/logo/monochrome-next/visual-preview.png)
- [机器验证报告](design/logo/monochrome-next/validation.json)
- [可复现构造与渲染脚本](design/logo/monochrome-next/build.py)

## 验证和限制

使用本机 Chrome headless 渲染实际 SVG，每款先以 2048px 栅格化，再使用 Pillow Lanczos 缩至 1024px；检查 SVG XML、PNG 尺寸、不透明 RGB、三通道相同（纯灰阶），并展示 32 / 48 / 64 / 96 / 128px 实际缩小效果。

NEXT 是次级角标：32–48px 时不能保证完整读字，64px 仍应以鲸鱼剪影为主要辨识；需要准确读出 NEXT 建议 ≥96px。小尺寸 UI glyph 建议另用无角标版本，而不是硬塞文字。黑白主色对比为 21:1，但小尺寸字形的可读性不由对比度独自保证。

未做原图叠加比对、官方品牌审核、商标或商业授权确认；若对外公开使用，应核查 DeepSeek 品牌与商标要求。未接入应用、未做 iOS/Android 安装及各平台裁切验收。本次只新增本目录；脚本比较目录以外 579 个现有源码、资源及设计文件的 SHA-256（跳过 node_modules、build 等依赖/缓存目录及符号链接），结果记录在验证报告中。工作区没有 Git 元数据，不能宣称通过 git diff 校验。
