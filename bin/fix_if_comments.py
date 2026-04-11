#!/usr/bin/env python3
"""
fix_if_comments.py - C/C++ ファイルの #else / #endif コメントと
Linux/Windows 二択分岐を標準化する。

【規則】
  #ifndef MACRO ... #else /* MACRO */  ... #endif /* MACRO */
  #ifdef  MACRO ... #else /* !MACRO */ ... #endif /* MACRO */

  #if defined(MACRO) ... #endif /* MACRO */
  #if defined(MACRO) ... #else /* !MACRO */ ... #endif /* MACRO */

  #if defined(PLATFORM_LINUX) ... #elif defined(PLATFORM_WINDOWS) ... #endif /* PLATFORM_ */

  - Linux/Windows 二択分岐は #else /* PLATFORM_WINDOWS */ ではなく
    #elif defined(PLATFORM_WINDOWS) に統一する
  - コメントには ifdef/ifndef キーワードは含めない（マクロ名または !マクロ名のみ）
  - 単一マクロの #if defined(MACRO) は #ifdef 相当として #endif にコメントする
  - 単純な #elif defined(MACRO) だけで構成される #if defined() チェーンは、
    共通接頭辞があれば #endif にコメントする
  - 複合条件を含む #elif チェーンの #else / #endif にはコメントしない
  - #if EXPR（複雑な式）のブロックは変更しない

【使い方】
  python framework/makefw/bin/fix_if_comments.py [--dry-run] <path>...

  --dry-run  ファイルを変更せず、差分のみ表示する
  <path>     ファイルまたはディレクトリ（複数指定可）
             ディレクトリ指定時は .c / .h / .cc / .hpp を再帰的に処理
"""

import argparse
import difflib
import os
import re
import sys
from pathlib import Path


_RE_IF = re.compile(r'^(\s*)#\s*(ifdef|ifndef)\s+(\w+)\s*(?:/\*.*\*/)?\s*$')
_RE_IF_DEFINED = re.compile(r'^(\s*)#\s*if\s+defined\s*\(\s*(\w+)\s*\)\s*(?:/\*.*\*/)?\s*$')
_RE_ELIF_DEFINED = re.compile(r'^(\s*)#\s*elif\s+defined\s*\(\s*(\w+)\s*\)\s*(?:/\*.*\*/)?\s*$')
_RE_ELIF = re.compile(r'^(\s*)#\s*elif\b')
_RE_IF_GENERIC = re.compile(r'^(\s*)#\s*if\b')
_RE_ELSE = re.compile(r'^(\s*)#\s*else\b(.*)')
_RE_ENDIF = re.compile(r'^(\s*)#\s*endif\b(.*)')


def _strip_comment(tail):
    """末尾の /* ... */ コメント内容を返す。なければ None。"""
    match = re.match(r'\s*/\*\s*(.*?)\s*\*/\s*$', tail)
    return match.group(1) if match else None


def _common_macro_prefix(macros):
    """複数マクロの意味のある共通接頭辞を返す。なければ None。"""
    if len(macros) < 2:
        return None

    prefix = macros[0]
    for macro in macros[1:]:
        limit = min(len(prefix), len(macro))
        index = 0
        while index < limit and prefix[index] == macro[index]:
            index += 1
        prefix = prefix[:index]
        if not prefix:
            return None

    boundary = prefix.rfind('_')
    if boundary < 0:
        return None

    prefix = prefix[:boundary + 1]
    return prefix if prefix.strip('_') else None


