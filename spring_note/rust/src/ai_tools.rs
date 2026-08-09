//! 回忆书工具的供应商中立定义。
//!
//! 工具是跨供应商的通用能力：这里统一定义名称、描述和参数 Schema，
//! 各供应商模块（ai_openai / ai_claude / ai_gemini）只负责把这些定义
//! 转换为各自接口的线上格式，不再各自维护一份工具清单。

use serde_json::{json, Value};

/// 日期参数的格式约束（YYYY-MM-DD，年份限 20xx）。
const DATE_PATTERN: &str = r"^20\d{2}-(0[1-9]|1[0-2])-([0-2][0-9]|3[0-1])$";
/// ISO 周参数的格式约束（YYYY-Www）。
const WEEK_PATTERN: &str = r"^20\d{2}-W(0[1-9]|[1-4]\d|5[0-3])$";
/// 月份参数的格式约束（YYYY-MM）。
const MONTH_PATTERN: &str = r"^20\d{2}-(0[1-9]|1[0-2])$";

/// 单个工具的供应商中立定义。
#[derive(Clone, Debug)]
pub struct AiToolDefinition {
    pub name: &'static str,
    pub description: &'static str,
    /// 工具参数的 JSON Schema 对象；各供应商按需裁剪不支持的字段。
    pub parameters: Value,
    /// 是否满足 OpenAI strict 模式的约束（required 覆盖全部属性、
    /// additionalProperties 为 false）；不使用严格模式的供应商忽略该字段。
    pub strict: bool,
}

/// 回忆书可用的全部工具，数组顺序即请求中 tools 的顺序。
pub fn memory_tools() -> Vec<AiToolDefinition> {
    vec![
        AiToolDefinition {
            name: "get_current_date",
            description: "Get the current local date, ISO week label, and week number. Use this before resolving relative dates such as today, yesterday, this week, this month.",
            parameters: json!({
                "type": "object",
                "properties": {},
                "required": [],
                "additionalProperties": false
            }),
            strict: true,
        },
        AiToolDefinition {
            name: "keyword_search",
            description: "Run one global indexed search across SpringNote daily, weekly, and monthly Markdown records. Use this only when the record type is unknown or the answer may span multiple types; prefer a scoped search when the user names daily, weekly, or monthly records. When calling keyword_search, submit all distinctive keywords in this single call. Every keyword must contain at least two Unicode characters. Each result includes truncated and totalCharacters fields: truncated is true when the snippet is clipped to a character limit (clipped parts are marked with '...'), and totalCharacters is the record's full length.",
            parameters: keyword_parameters("global"),
            strict: true,
        },
        AiToolDefinition {
            name: "search_daily_notes",
            description: "Search only SpringNote daily Markdown notes. Use this instead of keyword_search when the request is limited to daily notes or day-level records. Submit all distinctive keywords in this single call. Every keyword must contain at least two Unicode characters. Each result includes truncated and totalCharacters fields: truncated is true when the snippet is clipped to a character limit (clipped parts are marked with '...'), and totalCharacters is the record's full length.",
            parameters: keyword_parameters("daily-note"),
            strict: true,
        },
        AiToolDefinition {
            name: "search_weekly_notes",
            description: "Search only SpringNote weekly Markdown reports. Use this instead of keyword_search when the request is limited to weekly reports. Submit all distinctive keywords in this single call. Every keyword must contain at least two Unicode characters. Each result includes truncated and totalCharacters fields: truncated is true when the snippet is clipped to a character limit (clipped parts are marked with '...'), and totalCharacters is the record's full length.",
            parameters: keyword_parameters("weekly-report"),
            strict: true,
        },
        AiToolDefinition {
            name: "search_monthly_notes",
            description: "Search only SpringNote monthly Markdown reports. Use this instead of keyword_search when the request is limited to monthly reports. Submit all distinctive keywords in this single call. Every keyword must contain at least two Unicode characters. Each result includes truncated and totalCharacters fields: truncated is true when the snippet is clipped to a character limit (clipped parts are marked with '...'), and totalCharacters is the record's full length.",
            parameters: keyword_parameters("monthly-report"),
            strict: true,
        },
        AiToolDefinition {
            name: "read_daily_note",
            description: "Read the daily Markdown note for a specific date. The result includes truncated and totalCharacters fields: truncated is true when the snippet is clipped to a character limit (clipped parts are marked with '...'), and totalCharacters is the record's full length.",
            parameters: json!({
                "type": "object",
                "properties": {
                    "date": {
                        "type": "string",
                        "description": "The date in YYYY-MM-DD format.",
                        "pattern": DATE_PATTERN
                    }
                },
                "required": ["date"],
                "additionalProperties": false
            }),
            strict: true,
        },
        AiToolDefinition {
            name: "read_week_daily_notes",
            description: "Read all available daily notes in a date range, typically one week. Each result includes truncated and totalCharacters fields: truncated is true when the snippet is clipped to a character limit (clipped parts are marked with '...'), and totalCharacters is the record's full length.",
            parameters: json!({
                "type": "object",
                "properties": {
                    "startDate": {
                        "type": "string",
                        "description": "Range start date in YYYY-MM-DD format.",
                        "pattern": DATE_PATTERN
                    },
                    "endDate": {
                        "type": "string",
                        "description": "Range end date in YYYY-MM-DD format.",
                        "pattern": DATE_PATTERN
                    }
                },
                "required": ["startDate", "endDate"],
                "additionalProperties": false
            }),
            strict: true,
        },
        AiToolDefinition {
            name: "read_weekly_note",
            description: "Read only the SpringNote weekly report Markdown for a specific ISO week. Do not return daily notes. The result includes truncated and totalCharacters fields: truncated is true when the snippet is clipped to a character limit (clipped parts are marked with '...'), and totalCharacters is the record's full length.",
            parameters: json!({
                "type": "object",
                "properties": {
                    "week": {
                        "type": "string",
                        "description": "The ISO week in YYYY-Www format, for example 2026-W28.",
                        "pattern": WEEK_PATTERN
                    }
                },
                "required": ["week"],
                "additionalProperties": false
            }),
            strict: true,
        },
        AiToolDefinition {
            name: "read_month_weekly_notes",
            description: "Read all available SpringNote weekly report Markdown files whose ISO weeks overlap a specific calendar month. Return weekly reports only, not daily notes or the monthly report. Each result includes truncated and totalCharacters fields: truncated is true when the snippet is clipped to a character limit (clipped parts are marked with '...'), and totalCharacters is the record's full length.",
            parameters: json!({
                "type": "object",
                "properties": {
                    "month": {
                        "type": "string",
                        "description": "The calendar month in YYYY-MM format.",
                        "pattern": MONTH_PATTERN
                    }
                },
                "required": ["month"],
                "additionalProperties": false
            }),
            strict: true,
        },
        AiToolDefinition {
            name: "read_month_report",
            description: "Read only the monthly report Markdown for a specific month. Do not return daily notes. The result includes truncated and totalCharacters fields: truncated is true when the snippet is clipped to a character limit (clipped parts are marked with '...'), and totalCharacters is the record's full length.",
            parameters: json!({
                "type": "object",
                "properties": {
                    "month": {
                        "type": "string",
                        "description": "The month in YYYY-MM format.",
                        "pattern": MONTH_PATTERN
                    }
                },
                "required": ["month"],
                "additionalProperties": false
            }),
            strict: true,
        },
    ]
}

