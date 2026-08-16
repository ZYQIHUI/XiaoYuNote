/**
 * XiaoYu 表格前端 — Univer（sheet + 公式）经 exceljs 读写 xlsx。
 *
 * 与 Flutter（webview_windows）通过全局 window.univerBridge 通信：
 *   newSheet()                     新建空工作簿
 *   loadXlsx(base64)               从 base64 载入 xlsx
 *   saveXlsx() -> Promise<string>  导出当前工作簿为 xlsx base64
 *   setDirty(bool) / getDirty()    编辑状态标记（保存/关闭提示）
 */

import * as coreNS from '@univerjs/core';
import * as renderNS from '@univerjs/engine-render';
import { FUniver } from '@univerjs/core/facade';
import '@univerjs/sheets/facade';
import '@univerjs/sheets-ui/facade';
import { Univer, UniverInstanceType, LocaleType, LogLevel } from '@univerjs/core';
// 暴露 core/render 服务引用（自定义编辑器用）
window.__univerCore = coreNS;
window.__univerRender = renderNS;
import { UniverSheetsPlugin } from '@univerjs/sheets';
import { UniverSheetsUIPlugin } from '@univerjs/sheets-ui';
import { UniverRenderEnginePlugin } from '@univerjs/engine-render';
import { UniverSheetsNumfmtPlugin } from '@univerjs/sheets-numfmt';
import { UniverSheetsZenEditorPlugin } from '@univerjs/sheets-zen-editor';
import { UniverUIPlugin } from '@univerjs/ui';
import { UniverDocsPlugin } from '@univerjs/docs';
import { UniverDocsUIPlugin } from '@univerjs/docs-ui';
import ExcelJS from 'exceljs';
// Univer UI 层必需样式（缺 CSS 会导致布局/渲染异常）
import '@univerjs/design/lib/index.css';
import '@univerjs/ui/lib/index.css';
import '@univerjs/sheets-ui/lib/index.css';
import '@univerjs/docs-ui/lib/index.css';
import designLocale from '@univerjs/design/lib/es/locale/zh-CN.js';
import sheetsLocale from '@univerjs/sheets/lib/es/locale/zh-CN.js';
import sheetsUILocale from '@univerjs/sheets-ui/lib/es/locale/zh-CN.js';
import uiLocale from '@univerjs/ui/lib/es/locale/zh-CN.js';
import docsUILocale from '@univerjs/docs-ui/lib/es/locale/zh-CN.js';

const locales = {
  [LocaleType.ZH_CN]: Object.assign(
    {},
    designLocale,
    sheetsLocale,
    sheetsUILocale,
    uiLocale,
    docsUILocale,
  ),
};

let univer = null;
let dirty = false;
/** 当前编辑的工作簿模型（loadXlsx 后记录，saveXlsx 用）。 */
let currentWorkbook = null;

/** 监听 Univer 命令执行，标记编辑状态（保存/关闭提示用）。 */
function setupDirtyTracking() {
  try {
    const commandService = univer.__getInjector().get('ICCommandService');
    if (commandService) {
      commandService.beforeCommandExecuted((command) => {
        // 忽略选择/滚动等只读命令
        const id = command && command.id ? command.id : '';
        if (id && /set-select|scroll|move|set-worksheet-active|set-scroll/i.test(id)) {
          return;
        }
        dirty = true;
      });
    }
  } catch (err) {
    // 监听失败不阻塞核心功能
  }
}

