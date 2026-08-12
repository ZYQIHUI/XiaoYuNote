"""注入假 chrome.webview 模拟 WebView2，验证完整通信协议。"""
import asyncio
import base64
import json
import zipfile
import io

from playwright.async_api import async_playwright


def make_xlsx() -> str:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, 'w') as z:
        z.writestr('[Content_Types].xml', '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>')
        z.writestr('_rels/.rels', '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>')
        z.writestr('xl/workbook.xml', '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="对账清单" sheetId="1" r:id="rId1"/></sheets></workbook>')
        z.writestr('xl/_rels/workbook.xml.rels', '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>')
        z.writestr('xl/worksheets/sheet1.xml', '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>拼房大表对账</t></is></c><c r="B1" t="inlineStr"><is><t>金额</t></is></c></row><row r="2"><c r="A2" t="inlineStr"><is><t>D20260721002</t></is></c><c r="B2"><v>186.50</v></c></row></sheetData></worksheet>')
    return base64.b64encode(buf.getvalue()).decode()


async def main() -> None:
    port = json.load(open(r'C:\Users\zy186\AppData\Roaming\XiaoYu\.sidecar.json'))['port']
    url = f"http://127.0.0.1:{port}/univer/index.html"
    b64 = make_xlsx()
    async with async_playwright() as p:
        browser = await p.chromium.launch()
        page = await browser.new_page(viewport={"width": 1280, "height": 800})
        # 注入假 chrome.webview（模拟 WebView2），在页面加载前
        await page.add_init_script("""
        (() => {
          const listeners = [];
          window.chrome = window.chrome || {};
          window.chrome.webview = {
            listeners: listeners,
            addEventListener: (type, fn) => { if (type === 'message') listeners.push(fn); },
            removeEventListener: (type, fn) => { const i = listeners.indexOf(fn); if (i >= 0) listeners.splice(i, 1); },
            postMessage: (msg) => {
              // 模拟 WebView2 的 WebMessageReceived：把消息发给监听者
              listeners.forEach((fn) => fn({ data: msg }));
            },
          };
        })();
        """)
        logs: list[str] = []
        page.on("pageerror", lambda e: logs.append(f"pageerror: {e}"))
        page.on("console", lambda m: logs.append(f"console: {m.text}") if m.type in ("error", "warning") else None)
        await page.goto(url, wait_until="networkidle", timeout=30000)
        await page.wait_for_timeout(5000)
        # 通过注入的 chrome.webview 发 loadXlsx 命令（模拟 Flutter postWebMessage）
        result = await page.evaluate("""
        async (b64) => {
          const out = { hasWebview: !!(window.chrome && window.chrome.webview) };
          // 前端 bootstrap 时会发 ready；检查前端是否监听了 message
          out.listenerCount = window.chrome.webview.listeners.length;
          // 用 postMessage 发命令（会触发前端 handleCommand → 回 result）
          const reqId = 100;
          const respPromise = new Promise((resolve) => {
            const handler = (e) => {
              try {
                const d = typeof e.data === 'string' ? JSON.parse(e.data) : e.data;
                if (d && d.reqId === reqId) resolve(d);
              } catch (err) {}
            };
            window.chrome.webview.listeners.push(handler);
            window.chrome.webview.postMessage(JSON.stringify({ cmd: 'loadXlsx', reqId, base64: b64 }));
          });
          try {
            const r = await Promise.race([respPromise, new Promise((_, rej) => setTimeout(() => rej(new Error('timeout 15s')), 15000))]);
            out.result = r;
          } catch (e) { out.result = 'TIMEOUT: ' + String(e); }
          await new Promise(res => setTimeout(res, 2000));
          out.canvases = document.querySelectorAll('canvas').length;
          return out;
        }
        """, b64)
        result["logs"] = logs[:8]
        print(json.dumps(result, ensure_ascii=False))
        await browser.close()


asyncio.run(main())
