# 岗位持续采集服务

这版把持续更新放在电脑服务上。App 保存并展示岗位、匹配结果和来源状态；电脑服务负责定时搜索、读取允许的公开来源以及本机授权招聘会话。电脑关机、休眠或服务退出时，采集暂停；重启服务后会读回调度计划、查询游标、来源退避和岗位缓存，继续执行到期任务。iPhone 本身没有实现常驻后台招聘网站采集。

## 已实现的管线

默认每 3 天运行一轮，需要时可手动刷新。每轮查询将方向、杭州关注公司、其他城市分开分配；默认城市为杭州和上海，可在私有配置里增减。采用独立短方向词和公司名查询，避免把“公司＋机器人＋具身＋实习”全部叠加造成漏检；实习身份和技能相关性在读取岗位后筛选。关注公司只是搜索范围，并不代表已经确认有杭州实习岗位。

实习僧官方搜索每个查询重新看第一页发现新岗位，并按持久化 backlog 游标扫描后续页；每轮最多 2 页，下一轮从上次未扫描的后续页继续，最多第 100 页。BOSS 使用用户本机会话与普通网页分页，保存已观察到的实际页码；如果网页没有接受深页跳转，会尝试有预算的普通“下一页”，仍无法确认页码则保留游标并标识受限，不假装翻页成功。

搜索发现的允许域名详情链接进入持久详情队列，每轮最多补全 2 个支持的详情。实习僧公开详情、智联结构化详情及支持 JobPosting 结构化数据的已注册来源可以补全；不支持的页面、登录限制或安全验证明确记为无法读取，继续保留搜索线索。详情补全不得由模型编造正文。已核查详情通常每 7 天重新核查。

岗位优先按来源原始岗位 ID 和规范来源 URL 去重。不同公司团队、不同来源职位地址、不同硬条件不会仅因为标题相同就合并；跨平台聚合要求完整职责、要求、地点和硬条件高度一致，并保留成员来源，防止第三条岗位通过中间来源被误吞。列表更新不覆盖完整 JD 的毕业届次、每周天数、实习月数和原详情核查时间。部分分页扫描缺席不是关闭证据；已过明确截止时间的记录关闭，超过 7 天没核查的 verified 缓存降为待核实。旧发布日期不会否定今天实际核查开放的长期岗位。

## 来源能力和限制

| 来源 | 当前接入 | 需要什么 | 此版验证情况 |
| --- | --- | --- | --- |
| 宇树 | 官方公开招聘列表 HTML | 不需要第三方 Key | 真实公开页面只读验证；类型和实习要求未写明时保持未知 |
| 浙大 | 官方招聘活动中公司岗位页 | 不需要第三方 Key | 真实页面只读验证；保留发布日、截止日与历史来源限制 |
| 实习僧官方 API | `/intern/search`、`/intern/info` | 商务提供 APP_ID/APP_SECRET、IP 白名单 | 签名和结构通过模拟测试；未有商户账号真实联调 |
| 实习僧公开详情 | 配置的公开详情及发现队列 | 页面能公开读取 | 真实详情验证；明确下线的 Palatial 岗已识别为关闭 |
| BOSS | 本机用户授权浏览器采集器 | 首次本机登录、可选官方 Playwright | 2026-10-09 在标准 Chrome 自动化窗口现场测试：首页、登录页 HTTP 200 后退回空白页，当前未接通；代码检查受限状态并保留缓存 |
| 多源公开搜索 | Tavily 搜索和受限详情队列 | 服务端 Tavily Key | 结构、鉴权与队列测试；未使用真实收费 Key 联调 |
| 智联 | 配置公开详情链接/发现队列 | 页面有支持的可读结构 | 格式测试；全站自动搜索未接入 |
| 牛客 | 缓存与发现队列的结构化详情 | 支持的公开页面 | 独立全站采集器未接入 |

