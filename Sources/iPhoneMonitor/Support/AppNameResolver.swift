import Foundation

enum AppNameResolver {
    private static let knownNames: [String: String] = [
        "com.tencent.xin": "微信",
        "tv.danmaku.bilianime": "哔哩哔哩",
        "com.ss.iphone.ugc.Aweme": "抖音",
        "com.openai.chat": "ChatGPT",
        "com.xingin.discover": "小红书",
        "com.alipay.iphoneclient": "支付宝",
        "com.xunmeng.pinduoduo": "拼多多",
        "com.apple.mobileslideshow": "照片",
        "com.apple.camera": "相机",
        "com.apple.WebKit.WebContent": "网页内容",
        "com.duolingo.DuolingoMobile": "多邻国",
        "suggestd": "系统建议与搜索",
        "mediaanalysisd": "媒体分析",
        "photoanalysisd": "照片分析",
        "duetexpertd": "系统智能调度",
        "knowledgeconstructiond": "知识索引",
        "spotlightknowledged.updater": "Spotlight 更新",
        "fileproviderd": "文件同步",
        "WeChat": "微信",
        "Aweme": "抖音",
        "SpringBoard": "SpringBoard（系统界面）",
        "backboardd": "backboardd（触控与界面事件）",
        "runningboardd": "runningboardd（应用运行管理）"
    ]

    static func displayName(for identifier: String) -> String {
        knownNames[identifier] ?? identifier
    }
}
