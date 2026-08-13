//! 极简 HTTP 静态文件服务器 — 托管 Univer 前端（ES module 需 http:// 协议）。
//!
//! sidecar 移除后，Univer（<script type="module">）无法从 file:// 加载，
//! 因此用 Rust 内置一个仅绑定 127.0.0.1 随机端口的静态服务器。

use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread;

/// 全局服务器状态：root 目录 + 监听端口。
struct StaticServer {
    port: u16,
}

static SERVER: OnceLock<Arc<Mutex<Option<StaticServer>>>> = OnceLock::new();

fn server_state() -> &'static Arc<Mutex<Option<StaticServer>>> {
    SERVER.get_or_init(|| Arc::new(Mutex::new(None)))
}

/// 启动静态服务器（幂等）：首次调用绑定随机端口并后台线程服务，
/// 之后返回已有端口。返回 "http://127.0.0.1:PORT" 或空字符串（失败）。
pub fn start_static_server(root_dir: &str) -> String {
    let root = PathBuf::from(root_dir);
    if !root.is_dir() {
        return String::new();
    }
    let state = server_state();
    {
        let guard = state.lock().unwrap();
        if let Some(server) = guard.as_ref() {
            return format!("http://127.0.0.1:{}", server.port);
        }
    }

    let listener = match TcpListener::bind("127.0.0.1:0") {
        Ok(l) => l,
        Err(_) => return String::new(),
    };
    let port = listener.local_addr().map(|a| a.port()).unwrap_or(0);
    {
        let mut guard = state.lock().unwrap();
        *guard = Some(StaticServer { port });
    }

    let root = Arc::new(root);
    thread::spawn(move || {
        for stream in listener.incoming() {
            if let Ok(stream) = stream {
                let root = Arc::clone(&root);
                thread::spawn(move || {
                    handle_connection(stream, &root);
                });
            }
        }
    });

    format!("http://127.0.0.1:{port}")
}

fn handle_connection(mut stream: TcpStream, root: &Path) {
    let mut buf = [0u8; 8192];
    let n = match stream.read(&mut buf) {
        Ok(n) => n,
        Err(_) => return,
    };
    let request = String::from_utf8_lossy(&buf[..n]);
    // 解析请求行：GET /path HTTP/1.1
    let Some(request_line) = request.lines().next() else { return };
    let mut parts = request_line.split_whitespace();
    let method = parts.next().unwrap_or("");
    let path = parts.next().unwrap_or("/");
    if method != "GET" && method != "HEAD" {
        let _ = write_response(&mut stream, 405, "text/plain", b"Method Not Allowed");
        return;
    }

    // 路径规范化 + 防目录穿越
    let decoded = percent_decode(path);
    let rel = decoded.trim_start_matches('/');
    let rel = if rel.is_empty() { "index.html" } else { rel };
    let file_path = root.join(rel);
    if !file_path.starts_with(root) {
        let _ = write_response(&mut stream, 403, "text/plain", b"Forbidden");
        return;
    }

    if file_path.is_dir() {
        let _ = write_response(&mut stream, 404, "text/plain", b"Not Found");
        return;
    }

    match std::fs::read(&file_path) {
        Ok(bytes) => {
            let mime = mime_for(&file_path);
            let _ = write_response(&mut stream, 200, mime, &bytes);
        }
        Err(_) => {
            let _ = write_response(&mut stream, 404, "text/plain", b"Not Found");
        }
    }
}

fn write_response(
    stream: &mut TcpStream,
    status: u16,
    mime: &str,
    body: &[u8],
) -> std::io::Result<()> {
    let status_text = match status {
        200 => "OK",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        _ => "Error",
    };
    let header = format!(
        "HTTP/1.1 {status} {status_text}\r\nContent-Type: {mime}\r\nContent-Length: {}\r\nCache-Control: no-cache\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n",
        body.len()
    );
    stream.write_all(header.as_bytes())?;
    stream.write_all(body)?;
    stream.flush()
}

fn mime_for(path: &Path) -> &'static str {
    match path.extension().and_then(|e| e.to_str()) {
        Some("html") => "text/html; charset=utf-8",
        Some("js") => "application/javascript; charset=utf-8",
        Some("mjs") => "application/javascript; charset=utf-8",
        Some("css") => "text/css; charset=utf-8",
        Some("json") => "application/json",
        Some("map") => "application/json",
        Some("svg") => "image/svg+xml",
        Some("png") => "image/png",
        Some("jpg") | Some("jpeg") => "image/jpeg",
        Some("gif") => "image/gif",
        Some("webp") => "image/webp",
        Some("ico") => "image/x-icon",
        Some("woff") => "font/woff",
        Some("woff2") => "font/woff2",
        Some("ttf") => "font/ttf",
        Some("otf") => "font/otf",
        Some("wasm") => "application/wasm",
        _ => "application/octet-stream",
    }
}

fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let (Some(h), Some(l)) = (hex_val(bytes[i + 1]), hex_val(bytes[i + 2])) {
                out.push(h * 16 + l);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).to_string()
}

fn hex_val(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        b'A'..=b'F' => Some(b - b'A' + 10),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mime_types() {
        assert_eq!(mime_for(Path::new("a.html")), "text/html; charset=utf-8");
        assert_eq!(mime_for(Path::new("a.js")), "application/javascript; charset=utf-8");
        assert_eq!(mime_for(Path::new("a.woff2")), "font/woff2");
        assert_eq!(mime_for(Path::new("a.wasm")), "application/wasm");
    }

    #[test]
    fn percent_decodes() {
        assert_eq!(percent_decode("/a%20b.js"), "/a b.js");
        assert_eq!(percent_decode("/plain"), "/plain");
    }

    #[test]
    fn server_serves_index() {
        let dir = std::env::temp_dir().join(format!("xyn_srv_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("index.html"), "<h1>test</h1>").unwrap();
        let url = start_static_server(&dir.to_string_lossy());
        assert!(!url.is_empty(), "server should start");
        // 拉取首页
        let body = std::process::Command::new("curl")
            .args(["-s", &format!("{url}/")])
            .output()
            .map(|o| String::from_utf8_lossy(&o.stdout).to_string())
            .unwrap_or_default();
        assert!(body.contains("test"));
        std::fs::remove_dir_all(&dir).ok();
    }
}
