#!/usr/bin/env python3
"""把 lib/l10n/fragments/*.json 合并为 app_zh.arb / app_en.arb。

文案工作流：
1. 在 lib/l10n/fragments/ 对应模块的 _zh.json / _en.json 中新增或修改文案
   （同一 key 的 zh/en 都要维护，占位符 {xxx} 两侧必须一致）。
2. 运行 `python tool/merge_l10n_fragments.py` 重新生成 arb 文件。
   合并是"就地更新"：已有 key 保持 arb 中原有的位置和值（以 fragment 为准），
   新 key 按 fragment 顺序追加到 arb 末尾，保证 diff 最小。
3. 运行 `flutter gen-l10n`（或 `flutter pub get` / 构建时自动触发）重新生成
   lib/l10n/app_localizations*.dart。

校验规则（违反即报错退出）：
- 同一 key 不允许出现在多个 fragment 中（避免合并结果依赖文件顺序）。
- arb 中不允许存在 fragment 没有的 key（否则重新生成会丢文案）。
- zh 与 en 的 key 集合、每个 key 的占位符集合必须一致。

`--check`：不写文件，仅校验 arb 是否与 fragments 同步（用于 CI）。
"""

from __future__ import annotations

import json
import re
import sys
from collections import OrderedDict
from pathlib import Path

L10N_DIR = Path(__file__).resolve().parent.parent / 'lib' / 'l10n'
FRAGMENT_MODULES = ['core', 'home', 'memory', 'notes', 'settings', 'settings_b']
LOCALES = ['zh', 'en']

PLACEHOLDER_RE = re.compile(r'\{(\w+)\}')


def load_json(path: Path) -> OrderedDict:
    with path.open(encoding='utf-8') as f:
        return json.load(f, object_pairs_hook=OrderedDict)


def write_json(path: Path, data: OrderedDict) -> None:
    with path.open('w', encoding='utf-8', newline='\n') as f:
        f.write(json.dumps(data, ensure_ascii=False, indent=2) + '\n')


def load_fragments(locale: str) -> OrderedDict:
    """按模块顺序加载 fragments，重复 key 直接报错。"""
    merged: OrderedDict[str, str] = OrderedDict()
    for module in FRAGMENT_MODULES:
        path = L10N_DIR / 'fragments' / f'{module}_{locale}.json'
        for key, value in load_json(path).items():
            if key.startswith('@'):
                continue
            if key in merged:
                sys.exit(f'错误：key "{key}" 在多个 fragment 中重复（{module}_{locale}.json）')
            merged[key] = value
    return merged


def merge(locale: str, check: bool) -> bool:
    """返回 arb 与 fragments 是否已同步。"""
    fragments = load_fragments(locale)
    arb_path = L10N_DIR / f'app_{locale}.arb'
    arb = load_json(arb_path)

    missing = [key for key in arb if not key.startswith('@') and key not in fragments]
    if missing:
        sys.exit(f'错误：app_{locale}.arb 中存在 fragments 没有的 key：{missing}')

    result: OrderedDict[str, object] = OrderedDict()
    changed: list[str] = []
    for key, value in arb.items():
        if key.startswith('@'):
            result[key] = value
            continue
        if value != fragments[key]:
            changed.append(key)
        result[key] = fragments[key]
    appended = [key for key in fragments if key not in arb]
    for key in appended:
        result[key] = fragments[key]

    if not changed and not appended:
        return True
    if check:
        print(f'app_{locale}.arb 未同步：值变化 {changed}，新增 {appended}')
        return False
    write_json(arb_path, result)
    print(f'app_{locale}.arb：更新 {len(changed)} 个值，追加 {len(appended)} 个 key')
    return True


def main() -> None:
    check = '--check' in sys.argv[1:]

    zh = load_fragments('zh')
    en = load_fragments('en')
    if list(zh) != list(en):
        only_zh = [k for k in zh if k not in en]
        only_en = [k for k in en if k not in zh]
        sys.exit(f'错误：zh/en key 集合不一致，仅 zh：{only_zh}，仅 en：{only_en}')
    for key in zh:
        ph_zh = sorted(PLACEHOLDER_RE.findall(zh[key]))
        ph_en = sorted(PLACEHOLDER_RE.findall(en[key]))
        if ph_zh != ph_en:
            sys.exit(f'错误：key "{key}" 占位符不一致，zh={ph_zh}，en={ph_en}')

    ok = all(merge(locale, check) for locale in LOCALES)
    if not ok:
        sys.exit(1)
    print('arb 与 fragments 已同步' if check else '合并完成')


if __name__ == '__main__':
    main()
