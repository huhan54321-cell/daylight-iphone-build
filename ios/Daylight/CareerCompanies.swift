import Foundation

struct CareerCompany: Identifiable {
    let id, name, category, location, status, intro, fit, url: String
}

enum CareerDirectory {
    // Public source snapshot; company presence does not imply an open internship.
    static let companies: [CareerCompany] = [
        CareerCompany(id: "spirit", name: "千寻智能", category: "仿真与操作", location: "杭州（官方招聘站列出）", status: "杭州招聘入口已核查 · 实习 JD 待筛选", intro: "研发通用具身模型与机器人，官方招聘页涵盖模型、遥操作及机器人开发。", fit: "按具体岗位 JD 核对技术方向、实习身份、工作地点和招聘状态。", url: "https://nwd4iy9rd2s.jobs.feishu.cn/"),
        CareerCompany(id: "udeer", name: "有鹿机器人", category: "仿真与操作", location: "杭州余杭", status: "高校公开来源 · 历史实习条目需核查", intro: "聚焦大模型与具身智能，面向专业设备开发通用智能能力。", fit: "按具体岗位 JD 核对技术方向、实习身份、工作地点和招聘状态。", url: "https://www.career.zju.edu.cn/jyxt/sczp/zpztgl/ckZpgwList.zf?dwxxid=JG1501358"),
        CareerCompany(id: "infiforce", name: "原力无限", category: "仿真与操作", location: "杭州余杭", status: "官网业务与杭州地址已核查", intro: "围绕具身大脑、世界模型与数据闭环，开发多形态机器人及应用。", fit: "按具体岗位 JD 核对技术方向、实习身份、工作地点和招聘状态。", url: "https://infiforce.cn/aboutus"),
        CareerCompany(id: "qunhe", name: "群核科技", category: "仿真与操作", location: "杭州拱墅", status: "杭州来源已核查", intro: "招聘资料涉及空间智能、仿真平台、算法与评测。", fit: "按具体岗位 JD 核对技术方向、实习身份、工作地点和招聘状态。", url: "https://www.career.zju.edu.cn/jyxt/sczp/zphgl/ckZphdwXq.zf?dwxxid=761C0E152EE024AFE055000000000001&zphbh=4A1E5434BDBC2BCEE0653A68DD0E9B18&zphsqbh=c580d07223d2c9238242b3455027755f"),
        CareerCompany(id: "westlake", name: "西湖机器人", category: "本体与控制", location: "杭州", status: "杭州来源已核查", intro: "布局具身模型与机器人，官网列有杭州算法和机器人 SDK 职位。", fit: "按具体岗位 JD 核对技术方向、实习身份、工作地点和招聘状态。", url: "https://wlrobo.com/module5"),
        CareerCompany(id: "linx", name: "灵西机器人", category: "仿真与操作", location: "杭州", status: "杭州来源已核查", intro: "自研 3D 视觉、机器人控制与智能抓取方案。", fit: "按具体岗位 JD 核对技术方向、实习身份、工作地点和招聘状态。", url: "https://www.linx-robot.com/about"),
        CareerCompany(id: "awomo", name: "西湖数智 Awomo", category: "仿真与操作", location: "杭州西湖", status: "杭州来源已核查", intro: "聚焦 Physical AI，涉及世界模型、仿真数据和机器人部署。", fit: "按具体岗位 JD 核对技术方向、实习身份、工作地点和招聘状态。", url: "https://www.westlakedi.com/"),
        CareerCompany(id: "unitree", name: "宇树科技", category: "本体与控制", location: "杭州", status: "杭州来源已核查", intro: "产品涵盖四足、人形机器人、机械臂与灵巧手。", fit: "按具体岗位 JD 核对技术方向、实习身份、工作地点和招聘状态。", url: "https://www.unitree.com/cn/position/"),
        CareerCompany(id: "deep", name: "云深处科技", category: "本体与控制", location: "杭州西湖", status: "杭州来源已核查", intro: "研发四足、人形机器人及核心部件，覆盖感知、控制与行业应用。", fit: "按具体岗位 JD 核对技术方向、实习身份、工作地点和招聘状态。", url: "https://www.deeprobotics.cn/robot/index/company.html"),
        CareerCompany(id: "58", name: "五八智能", category: "本体与控制", location: "杭州西湖", status: "杭州来源已核查", intro: "布局四足、人形机器人和机器人智能，并建设中试验证平台。", fit: "按具体岗位 JD 核对技术方向、实习身份、工作地点和招聘状态。", url: "https://58znkj.com/about"),
        CareerCompany(id: "launchy", name: "峦启机器人", category: "灵巧手", location: "杭州余杭", status: "杭州来源已核查", intro: "开发机器人灵巧手与智能仿生手，面向末端执行器。", fit: "按具体岗位 JD 核对技术方向、实习身份、工作地点和招聘状态。", url: "https://www.launchybot.com/"),
        CareerCompany(id: "torch", name: "炬坤机器人", category: "灵巧手", location: "杭州余杭", status: "杭州来源已核查", intro: "提供工业级灵巧手、末端执行器与相关感知部件。", fit: "按具体岗位 JD 核对技术方向、实习身份、工作地点和招聘状态。", url: "https://www.torchkernel.com/"),
        CareerCompany(id: "huaxi", name: "骅羲科技", category: "服务机器人", location: "杭州余杭", status: "杭州来源已核查", intro: "面向养老与居家服务研发具身机器人。", fit: "按具体岗位 JD 核对技术方向、实习身份、工作地点和招聘状态。", url: "https://www.huaxiai.com.cn/"),
        CareerCompany(id: "hik", name: "海康机器人", category: "相邻方向", location: "杭州", status: "杭州来源已核查", intro: "官方招聘列有杭州机器人软件与电机控制等岗位。", fit: "按具体岗位 JD 核对技术方向、实习身份、工作地点和招聘状态。", url: "https://job.hikrobotics.com/"),
        CareerCompany(id: "diffrobot", name: "微分智飞", category: "相邻方向", location: "杭州余杭", status: "官网地址已核查 · 飞行机器人方向", intro: "提供自主飞行机器人平台、仿真验证及科研教育工具。", fit: "按具体岗位 JD 核对技术方向、实习身份、工作地点和招聘状态。", url: "https://www.diffrobot.com/space.html"),
        CareerCompany(id: "huaray", name: "华睿科技", category: "相邻方向", location: "杭州（高校校招来源）", status: "杭州招聘来源已核查 · 当前实习待核对", intro: "机器视觉与移动机器人业务，招聘方向涉及感知、运动控制及嵌入式软件。", fit: "按具体岗位 JD 核对技术方向、实习身份、工作地点和招聘状态。", url: "https://cug.91wllm.cn/attachment/www/ueditor/file/20250826/6209_%E3%80%902026%E5%B1%8A%E3%80%91%E6%B5%99%E6%B1%9F%E5%8D%8E%E7%9D%BF%E7%A7%91%E6%8A%80%E6%A0%A1%E5%9B%AD%E6%8B%9B%E8%81%98%E7%AE%80%E7%AB%A0.pdf"),
        CareerCompany(id: "uniubi", name: "宇泛智能", category: "待核查", location: "杭州岗位待核查", status: "岗位地点需核查", intro: "官网展示通用机器人大脑、四足机器人与机器人关节。", fit: "按具体岗位 JD 核对技术方向、实习身份、工作地点和招聘状态。", url: "https://www.uniubi.com/"),
        CareerCompany(id: "mirror", name: "镜识科技", category: "待核查", location: "官网主体北京", status: "杭州团队需核查", intro: "官网展示四足与人形机器人；不能仅凭浙大团队背景判断岗位在杭州。", fit: "按具体岗位 JD 核对技术方向、实习身份、工作地点和招聘状态。", url: "https://www.mirrormetech.com/cn/"),
        CareerCompany(id: "alibaba", name: "阿里巴巴具身团队", category: "待核查", location: "团队与岗位待核查", status: "杭州团队需核查", intro: "作为大厂研究团队关注项，具体组织、方向和工作地按 JD 核查。", fit: "按具体岗位 JD 核对技术方向、实习身份、工作地点和招聘状态。", url: "https://www.alibabagroup.com/"),
        CareerCompany(id: "ant", name: "蚂蚁具身／灵波团队", category: "待核查", location: "杭州岗位待核查", status: "杭州团队需核查", intro: "按具体团队与地点核查；不把集团杭州背景等同于机器人岗位在杭州。", fit: "按具体岗位 JD 核对技术方向、实习身份、工作地点和招聘状态。", url: "https://www.antgroup.com/"),
        CareerCompany(id: "netease", name: "网易雷火具身团队", category: "待核查", location: "官方岗位待核查", status: "官方招聘需核查", intro: "已有第三方具身实习岗位线索；官方招聘状态未确认。", fit: "按具体岗位 JD 核对技术方向、实习身份、工作地点和招聘状态。", url: "https://hr.163.com/"),
        CareerCompany(id: "simplexity", name: "至简动力", category: "待核查", location: "杭州公司 · 岗位城市需核查", status: "产业名录线索 · 杭州实习未确认", intro: "杭州产业名录收录的具身方向公司；不能由注册地推断算法团队工作地点。", fit: "按具体岗位 JD 核对技术方向、实习身份、工作地点和招聘状态。", url: "https://ecohub.welian.com/lists/4?industry=%E4%BA%BA%E5%B7%A5%E6%99%BA%E8%83%BD%E4%B8%8E%E5%85%B7%E8%BA%AB%E6%99%BA%E8%83%BD&year=2026"),
        CareerCompany(id: "fifth", name: "中科第五纪", category: "待核查", location: "杭州名录线索", status: "产业名录线索 · 官网与具体团队待核查", intro: "杭州人工智能与具身智能产业名录收录；尚未取得足够的一手岗位与技术说明。", fit: "按具体岗位 JD 核对技术方向、实习身份、工作地点和招聘状态。", url: "https://ecohub.welian.com/lists/4?industry=%E4%BA%BA%E5%B7%A5%E6%99%BA%E8%83%BD%E4%B8%8E%E5%85%B7%E8%BA%AB%E6%99%BA%E8%83%BD&year=2026"),
        CareerCompany(id: "iplus", name: "迦智科技", category: "待核查", location: "历史杭州来源 · 当前团队需核查", status: "移动操作机器人 · 杭州实习待确认", intro: "移动机器人与移动操作产品；高校历史资料有杭州地址，官网当前联系地址为台州。", fit: "按具体岗位 JD 核对技术方向、实习身份、工作地点和招聘状态。", url: "https://www.iplusmobot.cn/about.html")
    ]
}
