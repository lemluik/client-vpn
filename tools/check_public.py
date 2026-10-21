"""Гейт публичного репозитория для прогона в CI.

Проверяет структуру, а не список нашего оборудования: имена наших узлов, домен и
имя бота вносить в этот репозиторий нельзя — сам такой список и был бы утечкой.
Полный гейт нейтральности с именами живёт вне репозитория и запускается локально
перед каждым коммитом. Здесь проверяется то, что обнаруживается, ничего не
называя: чужие письменности в текстах, литеральные публичные адреса, живые
секреты, пути рабочей машины разработчика и новые git-идентичности в истории.

Дополнительный список шаблонов можно передать переменной окружения
NEUTRAL_EXTRA_PATTERNS (regex по строке, каждый с новой линии) — значения тогда
живут в секретах репозитория, а не в его файлах.

Запуск:
    python tools/check_public.py                       # всё дерево
    python tools/check_public.py --commits --base SHA  # плюс проверка истории
    python tools/check_public.py --tag v0.4.1          # плюс сверка версии с тегом

Код возврата 1, если есть хоть одна находка. Значения печатаются маской.
"""
import io
import os
import re
import subprocess
import sys

SKIP_DIRS = {'.git', 'build', '.dart_tool', '.idea', '__pycache__', 'node_modules',
             '.gradle', 'ephemeral', 'Pods', '.symlinks'}
SKIP_NAMES = {'check_public.py', 'pubspec.lock', 'desktop.ini'}
TEXT_EXT = ('.md', '.txt', '.json', '.yaml', '.yml', '.dart', '.kt', '.java', '.xml',
            '.gradle', '.kts', '.properties', '.sh', '.ps1', '.bat', '.h', '.cpp',
            '.cmake', '.arb', '.swift', '.plist', '.html', '.css', '.js', '.ts',
            '.storyboard', '.xcconfig', '.inf', '.cfg', '.ini', '.toml')
MAX_FILE = 5 * 1024 * 1024

# петлевые, широковещательные, общественные DNS и диапазоны RFC 5737 из документации
ALLOWED_IP = {'0.0.0.0', '127.0.0.1', '255.255.255.255', '1.1.1.1',
              '8.8.8.8', '8.8.4.4', '9.9.9.9', '192.0.2.1', '198.51.100.1', '203.0.113.1'}
RESERVED_IP = re.compile(r'^(?:10\.|127\.|192\.168\.|172\.(?:1[6-9]|2\d|3[01])\.|'
                         r'198\.51\.100\.|203\.0\.113\.|192\.0\.2\.|224\.|240\.)')
IPV4 = re.compile(r'\b(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\b')
# авторы, которые считаются известными, даже если их ещё нет в истории base;
# только адреса GitHub noreply, без личной почты
KNOWN_AUTHORS = {
    'Daniil A <140379757+daniilprodev@users.noreply.github.com>',
}
# адрес считаем адресом только в контексте, где ему неоткуда быть версией пакета
ADDRESS_CONTEXT = re.compile(r'(?:://|:\d{2,5}\b|\baddress\b|\bhost\b|\bserver\b|\bpeer\b|'
                             r'\bip\b|\bipv4\b|\bconnect\b|\bendpoint\b)', re.I)

PATTERNS = [
    ('токен telegram-бота', re.compile(r'\b\d{8,12}:[A-Za-z0-9_-]{30,}')),
    ('закрытый ключ pem', re.compile(r'BEGIN [A-Z ]*PRIVATE KEY')),
    ('ключ x25519 в присваивании',
     re.compile(r'(?:private_?key|privateKey|secret|приватн\w*)\D{0,4}["\']?([A-Za-z0-9+/_-]{43})["\']?')),
    ('hex-ключ 32 байта', re.compile(r'(?:seed|key|secret|token)\D{0,4}([0-9a-fA-F]{64})\b')),
    ('пароль или токен значением',
     re.compile(r'(?:api_?key|api_?token|password|passwd|secret|token|пароль|ключ)["\']?\s*[:=]\s*["\']?([A-Za-z0-9_+/=\-]{20,})["\']?', re.I)),
]
PLACEHOLDER = re.compile(r'^(?:x{3,}|y{3,})$|[<{$]|\.{3}|(?:не задан|измените|замените|маска)', re.I)
# имена в коде, а не значения: вызов, тип или константа. Объявление само по себе
# не оправдание — `const token = '…'` и есть то, что гейт обязан поймать.
# Идентификатором считаем слово без символов, где цифр не больше пятой части:
# живой ключ от отличает как раз плотность цифр и знаков.
CAMEL = re.compile(r'[A-Za-z_][A-Za-z0-9]*(?:[A-Z][a-z0-9]*)+')


