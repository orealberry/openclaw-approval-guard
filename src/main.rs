use anyhow::{anyhow, Context, Result};
use clap::{Parser, Subcommand};
use fs2::FileExt;
use regex::Regex;
use reqwest::blocking::Client;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::path::PathBuf;
use std::process::Command;
use std::thread::sleep;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

#[derive(Parser)]
#[command(name = "approval-guard")]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    Install,
    Run { command: String },
    Doctor,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
struct Config {
    bot_token: String,
    approver_chat_id: String,
    timeout_sec: u64,
    soft_guard_timeout_sec: u64,
    openclaw_key_targets: Vec<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Risk {
    Low,
    Medium,
    High,
    Critical,
}

impl Risk {
    fn as_str(self) -> &'static str {
        match self {
            Risk::Low => "low",
            Risk::Medium => "medium",
            Risk::High => "high",
            Risk::Critical => "critical",
        }
    }
}

fn home_dir() -> Result<PathBuf> {
    dirs::home_dir().ok_or_else(|| anyhow!("cannot detect home dir"))
}

fn runtime_dir() -> Result<PathBuf> {
    Ok(home_dir()?.join(".openclaw").join("approval-guard"))
}

fn config_path() -> Result<PathBuf> {
    if let Ok(v) = std::env::var("APPROVAL_CONFIG") {
        return Ok(PathBuf::from(v));
    }
    Ok(runtime_dir()?.join("config.json"))
}

fn load_config() -> Result<Config> {
    let p = config_path()?;
    let raw = fs::read_to_string(&p).with_context(|| format!("read config: {}", p.display()))?;
    let mut cfg: Config = serde_json::from_str(&raw)?;
    if let Ok(v) = std::env::var("APPROVAL_BOT_TOKEN") {
        if !v.trim().is_empty() {
            cfg.bot_token = v;
        }
    }
    if let Ok(v) = std::env::var("APPROVAL_CHAT_ID") {
        if !v.trim().is_empty() {
            cfg.approver_chat_id = v;
        }
    }
    if cfg.bot_token.trim().is_empty() || cfg.approver_chat_id.trim().is_empty() {
        return Err(anyhow!("bot_token/approver_chat_id missing"));
    }
    Ok(cfg)
}

fn now_ts() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs()
}

fn req_id(prefix: &str) -> String {
    format!("{}-{}-{}", prefix, now_ts(), std::process::id())
}

fn tg_api(client: &Client, token: &str, method: &str, form: &[(&str, String)]) -> Result<Value> {
    let url = format!("https://api.telegram.org/bot{}/{}", token, method);
    let res = client.post(url).form(form).send()?.error_for_status()?;
    Ok(res.json()?)
}

fn explain_command(cmd: &str, soft: bool) -> &'static str {
    if cmd.contains("rm -rf") { return "解读：rm -rf 是递归强制删除指令，误用会造成不可逆数据丢失。"; }
    if cmd.contains("dd if=") { return "解读：dd 可直接读写块设备，目标写错会破坏磁盘数据。"; }
    if cmd.contains("mkfs.") { return "解读：mkfs 会格式化文件系统，目标分区数据会被清空。"; }
    if cmd.contains("curl") && cmd.contains('|') { return "解读：下载后直接执行脚本存在供应链与远程代码执行风险。"; }
    if cmd.contains("wget") && cmd.contains('|') { return "解读：下载后直接执行脚本存在供应链与远程代码执行风险。"; }
    if cmd.contains("chmod 777") { return "解读：chmod 777 权限过宽，存在明显安全风险。"; }
    if cmd.contains("sudo ") { return "解读：sudo 以特权执行，影响范围和破坏面更大。"; }
    if cmd.contains("iptables") || cmd.contains("ufw") || cmd.contains("firewall-cmd") { return "解读：防火墙变更可能导致连接中断或服务暴露。"; }
    if soft && cmd.contains("openclaw.json") { return "解读：openclaw.json 是主配置，改坏会导致网关/插件异常。"; }
    if soft && cmd.contains("cron/jobs.json") { return "解读：cron 配置变更可能导致任务漏跑或误触发。"; }
    "解读：该命令可能影响系统状态，请确认目标与参数无误。"
}