function createUniver() {
  const container = document.getElementById('app');
  univer = new Univer({
    locale: LocaleType.ZH_CN,
    locales,
    logLevel: LogLevel.VERBOSE,
  });
  // 最小插件集：Docs → RenderEngine → UI → DocsUI → Sheets → SheetsUI → Numfmt → ZenEditor
  // 单元格编辑由自定义实现（见 setupCustomCellEditor），不依赖公式引擎/RPC worker
  univer.registerPlugin(UniverDocsPlugin);
  univer.registerPlugin(UniverRenderEnginePlugin);
  univer.registerPlugin(UniverUIPlugin, { container });
  univer.registerPlugin(UniverDocsUIPlugin);
  univer.registerPlugin(UniverSheetsPlugin, {
    notExecuteFormula: true,
    autoHeightForMergedCells: true,
  });
  univer.registerPlugin(UniverSheetsUIPlugin);
  univer.registerPlugin(UniverSheetsNumfmtPlugin);
  univer.registerPlugin(UniverSheetsZenEditorPlugin);
  // 提高默认工作表列数（Univer 默认 20 列，宽表显示不全）
  try {
    const configService = univer.__getInjector().get('univer.config-service');
    if (configService && configService.setConfig) {
      configService.setConfig('DEFAULT_WORKSHEET_COLUMN_COUNT', 100);
      configService.setConfig('DEFAULT_WORKSHEET_ROW_COUNT', 100);
      configService.setConfig('DEFAULT_WORKSHEET_COLUMN_WIDTH', 60);
    }
  } catch (err) {
    // 配置失败不阻塞
  }
  window.__univer = univer;
  // FUniver facade（稳定 API，自定义编辑器用）
  window.__fUniver = FUniver.newAPI(univer);
  setupDirtyTracking();
}

/** exceljs 单元格值 → Univer cellData 条目。 */
function _cellToUniver(v) {
  const data = {};
  // 公式对象
  if (v && typeof v === 'object' && typeof v.formula === 'string') {
    data.f = v.formula;
    data.v = v.result !== undefined && v.result !== null ? v.result : '';
    return data;
  }
  // Date 对象 → 数字（Excel 日期序列值，保留日期格式 m）
  if (v instanceof Date) {
    data.v = _dateToSerial(v);
    data.t = 2;
    if (!data.m) data.m = 'yyyy/m/d';
    return data;
  }
  // 超链接 { text, hyperlink }
  if (v && typeof v === 'object' && v.hyperlink) {
    data.v = typeof v.text === 'string' && v.text.length ? v.text : v.hyperlink;
    data.t = 1;
    return data;
  }
  // 富文本 { richText: [...] }
  if (v && typeof v === 'object' && Array.isArray(v.richText)) {
    const text = v.richText.map((r) => (r && r.text != null ? r.text : '')).join('');
    data.v = text;
    data.t = 1;
    return data;
  }
  // 错误值 { error: '#DIV/0!' }
  if (v && typeof v === 'object' && v.error) {
    data.v = v.error;
    data.t = 1;
    return data;
  }
  // 原始值
  data.v = v;
  if (typeof v === 'string') {
    data.t = 1;
  } else if (typeof v === 'number') {
    data.t = 2;
  } else if (typeof v === 'boolean') {
    data.t = 3;
  }
  return data;
}

/** JS Date → Excel 序列号（1900 日期系统）。 */
function _dateToSerial(date) {
  // Excel 1900 系统：1900-01-01 = 1（含伪闰日 1900-02-29）
  const epoch = Date.UTC(1899, 11, 30);
  return (date.getTime() - epoch) / 86400000;
}

