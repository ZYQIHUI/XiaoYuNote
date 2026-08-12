"""用 node 检查 exceljs 读取合并/列宽的实际结构。"""
import json

JS = """
const ExcelJS = require('exceljs');
const fs = require('fs');
// 构造带合并 + 列宽的工作簿
async function main() {
  const wb = new ExcelJS.Workbook();
  const ws = wb.addWorksheet('测试');
  ws.getCell('A1').value = '标题';
  ws.mergeCells('A1:C1');
  ws.getCell('A2').value = 123;
  ws.columns = [{ width: 20 }, { width: 15 }, { width: 10 }];
  ws.getRow(3).height = 30;
  const buf = await wb.xlsx.writeBuffer();
  fs.writeFileSync('/tmp/test_merge.xlsx', buf);

  // 重新读取
  const wb2 = new ExcelJS.Workbook();
  await wb2.xlsx.load(buf);
  const ws2 = wb2.getWorksheet('测试');
  console.log(JSON.stringify({
    merges: ws2._merges ? Object.values(ws2._merges).map(m => ({ top: m.top, left: m.left, bottom: m.bottom, right: m.right })) : 'none',
    columns: ws2.columns ? ws2.columns.map(c => c && c.width) : 'none',
    row3: ws2.getRow(3).height,
    a1: ws2.getCell('A1').value,
  }));
}
main().catch(e => { console.error('ERR', e.message); process.exit(1); });
"""
with open('D:/XiaoYu/XiaoYuNote/spring_note/univer_app/probe_merge.js', 'w', encoding='utf-8') as f:
    f.write(JS)
print('written')
