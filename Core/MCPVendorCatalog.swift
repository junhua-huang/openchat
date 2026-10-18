import Foundation

/// Addresses and setup requirements checked against the linked vendor docs.
/// A catalog entry is not a claim that this client has vendor OAuth approval.
enum MCPVendorCatalog {
    static let checkedOn = "2026-10-18"
    static let registryAliases: [String: String] = [
        "微软": "microsoft", "微软文档": "microsoft", "微软云": "azure", "谷歌": "google", "谷歌云": "google",
        "亚马逊": "aws", "亚马逊云": "aws", "阿里": "aliyun", "阿里云": "aliyun", "百炼": "aliyun",
        "腾讯": "tencent", "腾讯云": "tencent", "百度": "baidu", "百度地图": "baidu", "高德": "amap", "高德地图": "amap",
        "飞格玛": "figma", "线性": "linear", "代码托管": "github", "笔记": "notion", "支付": "stripe"
    ]
    static let entries: [MCPListing] = MCPRegistryClient.recommendations + [
        MCPListing(id: "vendor-github", title: "GitHub", summary: "查询和管理仓库、Issue、Pull Request 与代码。",
            endpoint: "https://api.githubcopilot.com/mcp/", website: "https://github.com/github/github-mcp-server",
            authorization: "需要 GitHub 访问令牌", publisher: "GitHub / Microsoft", keywords: ["微软", "代码", "代码仓库", "代码托管", "copilot", "repository", "开发"]),
        MCPListing(id: "vendor-notion", title: "Notion", summary: "搜索工作空间，读取、创建和整理页面与数据库。",
            endpoint: "https://mcp.notion.com/mcp", website: "https://developers.notion.com/guides/mcp/get-started-with-mcp",
            authorization: "浏览器授权 · 需要工作空间权限", publisher: "Notion", keywords: ["笔记", "知识库", "文档", "数据库", "notes", "knowledge", "docs", "database"]),
        MCPListing(id: "vendor-linear", title: "Linear", summary: "查询与管理项目、任务、Issue 和开发进度。",
            endpoint: "https://mcp.linear.app/mcp", website: "https://linear.app/docs/mcp",
            authorization: "OAuth 登录或访问令牌", publisher: "Linear", keywords: ["任务", "项目", "工单", "线性", "issues", "project"]),
        MCPListing(id: "vendor-cloudflare", title: "Cloudflare", summary: "访问 Cloudflare 账户中的 Workers、DNS、R2 等云服务。",
            endpoint: "https://mcp.cloudflare.com/mcp", website: "https://developers.cloudflare.com/agents/model-context-protocol/cloudflare/servers-for-cloudflare/",
            authorization: "浏览器授权 · 按账户权限访问", publisher: "Cloudflare", keywords: ["云", "cdn", "workers", "dns", "r2", "部署", "数据库"]),
        MCPListing(id: "vendor-cloudflare-docs", title: "Cloudflare 文档", summary: "查找 Cloudflare 官方开发文档和产品用法。",
            endpoint: "https://docs.mcp.cloudflare.com/mcp", website: "https://developers.cloudflare.com/agents/model-context-protocol/cloudflare/servers-for-cloudflare/",
            authorization: "公开文档 · 连接时检查访问要求", publisher: "Cloudflare", keywords: ["文档", "开发文档", "docs", "cloud", "workers"]),
        MCPListing(id: "vendor-stripe", title: "Stripe", summary: "查询支付、客户、账单和商品，执行已授权的支付业务操作。",
            endpoint: "https://mcp.stripe.com", website: "https://docs.stripe.com/mcp",
            authorization: "OAuth 登录或 Agent API Key", publisher: "Stripe", keywords: ["支付", "账单", "收款", "payment", "billing"]),
        MCPListing(id: "vendor-vercel", title: "Vercel", summary: "查询项目、部署状态与日志，管理网站部署。",
            endpoint: "https://mcp.vercel.com", website: "https://vercel.com/docs/agent-resources/vercel-mcp",
            authorization: "浏览器授权 · 需要项目权限", publisher: "Vercel", keywords: ["部署", "网站", "日志", "nextjs", "next.js", "hosting", "deploy"]),
        MCPListing(id: "vendor-huggingface", title: "Hugging Face", summary: "搜索 AI 模型、数据集、论文与 Spaces 应用。",
            endpoint: "https://huggingface.co/mcp", website: "https://huggingface.co/docs/hub/agents-mcp",
            authorization: "部分能力需要 Hugging Face 账户授权", publisher: "Hugging Face", keywords: ["huggingface", "hf", "抱抱脸", "模型", "数据集", "论文", "ai", "models", "datasets", "搜索", "search"]),
        MCPListing(id: "vendor-figma", title: "Figma", summary: "读取设计稿、组件和设计上下文。",
            endpoint: "https://mcp.figma.com/mcp", website: "https://developers.figma.com/docs/figma-mcp-server/remote-server-installation/",
            authorization: "需要 Figma 登录及客户端准入", limitation: "Figma 只允许已获准的客户端连接，OpenChat 尚未获准；可先查看官方接入说明。",
            publisher: "Figma", keywords: ["飞格玛", "设计", "设计稿", "组件", "design", "ui"]),
        MCPListing(id: "vendor-aws", title: "AWS", summary: "亚马逊云官方 MCP 服务，连接云资源和 AWS 工具。",
            endpoint: nil, website: "https://docs.aws.amazon.com/agent-toolkit/latest/userguide/getting-started-aws-mcp-server.html",
            authorization: "AWS 账户与专门的授权配置", limitation: "需要按 AWS 文档完成客户端授权或配置签名代理；本 App 尚未提供 AWS 专用接入。",
            publisher: "Amazon Web Services", keywords: ["亚马逊", "亚马逊云", "amazon", "云", "cloud", "部署"]),
        MCPListing(id: "vendor-google-cloud", title: "Google Cloud", summary: "查找谷歌云官方的远程 MCP 服务及其连接方式。",
            endpoint: nil, website: "https://docs.cloud.google.com/mcp/overview",
            authorization: "Google Cloud IAM 与服务授权", limitation: "不同产品使用不同端点，需要先按官方文档启用服务和配置账户授权。",
            publisher: "Google", keywords: ["谷歌", "谷歌云", "gcp", "云", "数据库", "bigquery", "maps"]),
        MCPListing(id: "vendor-aliyun", title: "阿里云百炼", summary: "浏览百炼 MCP 广场中的联网搜索、文档、地图等服务。",
            endpoint: nil, website: "https://help.aliyun.com/zh/model-studio/official-and-third-party-mcp",
            authorization: "需开通服务并获取接入配置", limitation: "各服务有独立连接地址；获取配置后可填写本 App 支持的 HTTPS Streamable HTTP 地址。",
            publisher: "阿里云 Alibaba Cloud", keywords: ["阿里", "阿里云", "aliyun", "alibaba", "bailian", "百炼", "通义", "qwen", "搜索", "文档", "地图", "云"], requiresCustomEndpoint: true),
        MCPListing(id: "vendor-tencent", title: "腾讯云 MCP 广场", summary: "浏览腾讯产品与开发、内容、数据库等 MCP 服务。",
            endpoint: nil, website: "https://cloud.tencent.com/developer/mcp",
            authorization: "按具体服务开通和授权", limitation: "各服务接入方式不同；获取 HTTPS Streamable HTTP 地址后可手动连接，暂不支持仅提供 SSE 或本机运行的服务。",
            publisher: "腾讯云 Tencent Cloud", keywords: ["腾讯", "腾讯云", "tencent", "cloudbase", "云开发", "数据库", "内容", "开发", "云"], requiresCustomEndpoint: true),
        MCPListing(id: "vendor-amap", title: "高德地图", summary: "查看官方地图 MCP 的地点搜索、路线和出行能力。",
            endpoint: nil, website: "https://lbs.amap.com/api/mcp-server/summary",
            authorization: "需要高德开放平台 Key", limitation: "官方连接配置含 URL 密钥；当前版本暂不支持此类授权，可查看文档了解服务。",
            publisher: "高德 / 阿里巴巴", keywords: ["高德", "高德地图", "amap", "阿里", "阿里巴巴", "地图", "路线", "出行", "maps", "位置"]),
        MCPListing(id: "vendor-baidu-maps", title: "百度地图", summary: "查看官方地图 MCP 的地点、路线与行程规划能力。",
            endpoint: nil, website: "https://lbsyun.baidu.com/docs/ai?title=mcpserver%2Fquickstart",
            authorization: "需要百度地图开放平台 API Key", limitation: "官方连接配置含 URL 密钥；当前版本暂不支持此类授权，可查看文档了解服务。",
            publisher: "百度 Baidu", keywords: ["百度", "百度地图", "baidu", "地图", "路线", "出行", "maps", "位置"])
    ]
    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func matching(_ query: String) -> [MCPListing] {
        let term = normalize(query)
        guard !term.isEmpty else { return entries }
        guard term.count <= 200 else { return [] }
        let tokens = term.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return entries.filter { listing in
            let searchable = normalize(([listing.title, listing.summary, listing.publisher ?? "", listing.endpoint ?? ""] + listing.keywords).joined(separator: " "))
            return tokens.allSatisfy { searchable.contains($0) }
        }.sorted { a, b in
            func score(_ item: MCPListing) -> Int {
                if normalize(item.title) == term { return 0 }
                if item.keywords.contains(where: { normalize($0) == term }) { return 1 }
                if normalize(item.title).contains(term) { return 2 }
                return 3
            }
            return score(a) < score(b) || (score(a) == score(b) && a.title.localizedStandardCompare(b.title) == .orderedAscending)
        }
    }
}
