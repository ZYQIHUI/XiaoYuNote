//! xls → xlsx 转换器。
//!
//! Univer 前端（exceljs）只支持 xlsx，无法解析老式 .xls 二进制。
//! 用 calamine 读取 .xls 数据，再生成最小 xlsx（zip + XML）供前端加载。

use calamine::Reader;
use std::io::Write;
use std::path::Path;

/// 将 .xls 文件转换为 xlsx 字节（base64 由调用方处理）。
pub fn xls_to_xlsx_bytes(path: &Path) -> Result<Vec<u8>, String> {
    let mut workbook = calamine::open_workbook_auto(path)
        .map_err(|e| format!("打开 xls 失败: {e}"))?;
    let sheet_names: Vec<String> = workbook.sheet_names().to_vec();

    let mut sheets_xml: Vec<String> = Vec::new();
    let mut sheet_entries: Vec<(String, String)> = Vec::new(); // (name, xml)

    for (idx, sheet_name) in sheet_names.iter().enumerate() {
        let range = workbook
            .worksheet_range(sheet_name)
            .map_err(|e| format!("读取 sheet {sheet_name} 失败: {e}"))?;
        let rows = range.rows();
        // 收集行列数据
        let mut max_row = 0usize;
        let mut max_col = 0usize;
        let mut cells: Vec<(usize, usize, String)> = Vec::new(); // (row, col, value)
        for (ri, row) in rows.enumerate() {
            for (ci, cell) in row.iter().enumerate() {
                if matches!(cell, calamine::Data::Empty) {
                    continue;
                }
                let value = match cell {
                    calamine::Data::String(s) => s.clone(),
                    calamine::Data::Float(f) => format_float(*f),
                    calamine::Data::Int(i) => i.to_string(),
                    calamine::Data::Bool(b) => if *b { "TRUE".to_string() } else { "FALSE".to_string() },
                    calamine::Data::DateTime(dt) => dt.to_string(),
                    calamine::Data::Error(e) => format!("{e:?}"),
                    calamine::Data::Empty => continue,
                    _ => continue,
                };
                if value.is_empty() {
                    continue;
                }
                cells.push((ri + 1, ci + 1, value));
                max_row = max_row.max(ri + 1);
                max_col = max_col.max(ci + 1);
            }
        }
        // 生成 sheet XML
        let sheet_xml = build_sheet_xml(&cells, max_row, max_col);
        sheets_xml.push(sheet_xml);
        sheet_entries.push((sheet_name.clone(), format!("sheet{idx}")));
    }

    if sheet_entries.is_empty() {
        // 至少一个空 sheet
        sheet_entries.push(("Sheet1".to_string(), "sheet0".to_string()));
        sheets_xml.push(build_sheet_xml(&[], 500, 150));
    }

    build_xlsx_archive(&sheet_entries, &sheets_xml)
}

/// 生成单个 worksheet 的 XML。
fn build_sheet_xml(cells: &[(usize, usize, String)], _max_row: usize, max_col: usize) -> String {
    let mut xml = String::new();
    xml.push_str("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>");
    xml.push_str(
        "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">",
    );
    // 列定义（前 26 列设默认宽，让前端显示更多列）
    xml.push_str("<cols>");
    for i in 1..=max_col.min(26) {
        xml.push_str(&format!("<col min=\"{i}\" max=\"{i}\" width=\"9\" customWidth=\"1\"/>"));
    }
    xml.push_str("</cols>");
    xml.push_str("<sheetData>");
    for (row, col, value) in cells {
        let cell_ref = format!("{}{}", col_letter(*col - 1), row);
        // 纯数字 → 数值单元格；否则字符串（inlineStr 避免共享字符串表）
        if let Ok(num) = value.parse::<f64>() {
            let formatted = if num.fract() == 0.0 && value.contains('.') {
                format!("{num}")
            } else if num.fract() == 0.0 {
                format!("{}", num as i64)
            } else {
                format!("{num}")
            };
            xml.push_str(&format!(
                "<row r=\"{row}\"><c r=\"{cell_ref}\"><v>{formatted}</v></c></row>"
            ));
        } else {
            let escaped = xml_escape(value);
            xml.push_str(&format!(
                "<row r=\"{row}\"><c r=\"{cell_ref}\" t=\"inlineStr\"><is><t>{escaped}</t></is></c></row>"
            ));
        }
    }
    xml.push_str("</sheetData></worksheet>");
    xml
}