实习僧存在正式开放 API，但并不是个人在手机登录后便可自动取得的权限。其[官方文档](https://open.shixiseng.com/)要求商务接入和 IP 白名单。BOSS 本机采集参考来源适配、用户会话和持久化结构；它不伪装成官方开放 API。无需安装或运行第三方招聘项目代码。

## 在 Windows 启动

需要 Node.js 20 或更新版本，服务本体仅使用 Node 内建库。可双击 `scripts/start-career.cmd` 保持服务窗口运行，也可以在项目目录执行：

```powershell
node scripts/career-server.cjs --lan
```

默认端口 `4176`。不加 `--lan` 只监听 `127.0.0.1`；加上后 iPhone 和电脑同一局域网可通过电脑内网地址连接。App 的服务地址填 `http://你的电脑内网IP:4176`，服务连接凭据从 `data/career-private/token.txt` 复制到 App。它是独立随机访问令牌，和大模型 API Key、短信配对码不是同一个东西。请勿把令牌或私有目录上传到 GitHub。

本机桌面已有 `启动岗位采集服务.cmd`：电脑重启或服务停止后双击一次，启动后保持服务窗口运行；重复双击会检查现有服务而不会启动第二份。脚本调用 `scripts/show-career-address.ps1` 显示当前地址。切换 Wi-Fi／热点后电脑 IP 可能变化，需要按脚本显示的地址更新 App；令牌通常保持不变。按用户选择未配置 Windows 登录后自动启动。

`--no-schedule` 可临时只提供接口，`--refresh-on-start` 可手动提前刷新，`--port` 可指定其他端口，`--data-dir` 可指定私有缓存目录。没有缓存时，服务会从 `ios/Daylight/CareerSeed.json` 读取人工核查资料；这不会被标记成某招聘来源已经自动采集成功。

运行后生成：

- `token.txt`：App 连接随机凭据；`config.json`：持续采集配置。
- `feed.json`：持久岗位与每个来源的成功/错误状态。
- `scheduler.json`：下一次采集时间、失败退避、来源与查询轮换、分页 checkpoint 和每日预算。
- `detail-queue.json`：搜索发现后待核查或无法读取的详情。
- `browser-boss/`、`boss-detail-cache.json`：用户选择启用 BOSS 后的本机会话和详情缓存。

私有目录自带 `.gitignore`，发布包仅允许明确的源码文件，不包含该目录。财务、银行短信和模型密钥不经过此服务。

## 配置持续搜索

首次启动后编辑 `data/career-private/config.json`。服务每轮重新读取配置，无需把 Key 发到聊天：

```json
{
  "schemaVersion": 1,
  "schedulingEnabled": true,
  "intervalHours": 72,
  "dailyRequestBudget": 80,
  "maxRequestsPerRefresh": 24,
  "maxQueriesPerSource": 3,
  "pagesPerQuery": 2,
  "maxDetailsPerSource": 8,
  "cities": ["杭州", "上海"],
  "keywords": ["具身智能", "模仿学习", "机器人仿真", "机械臂", "机器人软件", "运动控制", "MuJoCo", "操作学习"],
  "companies": ["群核科技", "西湖机器人", "千寻智能", "有鹿机器人", "原力灵机", "灵西机器人", "宇树科技", "云深处"],
  "browserCollectorEnabled": false,
  "sources": {}
}
```

`intervalHours` 默认 72（每 3 天），可设为 48（每 2 天）。默认配置的关注公司比示例更多，可自行更改。`sources` 中将来源 ID 设为 `false` 可暂停这个来源，例如 `{"tavily":false}`。一次查询分配是滚动覆盖，**不意味着每家公司和每个平台每天全部扫描**；有限预算下会跨周期补齐计划。每来源有单轮请求上限，全轮 24 次、每天 80 次按中国时区累计，重启不会清零。浏览器预算计有限页面/翻页/详情动作的保守额度，不计网页静态资源；不能把它解读成整台电脑所有 HTTP 请求的流量额度。

缺少 Key/会话的来源会暂停并报告状态，不按零个岗位处理。失败采用来源退避，自动重试不会早于设定的采集周期；默认每 3 天重试。手动刷新可以重新检查配置，但每次需间隔至少 1 分钟；已有结果在失败时保留。

## BOSS 一次授权，后续周期采集

这部分需要额外安装官方 Playwright，用独立私有浏览器会话。它没有隐身反检测参数，不绕过验证码，也不会投递、打招呼或读取简历。2026-10-09 已在本机启动标准 Chrome 现场检查：首页和官方登录页都在 HTTP 200 后退回空白页，普通 Chrome 可以访问。当前浏览器路线未接通，不应仅凭代码测试或会话目录存在启用定期采集。出现空白／离站页面时立即停止并显示受限状态，不提示授权成功。

用户可以自行在项目目录安装：

```powershell
npm install --no-save --package-lock=false playwright
npx playwright install chromium
node scripts/career-browser-collector.mjs --source boss --login
```

如果此电脑已安装 Google Chrome，也可显式选择它。先安装上面第一行的 Playwright；下面两行要在同一个 PowerShell 窗口中执行，之后从这个窗口启动岗位服务，定时采集会沿用该设置：

```powershell
$env:CAREER_BROWSER_CHANNEL = 'chrome'
node scripts/career-browser-collector.mjs --source boss --login
```

若 Chrome 的安装路径需要手动指定，可用 `CAREER_BROWSER_EXECUTABLE_PATH` 指向 `chrome.exe`，与 `CAREER_BROWSER_CHANNEL` 二选一。单次手动运行也支持 `--browser-channel chrome` 或 `--browser-executable "C:\Program Files\Google\Chrome\Application\chrome.exe"`；定时采集请使用环境变量，并在启动岗位服务前设置。没有设置时仍使用 Playwright 自带的 Chromium，并需要执行上面的 `npx playwright install chromium`。

出现浏览器后由本人扫码登录，再回到终端按回车。手机已登录不等于此电脑会话已登录。之后将私有 `config.json` 的 `browserCollectorEnabled` 改成 `true`，保持岗位服务运行；定期任务会自动调用本机 collector，读取已授权会话，不需要每轮重新登录或手工导入。会话过期时再运行 `--login`。可自行用 `--collect` 提前触发一轮。遇验证码会停并保留已成功读取的列表 checkpoint，提示 `blocked`；用户在自己浏览器处理后再试。

目前本机浏览器路径只实现 BOSS；实习僧用正式 API/公开详情，不声称另一个已登录采集器存在。默认浏览器城市映射仅验证代码支持杭州、北京、上海；其他城市报未验证，不混成杭州数据。

2026-10-09 Edge 现场结果：用户通过 `scripts/boss-login-edge.cmd` 在普通 Edge 的独立 `browser-boss-edge` 目录扫码登录，并通过 `search` 参数打开杭州搜索、完成官网验证，确认能看到岗位列表。关闭普通窗口后，使用同一目录的 Playwright 后台和可见窗口采集都再次被跳转到 `/web/passport/zp/verify.html`。因此尚未取得实际岗位采集结果；私有配置保持 `browserCollectorEnabled: false`、`sources.boss: false`，来源状态为受限。`browserChannel: "msedge"` 已支持，但普通网页登录成功不代表自动读取成功。页面初次加载后、等待岗位卡片后均检查验证跳转，避免误报无岗位或成功。

## 服务端接口 Key

服务端环境变量：

- `SHIXISENG_APP_ID`、`SHIXISENG_APP_SECRET`：实习僧商户凭据；还需要平台配置出口 IP 白名单。
- `TAVILY_API_KEY`：公开搜索服务凭据；没有配置时显示 `not_configured`。
- `SHIXISENG_PUBLIC_URLS`、`ZHAOPIN_PUBLIC_URLS`：最多 5 条对应公开详情地址的 JSON 数组。
- `CAREER_SERVICE_TOKEN`：可自设至少 24 字符的随机 App 连接令牌；不设置则服务自动生成并持久化。

这些配置留在电脑。模型分析仍在 App 现有配置中按需执行，采集和规则处理不消耗 DeepSeek token；设置模型 Key 不能替代招聘平台授权或搜索 Key。

Windows 搜索 Key 一次配置：在私有 `data/career-private/search.env` 填写 `TAVILY_API_KEY=你的Key`，不要将 Key 放在聊天或 GitHub。`scripts/start-career.cmd` 启动时通过 Node 的 `--env-file` 读取该文件，仅传给服务进程。配置后需要重启已运行的服务；之后沿用桌面启动脚本即可。该文件在电脑本地以文本保存，不随 IPA 打包或上传，环境文件存在但 Key 为空时仍显示未配置。搜索请求使用 Bearer 鉴权，固定 `basic`、关闭自动参数与答案生成；摘要保持线索等级，不推测公司、资格或在招状态。

本机 2026-10-09 对照：Node 经现有代理多次出现连接重置或超时，Windows 网络栈连续查询成功。因此私有环境启用 `CAREER_TAVILY_TRANSPORT=windows`，`CAREER_POWERSHELL` 使用本机已验证的 PowerShell 路径，`HTTPS_PROXY` 沿用本机现有代理。此模式只对 `https://api.tavily.com/search` 生效；Key 通过子进程标准输入传递，日志和命令行不包含凭据。Node 的取消信号会终止该子进程，响应受大小上限限制。代理客户端关闭时搜索可能失败，旧缓存保留。多查询中途失败也保留前面的成功线索，轮转游标不跳过未完成批次；招聘汇总／搜索页不作为具体岗位推荐。已关闭的来源不会因搜索发现链接而重新进行自动详情抓取。

## API Contract v1

`GET /health` 公开，只返回服务和 schema 版本，不含岗位和令牌。下列接口均需 `Authorization: Bearer <连接凭据>`：

- `GET /v1/career/feed`：当前缓存、来源状态、周期运行进度。
- `POST /v1/career/refresh`：立即返回 `202` 和当前 feed，服务异步采集；调用方通过 GET 读取进度。运行中或冷却内重复刷新返回 `429`。
- `POST /v1/career/import`：受限本机 collector 输入，1–100 条规范岗位及已注册来源 ID；网址仅允许对应 HTTPS 源站，不接受“请服务器任意抓取这个 URL”。
- `POST /v1/career/collector-status`：受限 collector 上报登录、验证或失败，不清空已有岗位。

Feed 包括 `schemaVersion:1, generatedAt, jobs, sources, articles:[]`，以及可选 `scheduler`。岗位包括原发布时间、刷新时间、详情核查时间、截止时间、证据等级、原岗位身份及内容哈希。来源状态是 `ok / login_required / blocked / not_configured / error`，`coverage` 区分固定来源页面与关键词搜索，记录真正执行的查询、页面、详情和请求；未执行的词只写入 plannedKeywords，不能显示为已扫描。`scheduler` 报告运行中状态、下一次时间、失败恢复和当日预算；详情队列报告待补全和无法读取数量。

本机原型通过严格回环代理访问此服务，令牌不发送到浏览器页面。iPhone 直接连接时令牌保存在客户端安全存储；首次授权与周期成功状态在 App 中可见。

## 验证范围

```powershell
node --test tests/career-service.test.cjs tests/career-scheduler.test.cjs tests/career-detail-queue.test.cjs
node scripts/career-live-check.cjs --save
```

接口/采集算法已覆盖鉴权、受限域名、跳转/大小/请求预算、时区、期限、跨源和同源岗位身份、证据优先级、异步刷新、来源失败保留、分页 checkpoint、每日预算跨日、持久退避、公平查询及详情队列。公开页面真实验证只读宇树、浙大和实习僧详情；商户实习僧 API、Tavily 付费 API、BOSS 本人登录后的整条采集链路均尚未真实账号联调，不能据此保证全网全部职位可取得。