/// 关键词搜索工具的参数 Schema；scope 用于区分全局与各类型记录的描述文案。
fn keyword_parameters(scope: &str) -> Value {
    json!({
        "type": "object",
        "properties": {
            "keywords": {
                "type": "array",
                "description": format!("All concise keywords or phrases needed for one {scope} search, sorted by importance."),
                "minItems": 1,
                "maxItems": 8,
                "items": {
                    "type": "string",
                    "description": "A concise keyword or phrase containing at least two Unicode characters.",
                    "minLength": 2
                }
            }
        },
        "required": ["keywords"],
        "additionalProperties": false
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn memory_tools_have_unique_names_and_object_parameters() {
        let tools = memory_tools();
        assert_eq!(tools.len(), 10);
        let mut names = std::collections::HashSet::new();
        for tool in &tools {
            assert!(
                names.insert(tool.name),
                "duplicate tool name: {}",
                tool.name
            );
            assert!(!tool.description.is_empty());
            assert!(tool.parameters.is_object());
            assert!(tool.strict);
        }
    }

    #[test]
    fn memory_tools_keep_stable_order() {
        let names = memory_tools()
            .iter()
            .map(|tool| tool.name)
            .collect::<Vec<_>>();
        assert_eq!(
            names,
            vec![
                "get_current_date",
                "keyword_search",
                "search_daily_notes",
                "search_weekly_notes",
                "search_monthly_notes",
                "read_daily_note",
                "read_week_daily_notes",
                "read_weekly_note",
                "read_month_weekly_notes",
                "read_month_report",
            ]
        );
    }

    #[test]
    fn keyword_search_schema_constrains_keywords() {
        let tools = memory_tools();
        let keyword_search = &tools[1];
        assert_eq!(keyword_search.name, "keyword_search");
        assert_eq!(keyword_search.parameters["required"][0], "keywords");
        assert_eq!(keyword_search.parameters["additionalProperties"], false);
        let keywords = &keyword_search.parameters["properties"]["keywords"];
        assert_eq!(keywords["minItems"], 1);
        assert_eq!(keywords["maxItems"], 8);
        assert_eq!(keywords["items"]["minLength"], 2);
        assert!(keyword_search
            .description
            .contains("prefer a scoped search"));
        assert!(keyword_search
            .description
            .contains("submit all distinctive keywords in this single call"));
    }

    #[test]
    fn date_week_month_parameters_carry_format_patterns() {
        let tools = memory_tools();
        assert_eq!(tools[0].name, "get_current_date");
        assert!(tools[0].description.contains("ISO week"));
        assert_eq!(
            tools[5].parameters["properties"]["date"]["pattern"],
            DATE_PATTERN
        );
        assert_eq!(tools[6].parameters["required"][0], "startDate");
        assert_eq!(tools[7].parameters["required"][0], "week");
        assert_eq!(tools[8].parameters["required"][0], "month");
        assert_eq!(
            tools[8].parameters["properties"]["month"]["pattern"],
            MONTH_PATTERN
        );
    }
}
