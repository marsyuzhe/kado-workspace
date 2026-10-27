# KADO Desk 2.4.0

# KADO Desk 2.4.0+24

导航：网站导航固定在首页下方。科技工作空间与五个分类独立折叠、路由自动展开、选中项与查询视图一致，232px默认宽度/196–280px拖宽/72px紧凑侧栏。状态保存在现有设置表；移动端使用网站底栏入口和抽屉。

首页：最多8个96/108px快捷启动卡，按可用宽度1–4列，保留真实最近使用、收藏与项目/笔记，当前任务只显示实际记录。统一Comfortable/Compact控制Theme、列表、表格、卡片与侧栏间距。取消无区分价值的“本地可用”卡片状态。

模块：局域网互传、家庭设备、游戏存档、记账、收藏卡、安装包收藏默认从主工作空间隐藏，设置→模块管理可重新显示；旧记录、文件与路由保留。模块管理包含启用、版本、排序与独立favicon缓存清理。

第一批：API Studio、Data Formatter、Regex Lab、Hash Inspector、Snippet Library、Network Inspector、Log Viewer均有真实服务和操作页面。数据/文件/网络边界见V24_TOOLS_GUIDE。

第二批：GitHub公开仓库与Release记录、本地目录关联；四种项目依赖配置检查；环境/软件版本与变量名称比较；表单式文本转换→哈希→安全导出工作流。Docker复用现有SSH认证与指纹固定，扩展只读镜像、容器资源与200行日志，未添加变更容器操作。

工程：路由改为清晰switch分发，侧栏配置独立，关键网络、后台计算和数据安全代码有边界说明。继续Material3，不引入第二个UI体系。yaml3.1.4从传递依赖改直接使用，新增toml0.18.0，保留cupertino_icons2.0.0（构建发现SDK自适应控件隐式字体引用，撤回候选删除）；原有依赖未升级。Release分析与符号归档分开构建，保留原生运行库、中文PDF字体、Pixel Studio素材和所有用户数据。

兼容：Schema3、原六模块、Studio/Agent Runtime、包ID、Windows二进制和CompanyName/ProductName不变。不配置云服务，不上传用户数据。旧封存2.3/2.0/1.8保留。

## Public preparation

Bilingual README and real synthetic-data captures; original promotional layouts; owner-approved MIT public copy; complete third-party texts; portable build/test paths and Windows PDB basenames. A compound large-log test uses a separate aggregate budget while preserving worker limits and assertions. No feature, database schema or application ID migration is introduced by the publishing preparation. Original development files and sealed artifacts are preserved.