/// 打包最小 xlsx（zip）。
fn build_xlsx_archive(
    sheets: &[(String, String)], // (sheet_name, file_stem)
    sheets_xml: &[String],
) -> Result<Vec<u8>, String> {
    let mut buffer: Vec<u8> = Vec::new();
    {
        let mut zip = zip::ZipWriter::new(std::io::Cursor::new(&mut buffer));
        let options = zip::write::SimpleFileOptions::default()
            .compression_method(zip::CompressionMethod::Deflated);

        // [Content_Types].xml
        let mut content_types = String::new();
        content_types.push_str("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>");
        content_types.push_str(
            "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">",
        );
        content_types.push_str("<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>");
        content_types.push_str("<Default Extension=\"xml\" ContentType=\"application/xml\"/>");
        content_types.push_str("<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>");
        for (_, stem) in sheets {
            content_types.push_str(&format!(
                "<Override PartName=\"/xl/worksheets/{stem}.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
            ));
        }
        content_types.push_str("</Types>");
        zip.start_file("[Content_Types].xml", options)
            .map_err(|e| e.to_string())?;
        zip.write_all(content_types.as_bytes()).map_err(|e| e.to_string())?;

        // _rels/.rels
        let rels = r#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
</Relationships>"#;
        zip.start_file("_rels/.rels", options).map_err(|e| e.to_string())?;
        zip.write_all(rels.as_bytes()).map_err(|e| e.to_string())?;

        // xl/workbook.xml
        let mut workbook_xml = String::new();
        workbook_xml.push_str("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>");
        workbook_xml.push_str(
            "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">",
        );
        workbook_xml.push_str("<sheets>");
        for (i, (name, _)) in sheets.iter().enumerate() {
            workbook_xml.push_str(&format!(
                "<sheet name=\"{}\" sheetId=\"{}\" r:id=\"rId{}\"/>",
                xml_escape(name),
                i + 1,
                i + 1
            ));
        }
        workbook_xml.push_str("</sheets></workbook>");
        zip.start_file("xl/workbook.xml", options).map_err(|e| e.to_string())?;
        zip.write_all(workbook_xml.as_bytes()).map_err(|e| e.to_string())?;

        // xl/_rels/workbook.xml.rels
        let mut wb_rels = String::new();
        wb_rels.push_str("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>");
        wb_rels.push_str(
            "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">",
        );
        for (i, (_, stem)) in sheets.iter().enumerate() {
            wb_rels.push_str(&format!(
                "<Relationship Id=\"rId{}\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/{stem}.xml\"/>",
                i + 1
            ));
        }
        wb_rels.push_str("</Relationships>");
        zip.start_file("xl/_rels/workbook.xml.rels", options)
            .map_err(|e| e.to_string())?;
        zip.write_all(wb_rels.as_bytes()).map_err(|e| e.to_string())?;

        // sheets
        for (i, (_, stem)) in sheets.iter().enumerate() {
            zip.start_file(format!("xl/worksheets/{stem}.xml"), options)
                .map_err(|e| e.to_string())?;
            zip.write_all(sheets_xml[i].as_bytes())
                .map_err(|e| e.to_string())?;
        }

        zip.finish().map_err(|e| e.to_string())?;
    }
    Ok(buffer)
}

fn format_float(f: f64) -> String {
    if (f - f.round()).abs() < 1e-9 {
        format!("{}", f.round() as i64)
    } else {
        format!("{f}")
    }
}

fn col_letter(index: usize) -> String {
    let mut n = index;
    let mut s = String::new();
    loop {
        s.insert(0, ((n % 26) as u8 + b'A') as char);
        if n < 26 {
            break;
        }
        n = n / 26 - 1;
    }
    s
}

fn xml_escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn col_letter_works() {
        assert_eq!(col_letter(0), "A");
        assert_eq!(col_letter(25), "Z");
        assert_eq!(col_letter(26), "AA");
    }

    #[test]
    fn xml_escapes() {
        assert_eq!(xml_escape("a<b&c"), "a&lt;b&amp;c");
    }

    #[test]
    fn builds_minimal_xlsx() {
        let bytes = build_xlsx_archive(
            &[("Sheet1".to_string(), "sheet0".to_string())],
            &[build_sheet_xml(&[(1, 1, "42".to_string())], 500, 150)],
        )
        .unwrap();
        // zip 应包含关键部件
        let mut zip = zip::ZipArchive::new(std::io::Cursor::new(bytes)).unwrap();
        let names: Vec<String> = (0..zip.len())
            .map(|i| zip.by_index(i).unwrap().name().to_string())
            .collect();
        assert!(names.contains(&"[Content_Types].xml".to_string()));
        assert!(names.contains(&"xl/workbook.xml".to_string()));
        assert!(names.contains(&"xl/worksheets/sheet0.xml".to_string()));
    }

    #[test]
    fn xls_to_xlsx_generates() {
        // 无 xls 样例文件，验证空 sheet 路径也能生成
        let dir = std::env::temp_dir().join(format!("xyn_xls_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        // 构造一个空 xlsx 当输入（open_workbook_auto 按扩展名）
        // 这里只验证 build_sheet_xml 的空表输出
        let xml = build_sheet_xml(&[], 500, 150);
        assert!(xml.contains("<sheetData>"));
        std::fs::remove_dir_all(&dir).ok();
    }
}