fn assess_risk(cmd: &str) -> (Risk, &'static str) {
    let re_rm = Regex::new(r"rm\s+-rf\s+[~/]").unwrap();
    let re_rm_var_or_dot = Regex::new(r"rm\s+-rf\s+(\$|\.|\./)").unwrap();
    let re_dd = Regex::new(r"dd\s+if=").unwrap();
    let re_mkfs = Regex::new(r"mkfs\.").unwrap();
    let re_dev = Regex::new(r">\s*/dev/sd[a-z]").unwrap();
    let re_777 = Regex::new(r"chmod\s+777").unwrap();
    let re_sysdir = Regex::new(r">\s*/(etc|boot|sys|root)/").unwrap();
    let re_pipe = Regex::new(r"(curl|wget).*\|\s*(bash|sh|python)").unwrap();
    let re_sudo = Regex::new(r"sudo\s+").unwrap();
    let re_fw = Regex::new(r"iptables|firewall-cmd|ufw").unwrap();
    let re_chain = Regex::new(r"(;|&&|\|\|)").unwrap();

    if cmd.contains(":(){:|:&};:") { return (Risk::Critical, "Fork炸弹"); }
    if re_rm.is_match(cmd) { return (Risk::Critical, "删除根目录或家目录文件"); }
    if re_rm_var_or_dot.is_match(cmd) { return (Risk::Critical, "rm -rf + 变量/相对路径，存在绕过与误删风险"); }
    if re_dd.is_match(cmd) { return (Risk::Critical, "磁盘破坏命令"); }
    if re_mkfs.is_match(cmd) { return (Risk::Critical, "格式化文件系统"); }
    if re_dev.is_match(cmd) { return (Risk::Critical, "直接写入磁盘"); }

    // Heuristic: command chaining with destructive verbs is high risk.
    if re_chain.is_match(cmd)
        && (cmd.contains("rm ") || cmd.contains("dd ") || cmd.contains("mkfs") || cmd.contains("chmod ") || cmd.contains("chown ")) {
        return (Risk::High, "多段命令链包含破坏性动作");
    }

    if re_777.is_match(cmd) { return (Risk::High, "设置文件为全局可写"); }
    if re_sysdir.is_match(cmd) { return (Risk::High, "写入系统目录"); }
    if re_pipe.is_match(cmd) { return (Risk::High, "管道下载到shell"); }
    if re_sudo.is_match(cmd) { return (Risk::Medium, "使用特权执行"); }
    if re_fw.is_match(cmd) { return (Risk::Medium, "修改防火墙规则"); }
    (Risk::Low, "")
}

fn is_soft_target(cmd: &str, cfg: &Config) -> bool {
    for t in &cfg.openclaw_key_targets {
        let c = cmd;
        if c.contains(&format!("sed -i")) && c.contains(t) { return true; }
        if c.contains(&format!("> {}", t)) || c.contains(&format!(">>{}", t)) || c.contains(&format!(">> {}", t)) { return true; }
        if c.contains(" tee ") && c.contains(t) { return true; }
        if (c.contains("cp ") || c.contains("mv ")) && c.ends_with(t) { return true; }
    }
    false
}

fn run_shell(command: &str) -> Result<i32> {
    let status = Command::new("bash").arg("-o").arg("errexit").arg("-o").arg("pipefail").arg("-c").arg(command).status()?;
    Ok(status.code().unwrap_or(1))
}

fn updates_lock_path() -> Result<PathBuf> {
    Ok(runtime_dir()?.join("updates.lock"))
}