def analyze(lines):
    """ファイルの行リストを解析し、修正が必要な行を返す。"""
    stack = []
    else_info = {}
    endif_info = {}

    for index, line in enumerate(lines):
        match = _RE_IF.match(line)
        if match:
            kind = match.group(2)
            macro = match.group(3)
            stack.append(
                {
                    'kind': kind,
                    'macro': macro,
                    'macros': [],
                    'has_else': False,
                    'has_elif': False,
                    'complex_elif': False,
                }
            )
            continue

        match = _RE_IF_DEFINED.match(line)
        if match:
            stack.append(
                {
                    'kind': 'if_defined',
                    'macro': '',
                    'macros': [match.group(2)],
                    'has_else': False,
                    'has_elif': False,
                    'complex_elif': False,
                }
            )
            continue

        if _RE_IF_GENERIC.match(line) and not _RE_IF.match(line) and not _RE_IF_DEFINED.match(line):
            stack.append(
                {
                    'kind': 'if',
                    'macro': '',
                    'macros': [],
                    'has_else': False,
                    'has_elif': False,
                    'complex_elif': False,
                }
            )
            continue

        match = _RE_ELIF_DEFINED.match(line)
        if match and stack:
            top = stack[-1]
            if top['kind'] == 'if_defined':
                top['has_elif'] = True
                top['macros'].append(match.group(2))
            continue

        if _RE_ELIF.match(line) and stack:
            top = stack[-1]
            if top['kind'] == 'if_defined':
                top['has_elif'] = True
                top['complex_elif'] = True
            continue

        match = _RE_ELSE.match(line)
        if match and stack:
            top = stack[-1]
            top['has_else'] = True
            else_info[index] = (
                top['kind'],
                top['macro'],
                top['macros'],
                top['has_elif'],
                top['complex_elif'],
            )
            continue

        match = _RE_ENDIF.match(line)
        if match and stack:
            top = stack.pop()
            endif_info[index] = (
                top['kind'],
                top['macro'],
                top['has_else'],
                top['macros'],
                top['has_elif'],
                top['complex_elif'],
            )
            continue

    fixes = {}

    for index, (kind, macro, macros, has_elif, complex_elif) in else_info.items():
        line = lines[index]
        match = _RE_ELSE.match(line)
        indent = match.group(1)
        tail = match.group(2)
        current_comment = _strip_comment(tail)

        if kind in ('ifdef', 'ifndef'):
            expected = macro if kind == 'ifndef' else '!' + macro
            if current_comment != expected:
                fixes[index] = f'{indent}#else /* {expected} */\n'
        elif kind == 'if_defined':
            if complex_elif:
                if current_comment is not None:
                    fixes[index] = f'{indent}#else\n'
                continue

            if macros == ['PLATFORM_LINUX'] and current_comment == 'PLATFORM_WINDOWS':
                fixes[index] = f'{indent}#elif defined(PLATFORM_WINDOWS)\n'
                continue

            expected = ' && '.join('!' + entry for entry in macros) if has_elif else '!' + macros[0]
            if current_comment != expected:
                fixes[index] = f'{indent}#else /* {expected} */\n'

    for index, (kind, macro, _has_else, macros, has_elif, complex_elif) in endif_info.items():
        line = lines[index]
        match = _RE_ENDIF.match(line)
        indent = match.group(1)
        tail = match.group(2)
        current_comment = _strip_comment(tail)

        if kind in ('ifdef', 'ifndef'):
            expected = macro
            if current_comment != expected:
                fixes[index] = f'{indent}#endif /* {expected} */\n'
        elif kind == 'if_defined':
            if complex_elif:
                if current_comment is not None:
                    fixes[index] = f'{indent}#endif\n'
                continue

            if has_elif:
                expected = _common_macro_prefix(macros)
                if expected is None:
                    if current_comment is not None:
                        fixes[index] = f'{indent}#endif\n'
                elif current_comment != expected:
                    fixes[index] = f'{indent}#endif /* {expected} */\n'
            else:
                expected = macros[0]
                if current_comment != expected:
                    fixes[index] = f'{indent}#endif /* {expected} */\n'

    return fixes


def process_file(path, dry_run):
    """1 ファイルを処理し、変更数を返す。"""
    try:
        with open(path, 'r', encoding='utf-8') as file:
            lines = file.readlines()
    except UnicodeDecodeError:
        with open(path, 'r', encoding='latin-1') as file:
            lines = file.readlines()

    fixes = analyze(lines)
    if not fixes:
        return 0

    new_lines = list(lines)
    for index, new_line in fixes.items():
        new_lines[index] = new_line

    rel_path = os.path.relpath(path)
    diff = difflib.unified_diff(
        lines,
        new_lines,
        fromfile=f'a/{rel_path}',
        tofile=f'b/{rel_path}',
    )
    for line in diff:
        sys.stdout.write(line)

    if not dry_run:
        try:
            with open(path, 'w', encoding='utf-8') as file:
                file.writelines(new_lines)
        except OSError as exc:
            print(f'ERROR writing {path}: {exc}', file=sys.stderr)
            return 0

    return len(fixes)


def collect_files(paths):
    """パスリストから C/C++ ソースとヘッダを収集する。"""
    result = []
    seen = set()
    patterns = ('*.c', '*.h', '*.cc', '*.hpp')

    for raw_path in paths:
        path = Path(raw_path)
        if path.is_file():
            resolved = path.resolve()
            if resolved not in seen:
                result.append(path)
                seen.add(resolved)
            continue

        if path.is_dir():
            for pattern in patterns:
                for candidate in sorted(path.rglob(pattern)):
                    resolved = candidate.resolve()
                    if resolved not in seen:
                        result.append(candidate)
                        seen.add(resolved)
            continue

        print(f'WARNING: {path} は存在しません', file=sys.stderr)

    return result


def main():
    parser = argparse.ArgumentParser(
        description='#else / #endif コメントを標準化する',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument(
        '--dry-run',
        action='store_true',
        help='ファイルを変更せず差分のみ表示する',
    )
    parser.add_argument(
        'paths',
        nargs='+',
        metavar='PATH',
        help='処理するファイルまたはディレクトリ',
    )
    args = parser.parse_args()

    files = collect_files(args.paths)
    if not files:
        print('対象ファイルが見つかりません', file=sys.stderr)
        return 1

    total_files = 0
    total_fixes = 0

    for file in files:
        fix_count = process_file(file, dry_run=args.dry_run)
        if fix_count:
            total_files += 1
            total_fixes += fix_count

    mode = '(dry-run) ' if args.dry_run else ''
    suffix = '修正予定' if args.dry_run else '修正済み'
    print(f'\n{mode}{total_files} ファイル / {total_fixes} 箇所 {suffix}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
