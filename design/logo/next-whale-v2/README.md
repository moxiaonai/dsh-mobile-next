# dsh-mobile-next — Next whale v2

本目录为本次继续请求的新交付。上级目录中旧稿保留、不替换；建议评审本目录版本。

## 推荐：A / Forward whale

- 原创闭合贝塞尔轮廓：上扬双叶尾、圆润鲸身、胸鳍、眼点与腹部负形。鲸头朝右，强化下一步、前进的阅读方向。
- 腹部弧线在右端转成向右箭头，next 来自鲸鱼内部结构，不是额外悬浮的播放按钮。
- Mobile 以适应系统裁切的方形 icon 构图体现，不给推荐标识叠加细小手机框。
- 主色 `#4D6BFE`（沿用现有设计稿的 DeepSeek 蓝；本次未独立核验官方品牌规范）。图标白鲸、蓝底，平面色，无渐变、阴影或文字。
- 推荐用于启动图标与品牌主标识；小尺寸优先保持鲸的剪影，不要求 16px 上完整读出箭头与眼点。常用显示建议 ≥32px，独立品牌标识建议 ≥48px。

## 备选：B / Pocket whale

同一鲸鱼收进竖向圆角设备框，底部胶囊体现手机 home indicator，mobile 表达更直接。代价是两层轮廓与更小的鲸身：更适合大尺寸宣传、产品入口；不推荐作为 16–24px 图标。

## 文件

- [推荐蓝色鲸鱼 SVG](a-forward-whale-blue.svg) / [黑色 SVG](a-forward-whale-black.svg) / [白色 SVG](a-forward-whale-white.svg)
- [推荐 1024px app icon PNG](a-app-icon-1024.png) / [可编辑图标 SVG](a-app-icon-1024.svg)
- [备选鲸鱼 SVG](b-pocket-whale-blue.svg) / [备选 1024px app icon PNG](b-app-icon-1024.png) / [图标 SVG](b-app-icon-1024.svg)
- [双方向视觉预览](visual-preview.png)
- [深浅背景、裁切与实际小尺寸校样](visual-quality-proof.png)
- [机器验证报告](validation.json)
- [渲染前应用目录 SHA-256 清单](project-hashes-before.json)
- [可复现构造脚本](../next-whale-v2-build.py)

生产图标 PNG 为 **1024×1024、全不透明、方形满铺蓝底**，不预先加平台圆角；预览图中的圆角和圆形只模拟系统裁切。SVG 无外链图片、无外链字体；鲸鱼为真实矢量路径和透明挖空。品牌白版需要放在非白背景上。B 的手机外框使用 stroke，导入矢量编辑器后如需轮廓交付，可执行 expand stroke。

## 验证与边界

- 使用本机 Chrome headless 渲染 SVG，Pillow 检查 PNG 尺寸、alpha 和哈希；SVG 使用 XML 解析器验证。
- 在浅底、深底、圆形及圆角方形裁切上校样；检查 16/24/32/48/64/128px 实际缩小效果。
- 应用目录没有 Git 元数据，不能宣称通过 git diff。脚本逐个对比 `dsh-mobile-next` 文件内容 SHA-256，生成前后相同；未改应用代码、现有图标、配置或依赖。没有执行项目 build，因为本次没有代码改动。
- **当前会话没有用户上传的黑色鲸鱼附件，项目/reference 中也未找到原图。** 本稿按用户描述及鲸鱼品牌的双叶尾、圆润身形、腹部负形语汇原创重绘，不是对上传图逐点描摹，也未做原图叠加相似度核验。若需精确贴合其上传版本，需重新提供原图后校准尾部和身体比例。
- 当前工具无 AI 图像生成端点；交付通过手工矢量几何与实际栅格化制作，不是仅提示词，也不是宣称调用生图服务。
- 未接入或替换平台图标，也未做 iOS/Android 真机安装验证；裁切为视觉模拟，不能替代平台适配。未主张 DeepSeek 官方认可、独占商标权或商业许可。

完整目录：`design/logo/next-whale-v2/`。