fn poll_for_callback(client: &Client, token: &str, matcher_prefix: &str, timeout_sec: u64) -> Result<Option<(String, String)>> {
    fs::create_dir_all(runtime_dir()?)?;
    let lock_p = updates_lock_path()?;
    let f = File::create(lock_p)?;
    f.lock_exclusive()?;

    let baseline = tg_api(client, token, "getUpdates", &[("timeout", "0".to_string())])?;
    let mut offset = baseline["result"].as_array().and_then(|a| a.last()).and_then(|x| x["update_id"].as_i64()).unwrap_or(0) + 1;
    let deadline = now_ts() + timeout_sec;

    while now_ts() < deadline {
        let v = tg_api(client, token, "getUpdates", &[("offset", offset.to_string()), ("timeout", "10".to_string())])?;
        if let Some(arr) = v["result"].as_array() {
            if let Some(last) = arr.last().and_then(|x| x["update_id"].as_i64()) {
                offset = last + 1;
            }
            for item in arr {
                let data = item["callback_query"]["data"].as_str().unwrap_or("");
                if data.starts_with(matcher_prefix) {
                    let cbid = item["callback_query"]["id"].as_str().unwrap_or("").to_string();
                    f.unlock()?;
                    return Ok(Some((data.to_string(), cbid)));
                }
            }
        }
        sleep(Duration::from_millis(800));
    }
    f.unlock()?;
    Ok(None)
}

fn pin_msg(client: &Client, cfg: &Config, msg_id: i64) {
    let _ = tg_api(client, &cfg.bot_token, "pinChatMessage", &[("chat_id", cfg.approver_chat_id.clone()), ("message_id", msg_id.to_string()), ("disable_notification", "true".to_string())]);
}

fn unpin_msg(client: &Client, cfg: &Config, msg_id: i64) {
    let _ = tg_api(client, &cfg.bot_token, "unpinChatMessage", &[("chat_id", cfg.approver_chat_id.clone()), ("message_id", msg_id.to_string())]);
}

fn edit_msg(client: &Client, cfg: &Config, msg_id: i64, text: &str) {
    let _ = tg_api(client, &cfg.bot_token, "editMessageText", &[
        ("chat_id", cfg.approver_chat_id.clone()),
        ("message_id", msg_id.to_string()),
        ("parse_mode", "HTML".to_string()),
        ("text", text.to_string()),
    ]);
}

fn hard_approval(cfg: &Config, command: &str, risk: Risk, reason: &str) -> Result<bool> {
    let client = Client::new();
    let rid = req_id("req");
    let text = format!(
        "🚨 <b>高危操作审批</b>\n\n<b>风险等级</b> {}\n<b>触发原因</b> {}\n\n<b>命令</b>\n<code>{}</code>\n\n<b>请求ID</b> <code>{}</code>\n\n<b>建议解读</b>\n{}\n\n请确认是否执行该操作：",
        risk.as_str().to_uppercase(), reason, command, rid, explain_command(command, false)
    );
    let kb = json!({"inline_keyboard":[[{"text":"✅ 批准执行","callback_data":format!("approve:{}", rid)},{"text":"⛔ 拒绝执行","callback_data":format!("reject:{}", rid)}]]});
    let sent = tg_api(&client, &cfg.bot_token, "sendMessage", &[
        ("chat_id", cfg.approver_chat_id.clone()),
        ("parse_mode", "HTML".to_string()),
        ("text", text),
        ("reply_markup", kb.to_string()),
    ])?;
    let msg_id = sent["result"]["message_id"].as_i64().unwrap_or_default();
    pin_msg(&client, cfg, msg_id);

    let decision = poll_for_callback(&client, &cfg.bot_token, &format!("approve:{}", rid), cfg.timeout_sec)?
        .or_else(|| poll_for_callback(&client, &cfg.bot_token, &format!("reject:{}", rid), 1).ok().flatten());

    let approved = match decision {
        Some((d, cbid)) if d.starts_with("approve:") => {
            let _ = tg_api(&client, &cfg.bot_token, "answerCallbackQuery", &[("callback_query_id", cbid), ("text", "✅ 已批准，开始执行".to_string())]);
            true
        }
        Some((_, cbid)) => {
            let _ = tg_api(&client, &cfg.bot_token, "answerCallbackQuery", &[("callback_query_id", cbid), ("text", "⛔ 已拒绝".to_string())]);
            false
        }
        None => false,
    };

    let final_text = format!(
        "🛡️ <b>审批已处理</b>\n\n<b>风险等级</b> {}\n<b>命令</b>\n<code>{}</code>\n\n<b>结果</b> {}\n\n<b>建议解读</b>\n{}",
        risk.as_str().to_uppercase(), command, if approved {"✅ 已批准"} else {"⛔ 已拒绝/超时"}, explain_command(command, false)
    );
    edit_msg(&client, cfg, msg_id, &final_text);
    unpin_msg(&client, cfg, msg_id);
    Ok(approved)
}