def looks_like_code(value, tail, line):
    if ':' in value:
        # в идентификаторе двоеточия не бывает — токен бота или address:port
        return False
    if tail[:1] in ('(', '.', '=', ',', ':'):
        return True
    digits = sum(c.isdigit() for c in value)
    if CAMEL.fullmatch(value) and digits <= len(value) * 0.2:
        return True
    if value.isupper():
        return True
    return False

# пути рабочей машины разработчика в текстах быть не должно
DEV_PATH = re.compile(r'[A-Za-z]:[\\/]{1,2}[Uu]sers[\\/]|/home/[a-z0-9._-]{2,}/|/Users/[a-z0-9._-]{2,}/')
# у проекта в текстах только кириллица, латиница и символы разметки
FOREIGN_SCRIPT = re.compile(r'[\u3040-\u30ff\u3400-\u4dbf\u4e00-\u9fff\uac00-\ud7af\u0600-\u06ff'
                            r'\u0e00-\u0e7f\u0590-\u05ff\u1100-\u11ff]')
# заявление «без сбора статистики» (позиция 16 §20.1) проверяется по графу зависимостей
TELEMETRY = re.compile(
    r'^(?:firebase_analytics|firebase_crashlytics|firebase_performance|sentry|sentry_flutter|'
    r'posthog|matomo_piwik|amplitude|segment_analytics|appcenter|appsflyer_sdk|mixpanel|'
    r'countly_sdk|yandex_metrica|google_measurement|plausible|bugsnag|newrelic|datadog|'
    r'telemetrics|telemetry|adjust|branch_sdk)\S*$')


def mask(value):
    return value[:4] + '*' * min(12, max(4, len(value) - 4))


def extra_patterns():
    raw = os.environ.get('NEUTRAL_EXTRA_PATTERNS', '')
    out = []
    for line in raw.split('\n'):
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        try:
            out.append(('шаблон из секрета', re.compile(line)))
        except re.error:
            out.append(('шаблон из секрета', re.compile(re.escape(line))))
    return out


def git_ignored(root):
    """Файлы, которые git не публикует: локальный ключ подписи, кэши, артефакты.

    Гейт ловит то, что может уйти в открытый репозиторий, поэтому проигнорированные
    git файлы он не читает. Добавленный силой (`git add -f`) файл перестаёт быть
    «прочим» и снова попадает в проверку; без git сканируется всё дерево.
    """
    try:
        out = subprocess.run(
            ['git', 'ls-files', '--others', '--ignored', '--exclude-standard'],
            cwd=root, capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.SubprocessError):
        return set()
    if out.returncode != 0:
        return set()
    return {line.strip() for line in out.stdout.split('\n') if line.strip()}


def text_files(root):
    ignored = git_ignored(root)
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS)
        for name in sorted(filenames):
            if name in SKIP_NAMES or not name.endswith(TEXT_EXT):
                continue
            path = os.path.join(dirpath, name)
            if os.path.relpath(path, root).replace(os.sep, '/') in ignored:
                continue
            if os.path.getsize(path) > MAX_FILE:
                continue
            try:
                yield path, io.open(path, encoding='utf-8').read()
            except UnicodeDecodeError:
                # не читается как UTF-8 — декодируем обратимо, чтобы находку не потерять
                yield path, io.open(path, encoding='latin-1').read()


