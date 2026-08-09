/**
 * XiaoYu 表格前端 — Univer（sheet + 公式）经 exceljs 读写 xlsx。
 *
 * 与 Flutter（webview_windows）通过全局 window.univerBridge 通信：
 *   newSheet()                     新建空工作簿
 *   loadXlsx(base64)               从 base64 载入 xlsx
 *   saveXlsx() -> Promise<string>  导出当前工作簿为 xlsx base64
 *   setDirty(bool) / getDirty()    编辑状态标记（保存/关闭提示）
 */

import { Univer, UniverInstanceType } from '@univerjs/core';
import { UniverSheetsPlugin } from '@univerjs/sheets';
import { UniverSheetsUIPlugin } from '@univerjs/sheets-ui';
import { UniverSheetsFormulaPlugin } from '@univerjs/sheets-formula';
import { UniverSheetsFormulaUIPlugin } from '@univerjs/sheets-formula-ui';
import ExcelJS from 'exceljs';

let univer = null;
let dirty = false;

function createUniver() {
  const container = document.getElementById('app');
  univer = new Univer({
    locale: 'zhCN',
    container,
  });
  univer.registerPlugin(UniverSheetsPlugin);
  univer.registerPlugin(UniverSheetsFormulaPlugin);
  univer.registerPlugin(UniverSheetsFormulaUIPlugin);
  univer.registerPlugin(UniverSheetsUIPlugin);
  setupDirtyTracking();
}

/** exceljs 行/列模型 → Univer workbookData（cellData: {r: {c: {v}}}）。 */
function toUniverData(workbook) {
  const sheets = {};
  const sheetOrder = [];
  workbook.eachSheet((ws, id) => {
    const sheetId = `sheet-${id}`;
    sheetOrder.push(sheetId);
    const cellData = {};
    let maxRow = 0;
    let maxCol = 0;
    ws.eachRow((row, rowNumber) => {
      if (rowNumber > 10000) return;
      row.eachCell({ includeEmpty: false }, (cell, colNumber) => {
        const v = cell.value;
        if (v === null || v === undefined) return;
        const data = {};
        if (typeof v === 'object' && v.formula) {
          data.f = v.formula; // 公式：保留
          data.v = v.result !== undefined ? v.result : '';
        } else {
          data.v = v;
        }
        if (!cellData[rowNumber]) cellData[rowNumber] = {};
        cellData[rowNumber][colNumber] = data;
        maxRow = Math.max(maxRow, rowNumber);
        maxCol = Math.max(maxCol, colNumber);
      });
    });
    const name = ws.name || `Sheet${id}`;
    sheets[sheetId] = {
      id: sheetId,
      name,
      rowCount: Math.max(maxRow + 10, 100),
      colCount: Math.max(maxCol + 5, 20),
      cellData,
    };
  });
  return {
    id: 'workbook-1',
    name: 'XiaoYu 工作簿',
    sheetOrder,
    sheets,
  };
}

/** Univer workbook snapshot → exceljs 工作簿。 */
function toExceljs(univerData) {
  const wb = new ExcelJS.Workbook();
  univerData.sheets.forEach((sheet) => {
    const ws = wb.addWorksheet(sheet.name || 'Sheet1');
    const cellData = sheet.cellData || {};
    const sheetOrder = Object.keys(cellData).map(Number).sort((a, b) => a - b);
    for (const rowNum of sheetOrder) {
      const rowMap = cellData[rowNum];
      const cols = Object.keys(rowMap).map(Number).sort((a, b) => a - b);
      for (const colNum of cols) {
        const c = rowMap[colNum];
        if (!c) continue;
        const cell = ws.getCell(rowNum, colNum);
        if (c.f) {
          cell.value = { formula: c.f.startsWith('=') ? c.f : `=${c.f}`, result: c.v };
        } else {
          cell.value = c.v;
        }
      }
    }
  });
  return wb;
}

window.univerBridge = {
  newSheet() {
    if (univer) {
      univer.createUnit(UniverInstanceType.UNIVER_SHEET, {
        name: '工作表',
        sheetOrder: ['sheet-1'],
        sheets: {
          'sheet-1': { id: 'sheet-1', name: 'Sheet1', rowCount: 100, colCount: 20, cellData: {} },
        },
      });
    }
    dirty = false;
  },

  async loadXlsx(base64) {
    const buf = Uint8Array.from(atob(base64), (c) => c.charCodeAt(0));
    const wb = new ExcelJS.Workbook();
    await wb.xlsx.load(buf);
    const data = toUniverData(wb);
    if (!univer) createUniver();
    univer.createUnit(UniverInstanceType.UNIVER_SHEET, data);
    dirty = false;
  },

  async saveXlsx() {
    const wb = univer.getCurrentUniverInstance(UniverInstanceType.UNIVER_SHEET);
    if (!wb) return null;
    const snapshot = wb.getSnapshot();
    const excel = toExceljs(snapshot);
    const arrayBuffer = await excel.xlsx.writeBuffer();
    const bytes = new Uint8Array(arrayBuffer);
    let binary = '';
    const CHUNK = 0x8000;
    for (let i = 0; i < bytes.length; i += CHUNK) {
      binary += String.fromCharCode.apply(null, bytes.subarray(i, i + CHUNK));
    }
    dirty = false;
    return btoa(binary);
  },

  setDirty(v) { dirty = !!v; },
  getDirty() { return dirty; },
};

// 与 Flutter（webview_windows）的双向命令通道：postWebMessage 请求 → 回复结果。
async function handleCommand(cmd) {
  const result = { type: 'result', cmd: cmd.cmd, reqId: cmd.reqId, ok: true };
  try {
    if (cmd.cmd === 'loadXlsx') {
      await window.univerBridge.loadXlsx(cmd.base64);
    } else if (cmd.cmd === 'saveXlsx') {
      result.data = await window.univerBridge.saveXlsx();
    } else if (cmd.cmd === 'newSheet') {
      window.univerBridge.newSheet();
    } else {
      result.ok = false;
      result.error = 'unknown command: ' + cmd.cmd;
    }
  } catch (err) {
    result.ok = false;
    result.error = String(err && err.message ? err.message : err);
  }
  if (window.chrome && window.chrome.webview) {
    window.chrome.webview.postMessage(JSON.stringify(result));
  }
}

if (window.chrome && window.chrome.webview) {
  window.chrome.webview.addEventListener('message', (e) => {
    try {
      const data = typeof e.data === 'string' ? JSON.parse(e.data) : e.data;
      if (data && data.cmd) {
        handleCommand(data);
      }
    } catch (err) {
      /* 忽略无法解析的消息 */
    }
  });
}

createUniver();
window.univerBridge.newSheet();