fn soft_guard(cfg: &Config, command: &str) -> Result<bool> {
    let client = Client::new();
    let rid = req_id("soft");
    let text = format!(
        "⚠️ <b>关键配置修改提醒</b>\n\n<code>{}</code>\n\n<b>建议解读</b>\n{}\n\n默认 {} 秒后自动放行；如需拦截请点按钮。\n<b>请求ID</b> <code>{}</code>",
        command, explain_command(command, true), cfg.soft_guard_timeout_sec, rid
    );
    let kb = json!({"inline_keyboard":[[{"text":"🛑 拦截本次执行","callback_data":format!("abort:{}", rid)}]]});
    let sent = tg_api(&client, &cfg.bot_token, "sendMessage", &[
        ("chat_id", cfg.approver_chat_id.clone()),
        ("parse_mode", "HTML".to_string()),
        ("text", text),
        ("reply_markup", kb.to_string()),
    ])?;
    let msg_id = sent["result"]["message_id"].as_i64().unwrap_or_default();

    let decision = poll_for_callback(&client, &cfg.bot_token, &format!("abort:{}", rid), cfg.soft_guard_timeout_sec)?;
    let blocked = if let Some((_d, cbid)) = decision {
        let _ = tg_api(&client, &cfg.bot_token, "answerCallbackQuery", &[("callback_query_id", cbid), ("text", "🛑 已拦截".to_string())]);
        true
    } else {
        false
    };

    let final_text = format!(
        "🛡️ <b>配置修改提醒已处理</b>\n\n<code>{}</code>\n\n<b>结果</b> {}\n\n<b>建议解读</b>\n{}",
        command,
        if blocked {"🛑 已拦截"} else {"✅ 超时自动放行"},
        explain_command(command, true)
    );
    edit_msg(&client, cfg, msg_id, &final_text);
    Ok(!blocked)
}