def check_files(root):
    patterns = PATTERNS + extra_patterns()
    findings = []
    for path, text in text_files(root):
        rel = os.path.relpath(path, root).replace(os.sep, '/')
        for num, line in enumerate(text.split('\n'), 1):
            for name, pattern in patterns:
                for found in pattern.finditer(line):
                    value = found.group(found.lastindex or 0) if found.lastindex else found.group(0)
                    if PLACEHOLDER.search(value) or looks_like_code(value, line[found.end():], line):
                        continue
                    findings.append(f'{rel}:{num}: {name}: {mask(value)}')
            for found in IPV4.finditer(line):
                ip = found.group(1)
                if ip in ALLOWED_IP or RESERVED_IP.match(ip):
                    continue
                if not ADDRESS_CONTEXT.search(line):
                    continue
                findings.append(f'{rel}:{num}: публичный ipv4: {mask(ip)}')
            if DEV_PATH.search(line):
                findings.append(f'{rel}:{num}: путь рабочей машины разработчика')
            if FOREIGN_SCRIPT.search(line):
                findings.append(f'{rel}:{num}: посторонняя письменность в тексте')
    return findings


def check_history(base):
    """Коммит, автор которого не появлялся в base и не указан в KNOWN_AUTHORS, —
    это новая идентификация."""
    if not base:
        return []
    current = subprocess.run(['git', 'log', '--format=%an <%ae>', f'{base}..HEAD'],
                             capture_output=True, text=True)
    known = subprocess.run(['git', 'log', '--format=%an <%ae>', base],
                           capture_output=True, text=True)
    if current.returncode != 0 or known.returncode != 0:
        return ['git log не выполнен — историю проверить нечем']
    fresh = sorted(set(current.stdout.split('\n')) - set(known.stdout.split('\n'))
                   - KNOWN_AUTHORS - {''})
    return [f'новая git-идентичность: {mask(x)}' for x in fresh]


def check_dependencies(root):
    """Позиция 16 (§20.1): «без сбора статистики» должно подтверждаться кодом.

    Заявление на экране «О программе» стоит столько, сколько стоит проверка:
    если в графе зависимостей появится аналитика, crash-репортер или телеметрия,
    гейт падает и релиз не собирается.
    """
    findings = []
    for rel in ('pubspec.yaml', 'pubspec.lock'):
        path = os.path.join(root, rel)
        if not os.path.exists(path):
            continue
        with io.open(path, encoding='utf-8') as handle:
            for num, line in enumerate(handle, 1):
                name = line.strip().rstrip(':')
                if TELEMETRY.match(name):
                    findings.append(
                        f'{rel}:{num}: телеметрия или аналитика в зависимостях: {name}')
    return findings


VERSION_CONST = re.compile(r"const String clientVersion = '([^']+)'")


def read_version(path, prefix=None, pattern=None):
    with io.open(path, encoding='utf-8') as handle:
        for line in handle:
            if prefix and line.startswith(prefix):
                return line.split(':', 1)[1].strip().split('+')[0]
            if pattern:
                found = pattern.match(line.strip())
                if found:
                    return found.group(1)
    return None


def check_version(root, tag):
    """Версия сборки и имя тега — одно и то же число.

    Тег v0.4.0 был собран с `version: 0.3.0` в pubspec.yaml и `clientVersion =
    '0.3.0'` на экране «О программе», из-за чего каждая установленная 0.4.0
    считала себя 0.3.0 и предлагала обновиться до самой себя. Сверка clientVersion
    с pubspec есть в test/about_test.dart, но тег не проверял никто.
    """
    findings = []
    pubspec = os.path.join(root, 'pubspec.yaml')
    about = os.path.join(root, 'lib', 'about_screen.dart')
    for path in (pubspec, about):
        if not os.path.exists(path):
            return [f'{os.path.relpath(path, root)}: файла нет, версию сверить нечем']
    version = read_version(pubspec, prefix='version:')
    if not version:
        return ['pubspec.yaml: строка version: не найдена']
    const = read_version(about, pattern=VERSION_CONST)
    if const is None:
        findings.append('lib/about_screen.dart: clientVersion не найден')
    elif const != version:
        findings.append(f'clientVersion {const} != версия в pubspec.yaml {version}')
    if tag:
        expected = tag[1:] if tag.startswith('v') else tag
        if expected != version:
            findings.append(f'тег {tag} != версия сборки {version}')
    return findings


def main(argv):
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    base = argv[argv.index('--base') + 1] if '--base' in argv else None
    tag = argv[argv.index('--tag') + 1] if '--tag' in argv else None
    findings = check_files(root) + check_dependencies(root) + check_version(root, tag)
    if '--commits' in argv:
        findings += check_history(base)
    for line in findings:
        print(line)
    print(f'находок: {len(findings)}')
    return 1 if findings else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