/** exceljs 行/列模型 → Univer workbookData（值/公式/合并/列宽/行高/样式）。 */
function toUniverData(workbook) {
  const sheets = {};
  const sheetOrder = [];
  workbook.eachSheet((ws, id) => {
    const sheetId = `sheet-${id}`;
    sheetOrder.push(sheetId);
    const cellData = {};
    const mergeData = [];
    const columnData = {};
    const rowData = {};
    let maxRow = 0;
    let maxCol = 0;
    // 列宽（只保留有效正数，null/0/undefined 跳过——避免 Univer 渲染异常）
    try {
      ws.columns.forEach((col, idx) => {
        let w = col && col.width;
        if (typeof w === 'object' && w !== null && 'w' in w) w = w.w;
        if (typeof w === 'number' && isFinite(w) && w > 0) {
          // Excel 列宽单位 ≈ 字符数；Univer 用 px，约乘 7 换算，至少 40px
          columnData[idx + 1] = { w: Math.max(Math.min(w * 7, 300), 40) };
        }
      });
    } catch (e) { /* 无列信息 */ }
    // 行高
    try {
      ws.eachRow((row, rowNumber) => {
        const h = row.height;
        if (h && h > 0) {
          rowData[rowNumber] = { h };
        }
      });
    } catch (e) { /* 无行高 */ }
    ws.eachRow((row, rowNumber) => {
      if (rowNumber > 10000) return;
      row.eachCell({ includeEmpty: false }, (cell, colNumber) => {
        const v = cell.value;
        if (v === null || v === undefined) return;
        const data = _cellToUniver(v);
        // 数字格式（如金额 ￥0.00、百分比、日期格式）
        if (cell.numFmt && cell.numFmt !== 'General') {
          data.m = cell.numFmt;
        }
        if (!cellData[rowNumber]) cellData[rowNumber] = {};
        cellData[rowNumber][colNumber] = data;
        maxRow = Math.max(maxRow, rowNumber);
        maxCol = Math.max(maxCol, colNumber);
      });
    });
    // 合并单元格
    try {
      if (ws._merges) {
        for (const m of Object.values(ws._merges)) {
          if (m && m.top !== undefined) {
            mergeData.push({ startRow: m.top, startColumn: m.left, endRow: m.bottom, endColumn: m.right });
          }
        }
      }
    } catch (e) { /* 无合并 */ }
    const name = ws.name || `Sheet${id}`;
    const sheet = {
      id: sheetId,
      name,
      // Univer 0.25 用 columnCount/rowCount（不是 colCount）
      // 按数据列 + 余量扩展（上限 300），避免空列太多导致视口定位偏差
      rowCount: Math.max(maxRow + 20, 100),
      columnCount: Math.min(Math.max(maxCol + 20, 30), 300),
      // 默认列宽：60px 适中（Univer 默认 88px 偏宽、36px 偏窄）
      defaultColumnWidth: 60,
      defaultRowHeight: 24,
      cellData,
    };
    if (mergeData.length) sheet.mergeData = mergeData;
    // 补全列宽：数据列若未显式设宽，用默认 60px（避免某些 xlsx 无 <col> 定义时列宽异常）
    for (let c = 1; c <= maxCol; c++) {
      if (!columnData[c]) columnData[c] = { w: 60 };
    }
    if (Object.keys(columnData).length) sheet.columnData = columnData;
    if (Object.keys(rowData).length) sheet.rowData = rowData;
    sheets[sheetId] = sheet;
  });
  return {
    id: 'workbook-1',
    name: 'XiaoYu 工作簿',
    appVersion: '0.25.1',
    locale: LocaleType.ZH_CN,
    sheetOrder,
    sheets,
  };
}

/** Univer workbook snapshot → exceljs 工作簿。 */
function toExceljs(univerData) {
  const wb = new ExcelJS.Workbook();
  const sheets = univerData.sheets || {};
  // 0.25 snapshot: sheets 是 {sheetId: IWorksheetData} 对象；也兼容数组
  const sheetList = Array.isArray(sheets) ? sheets : Object.values(sheets);
  for (const sheet of sheetList) {
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
        // 数字格式
        if (c.m && c.m !== 'General') {
          cell.numFmt = c.m;
        }
      }
    }
    // 合并单元格（Univer mergeData: {startRow, startColumn, endRow, endColumn}）
    if (Array.isArray(sheet.mergeData)) {
      for (const m of sheet.mergeData) {
        try {
          ws.mergeCells(
            m.startRow, m.startColumn, m.endRow, m.endColumn,
          );
        } catch (e) { /* 非法合并跳过 */ }
      }
    }
    // 列宽
    if (sheet.columnData) {
      for (const [idx, cd] of Object.entries(sheet.columnData)) {
        const w = cd && cd.w;
        if (w !== undefined && w !== null && Number(idx) > 0) {
          try { ws.getColumn(Number(idx)).width = Math.max(w, 0); } catch (e) {}
        }
      }
    }
    // 行高
    if (sheet.rowData) {
      for (const [idx, rd] of Object.entries(sheet.rowData)) {
        const h = rd && rd.h;
        if (h !== undefined && h !== null) {
          try { ws.getRow(Number(idx)).height = Math.max(h, 0); } catch (e) {}
        }
      }
    }
  }
  return wb;
}

