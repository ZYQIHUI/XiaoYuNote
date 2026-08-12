//! 精确值检索通道 — Excel 单号/金额精确匹配。
//!
//! 从问题中提取候选 token（字母+数字、小数金额、中文滑窗），
//! 对 cells 精确值索引做 SQL 精确/LIKE 匹配，返回带单元格引用。

use super::store::{self, CellRecord};
use regex::Regex;
use rusqlite::Connection;
use std::collections::HashSet;

/// 精确值命中项（含引用格式 `文件!Sheet A3`）。
#[derive(Clone, Debug)]
pub struct ExactHit {
    pub cell: CellRecord,
    pub ref_text: String,
}

/// 提取候选精确值 token：(精确值列表, LIKE 值列表)。
pub fn extract_query_tokens(query: &str) -> (Vec<String>, Vec<String>) {
    let alnum_re = Regex::new(r"[A-Za-z]{1,6}[0-9]{3,}").unwrap();
    let number_re = Regex::new(r"\d+\.\d{1,4}|\d{4,}").unwrap();
    let cn_re = Regex::new(r"\p{Han}{2,}").unwrap();

    let mut exact: Vec<String> = Vec::new();
    let mut seen_exact: HashSet<String> = HashSet::new();
    for m in alnum_re.find_iter(query) {
        let token = m.as_str().to_string();
        if seen_exact.insert(token.clone()) {
            exact.push(token);
        }
    }
    // 数字 token：若已被字母+数字覆盖则跳过
    for m in number_re.find_iter(query) {
        let num = m.as_str().to_string();
        if exact.iter().any(|a| a.contains(&num)) {
            continue;
        }
        if seen_exact.insert(num.clone()) {
            exact.push(num);
        }
    }

    // 中文 LIKE token：2~4 字滑窗
    let mut cn_tokens: HashSet<String> = HashSet::new();
    for m in cn_re.find_iter(query) {
        let seg = m.as_str();
        if seg.chars().count() <= 4 {
            cn_tokens.insert(seg.to_string());
        } else {
            let chars: Vec<char> = seg.chars().collect();
            for w in 2..=4 {
                for i in 0..chars.len().saturating_sub(w - 1) {
                    cn_tokens.insert(chars[i..i + w].iter().collect());
                }
            }
        }
    }
    let mut like: Vec<String> = cn_tokens.into_iter().collect();
    like.sort();

    (exact, like)
}

/// 精确值检索：精确命中优先，LIKE 兜底，去重后返回。
pub fn search_exact(
    conn: &Connection,
    query: &str,
    path_prefix: Option<&str>,
    top_n: i64,
) -> Vec<ExactHit> {
    let (exact, like) = extract_query_tokens(query);
    if exact.is_empty() && like.is_empty() {
        return Vec::new();
    }
    let rows_exact = store::search_cells(conn, &exact, &[], path_prefix, top_n).unwrap_or_default();
    let rows_like = store::search_cells(conn, &[], &like, path_prefix, top_n * 2).unwrap_or_default();

    let mut seen: HashSet<(String, String, i64, i64)> = HashSet::new();
    let mut merged: Vec<ExactHit> = Vec::new();
    for row in rows_exact.into_iter().chain(rows_like) {
        let key = (
            row.rel_path.clone(),
            row.sheet_name.clone(),
            row.row,
            row.col,
        );
        if !seen.insert(key) {
            continue;
        }
        let ref_text = format!("{}!{} {}{}", row.rel_path, row.sheet_name, row.col_letter, row.row);
        merged.push(ExactHit { cell: row, ref_text });
        if merged.len() >= top_n as usize {
            break;
        }
    }
    merged
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extracts_order_number() {
        let (exact, _) = extract_query_tokens("D20260721002 的金额是多少");
        assert!(exact.iter().any(|t| t == "D20260721002"));
    }

    #[test]
    fn extracts_amount() {
        let (exact, _) = extract_query_tokens("金额 186.50 的订单");
        assert!(exact.iter().any(|t| t == "186.50"));
    }

    #[test]
    fn extracts_chinese_like_tokens() {
        let (_, like) = extract_query_tokens("已对账的清单");
        assert!(like.iter().any(|t| t == "已对账"));
    }

    #[test]
    fn empty_query_no_tokens() {
        let (exact, like) = extract_query_tokens("你好");
        // "你好" 是 2 字中文 → 进 like
        assert!(exact.is_empty());
        assert!(like.iter().any(|t| t == "你好"));
    }
}