fn install() -> Result<()> {
    let rt = runtime_dir()?;
    fs::create_dir_all(&rt)?;

    let mut token = std::env::var("APPROVAL_BOT_TOKEN").unwrap_or_default();
    if token.trim().is_empty() {
        print!("Enter Telegram bot token: ");
        io::stdout().flush()?;
        io::stdin().read_line(&mut token)?;
        token = token.trim().to_string();
    }
    if token.is_empty() { return Err(anyhow!("empty token")); }

    let client = Client::new();
    let me = tg_api(&client, &token, "getMe", &[])?;
    if !me["ok"].as_bool().unwrap_or(false) { return Err(anyhow!("token invalid")); }
    let username = me["result"]["username"].as_str().unwrap_or("bot");
    println!("[ok] bot: @{}", username);

    let mut chat_id = std::env::var("APPROVAL_CHAT_ID").unwrap_or_default();
    if chat_id.trim().is_empty() {
        println!("Send one message to @{} now, then press Enter.", username);
        let mut dummy = String::new();
        io::stdin().read_line(&mut dummy)?;

        let base = tg_api(&client, &token, "getUpdates", &[("timeout", "0".to_string())])?;
        let mut offset = base["result"].as_array().and_then(|a| a.last()).and_then(|x| x["update_id"].as_i64()).unwrap_or(0) + 1;
        let deadline = now_ts() + 120;
        while now_ts() < deadline {
            let v = tg_api(&client, &token, "getUpdates", &[("offset", offset.to_string()), ("timeout", "10".to_string())])?;
            if let Some(arr) = v["result"].as_array() {
                if let Some(last) = arr.last().and_then(|x| x["update_id"].as_i64()) { offset = last + 1; }
                for it in arr {
                    if let Some(id) = it["message"]["chat"]["id"].as_i64() {
                        chat_id = id.to_string();
                        break;
                    }
                }
            }
            if !chat_id.is_empty() { break; }
        }
        if chat_id.is_empty() { return Err(anyhow!("chat id detection timeout")); }
    }

    let cfg = Config {
        bot_token: token,
        approver_chat_id: chat_id,
        timeout_sec: 300,
        soft_guard_timeout_sec: 10,
        openclaw_key_targets: vec![
            format!("{}/.openclaw/openclaw.json", home_dir()?.display()),
            format!("{}/.openclaw/extensions/", home_dir()?.display()),
            format!("{}/.openclaw/cron/jobs.json", home_dir()?.display()),
            format!("{}/.config/systemd/user/openclaw-gateway.service", home_dir()?.display()),
        ],
    };
    let cfg_path = config_path()?;
    let cfg_text = serde_json::to_string_pretty(&cfg)?;
    let mut f = OpenOptions::new().create(true).write(true).truncate(true).open(&cfg_path)?;
    f.write_all(cfg_text.as_bytes())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&cfg_path, fs::Permissions::from_mode(0o600))?;
    }

    let plugin_dir = home_dir()?.join(".openclaw/extensions/approval-guard-full");
    fs::create_dir_all(&plugin_dir)?;
    fs::write(plugin_dir.join("openclaw.plugin.json"), r#"{"id":"approval-guard-full","name":"Approval Guard Full","description":"Intercept exec tool calls and route them through approval guard","configSchema":{}}"#)?;
    let wrapper = std::env::current_exe()?.display().to_string();
    let plugin = format!(
        "const BIN=\"{}\";\nfunction q(s){{return `'${{s.replace(/'/g, `\'\"\'\"\'`)}}'`;}}\nexport default function register(api){{api.registerHook('before_tool_call', async (event,ctx)=>{{const n=String(event?.toolName??ctx?.toolName??''); if(n!=='exec')return; const p=event?.params??{{}}; const c=typeof p.command==='string'?p.command:''; if(!c.trim())return; if(c.includes(BIN))return; return {{params:{{...p, command:`${{q(BIN)}} run --command ${{q(c)}}`}}}};}},{{name:'approval-guard-full.before-tool-call',description:'Route exec through approval-guard'}});}}",
        wrapper
    );
    fs::write(plugin_dir.join("index.ts"), plugin)?;

    let _ = Command::new("openclaw").args(["gateway", "restart"]).status();
    println!("Installed. Test: approval-guard run --command \"sudo id\"");
    Ok(())
}

fn doctor() -> Result<()> {
    let cfg = load_config()?;
    println!("config ok, chat_id={} token_set={}", cfg.approver_chat_id, !cfg.bot_token.is_empty());
    Ok(())
}

fn run(command: &str) -> Result<i32> {
    let cfg = load_config()?;
    let (risk, reason) = assess_risk(command);

    if risk == Risk::Low {
        if is_soft_target(command, &cfg) {
            let allow = soft_guard(&cfg, command)?;
            if !allow { return Ok(20); }
        }
        return run_shell(command);
    }

    let approved = hard_approval(&cfg, command, risk, reason)?;
    if !approved {
        return Ok(10);
    }
    run_shell(command)
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    match cli.command {
        Commands::Install => install(),
        Commands::Doctor => doctor(),
        Commands::Run { command } => {
            let code = run(&command)?;
            std::process::exit(code);
        }
    }
}
