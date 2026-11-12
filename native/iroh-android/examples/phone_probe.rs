//! 用**真实 Android 传输库**当"手机"，连一台真实 host。
//!
//! 这是本机能做到的最接近真机的验证：同一份 `AndroidTransportSession`、
//! 同一套 iroh 生产发现/直连/中继、同一个 ALPN、同一份配对码流程。
//! 差别只在它跑在 macOS 而不是 Android（JNI 层没被覆盖）。
//!
//! 用法：
//!   phone_probe <data-dir> <peer-endpoint-id> <six-digit-code> <device-name>
//!
//! 连上后把 `connection_metadata` 打到 stdout（含本地 carrier 端口），
//! 然后等 stdin 收到一行输入再干净关闭。

use std::path::PathBuf;

use dsh_mobile_iroh_android_transport::{connect_with_options, TransportOptions};
use iroh::EndpointId;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let mut args = std::env::args().skip(1);
    let data_dir = PathBuf::from(args.next().expect("data-dir"));
    let peer_text = args.next().expect("peer endpoint id");
    let code = args.next().expect("six digit code");
    let name = args
        .next()
        .unwrap_or_else(|| "macOS phone probe".to_string());
    // 与 Flutter 端一致：carrier 端口必须取描述符里的 localPort，
    // 否则本地回环端口与二维码 origin 的端口对不上。
    let local_port: u16 = args
        .next()
        .expect("local port")
        .parse()
        .map_err(|_| anyhow::anyhow!("bad local port"))?;

    if !data_dir.is_absolute() {
        anyhow::bail!("data-dir must be absolute");
    }
    let peer: EndpointId = peer_text.parse().map_err(|_| anyhow::anyhow!("bad endpoint id"))?;

    let session = connect_with_options(
        &data_dir,
        peer,
        Some(&code),
        &name,
        TransportOptions {
            local_port,
            ..TransportOptions::default()
        },
    )
    .await?;
    // 只输出机器可读的一行；不含任何凭据。
    println!("{}", session.connection_metadata());
    println!("AUTHORITY {}", session.https_authority());

    // 保持会话存活，直到父进程让我们收工。
    let mut line = String::new();
    let _ = std::io::stdin().read_line(&mut line);
    session.close().await;
    Ok(())
}