window.univerBridge = {
  newSheet() {
    if (univer) {
      univer.createUnit(UniverInstanceType.UNIVER_SHEET, {
        id: 'workbook-' + Date.now(),
        name: '工作表',
        appVersion: '0.25.1',
        locale: LocaleType.ZH_CN,
        sheetOrder: ['sheet-1'],
        sheets: {
          'sheet-1': { id: 'sheet-1', name: 'Sheet1', rowCount: 100, columnCount: 100, defaultColumnWidth: 60, cellData: {} },
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
    const model = univer.createUnit(UniverInstanceType.UNIVER_SHEET, data);
    currentWorkbook = model;
    dirty = false;
  },

  async saveXlsx() {
    // 优先用 loadXlsx 记录的工作簿；否则取当前激活单元
    let wb = currentWorkbook;
    if (!wb) {
      const instanceSvc = univer && univer._univerInstanceService;
      if (instanceSvc) {
        wb = instanceSvc.getCurrentUnitOfType(UniverInstanceType.UNIVER_SHEET);
        if (!wb) {
          const units = instanceSvc.getAllUnitsForType(UniverInstanceType.UNIVER_SHEET) || [];
          wb = units[units.length - 1] || null;
        }
      }
    }
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

// 等待 DOM 就绪后初始化（避免模块加载阶段容器/布局未就绪导致失败）
function bootstrap() {
  try {
    createUniver();
    window.univerBridge.newSheet();
    // 挂载自定义单元格编辑（Univer 0.25.1 编辑器组件在此集成中未正确挂载，
    // 用浮动 input + 命令写入实现可靠编辑）
    setupCustomCellEditor();
    // 通知 Flutter：前端已就绪，可以开始通信
    if (window.chrome && window.chrome.webview) {
      window.chrome.webview.postMessage(JSON.stringify({ type: 'ready' }));
    }
  } catch (err) {
    console.error('[univer] bootstrap failed:', err);
    if (window.chrome && window.chrome.webview) {
      window.chrome.webview.postMessage(JSON.stringify({ type: 'error', message: String(err) }));
    }
  }
}

// ------------------------------------------------------------------
// 自定义单元格编辑（绕开 Univer 0.25.1 未挂载的编辑器组件）
// ------------------------------------------------------------------

let _cellEditor = null;
let _editCellRef = null; // {row, col} 1-based

/** 创建浮动单元格编辑器 input（覆盖在激活单元格上方）。 */
function ensureCellEditor() {
  if (_cellEditor) return _cellEditor;
  const input = document.createElement('input');
  input.type = 'text';
  Object.assign(input.style, {
    position: 'absolute',
    zIndex: '1000',
    display: 'none',
    fontSize: '14px',
    fontFamily: 'inherit',
    fontWeight: '500',
    padding: '3px 6px',
    border: '2px solid #4c8dff',
    borderRadius: '3px',
    outline: 'none',
    background: '#fff',
    color: '#000',
    boxShadow: '0 2px 8px rgba(0,0,0,0.25)',
    boxSizing: 'border-box',
    caretColor: '#4c8dff',
  });
  input.addEventListener('keydown', (e) => {
    e.stopPropagation();
    if (e.key === 'Enter') {
      e.preventDefault();
      commitCellEditor();
    } else if (e.key === 'Escape') {
      cancelCellEditor();
    } else if (e.key === 'Tab') {
      e.preventDefault();
      commitCellEditor();
    }
  });
  input.addEventListener('blur', () => commitCellEditor());
  document.body.appendChild(input);
  _cellEditor = input;
  return input;
}

/** 从 Univer 当前选区获取激活单元格（1-based row/col，点击后必然准确）。 */
function getActiveCellFromSelection() {
  try {
    const f = window.__fUniver;
    if (!f) return null;
    const sheet = f.getActiveWorkbook().getActiveSheet();
    const sel = sheet.getSelection();
    const range = sel && sel.getActiveRange ? sel.getActiveRange() : null;
    if (!range || !range._range) return null;
    const inner = range._range;
    return { row: inner.startRow + 1, col: inner.startColumn + 1 };
  } catch (e) {
    return null;
  }
}

/** 计算单元格的屏幕坐标（仅用于定位 input，行列不以此为准）。 */
function getCellScreenRect(row, col) {
  try {
    const canvas = document.querySelector('canvas');
    if (!canvas) return null;
    const crect = canvas.getBoundingClientRect();
    const sheet = window.__fUniver.getActiveWorkbook().getActiveSheet();
    let ex = 40;
    for (let c = 0; c < col - 1; c++) {
      const w = sheet.getColumnWidth ? sheet.getColumnWidth(c) : 60;
      ex += (w > 0 ? w : 60);
    }
    let ey = 24;
    for (let r = 0; r < row - 1; r++) {
      const h = sheet.getRowHeight ? sheet.getRowHeight(r) : 24;
      ey += (h > 0 ? h : 24);
    }
    const cw = sheet.getColumnWidth ? (sheet.getColumnWidth(col - 1) || 60) : 60;
    const rh = sheet.getRowHeight ? (sheet.getRowHeight(row - 1) || 24) : 24;
    return {
      x: crect.x + ex,
      y: crect.y + ey,
      w: cw,
      h: rh,
    };
  } catch (e) {
    return null;
  }
}

/** 在 canvas 上监听：双击进入编辑、键盘输入编辑。 */
function setupCustomCellEditor() {
  setTimeout(() => {
    const canvas = document.querySelector('canvas');
    if (!canvas) return;
    // 双击：进入编辑（Excel 风格，空输入框 + 光标闪烁）
    canvas.addEventListener('dblclick', (e) => {
      e.preventDefault();
      e.stopPropagation();
      commitCellEditor();
      openCellEditor();
    });
    // 单击：提交当前编辑（Univer 自己负责选中）
    canvas.addEventListener('pointerdown', () => {
      commitCellEditor();
    });
    // 键盘：直接输入 → 打开编辑器（单击选中后输入字符）
    canvas.addEventListener('keydown', (e) => {
      if (e.ctrlKey || e.metaKey || e.altKey) return;
      if (e.key.length === 1 && !e.key.startsWith('F')) {
        e.preventDefault();
        e.stopPropagation();
        openCellEditor(e.key);
      } else if (e.key === 'Enter' || e.key === 'Tab') {
        commitCellEditor();
      } else if (e.key === 'Escape') {
        cancelCellEditor();
      }
    });
  }, 2000);
}

/** 打开编辑器。firstChar 为 null/undefined 时打开空编辑器（双击场景），否则预填。 */
function openCellEditor(firstChar) {
  // 行列以 Univer 选区为准（点击后必然准确，免疫坐标偏差）
  const cell = getActiveCellFromSelection();
  if (!cell) return;
  const rect = getCellScreenRect(cell.row, cell.col);
  const input = ensureCellEditor();
  _editCellRef = { row: cell.row, col: cell.col };
  input.value = firstChar != null ? firstChar : '';
  input.style.display = 'block';
  if (rect) {
    input.style.left = rect.x + 'px';
    input.style.top = rect.y + 'px';
    input.style.width = Math.max(rect.w, 60) + 'px';
    input.style.height = Math.max(rect.h, 22) + 'px';
  } else {
    input.style.left = '200px';
    input.style.top = '200px';
    input.style.width = '160px';
    input.style.height = '24px';
  }
  input.focus();
  // 光标定位到末尾（双击空编辑器时光标在开头闪烁）
  input.setSelectionRange(input.value.length, input.value.length);
}

/** 提交编辑：把值写入激活单元格。 */
async function commitCellEditor() {
  const input = _cellEditor;
  if (!input || input.style.display === 'none') return;
  const ref = _editCellRef;
  input.style.display = 'none';
  _editCellRef = null;
  if (!ref) return;
  const value = input.value;
  if (value === '') return;
  try {
    const core = window.__univerCore;
    const injector = window.__univer.__getInjector();
    const cmdSvc = injector.get(core.ICommandService);
    const instSvc = injector.get(core.IUniverInstanceService);
    const unit = instSvc.getCurrentUnitOfType(2);
    const sheet = unit.getActiveSheet();
    const type = /^-?\d+(\.\d+)?$/.test(value) ? 2 : 1;
    const val = type === 2 ? Number(value) : value;
    await cmdSvc.executeCommand('sheet.command.set-range-values', {
      unitId: unit.getUnitId(),
      subUnitId: sheet.getSheetId(),
      range: {
        startRow: ref.row - 1, endRow: ref.row - 1,
        startColumn: ref.col - 1, endColumn: ref.col - 1,
      },
      value: { [ref.row]: { [ref.col]: { v: val, t: type } } },
    });
  } catch (err) {
    console.error('[univer] 写入单元格失败:', err);
  }
}

/** 取消编辑。 */
function cancelCellEditor() {
  if (_cellEditor) {
    _cellEditor.style.display = 'none';
    _cellEditor.value = '';
    _editCellRef = null;
  }
}

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', bootstrap);
} else {
  bootstrap();
}
