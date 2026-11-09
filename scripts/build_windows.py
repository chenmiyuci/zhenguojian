import argparse
import os
import shutil
import subprocess
import sys
import tempfile
import time
import zipfile
from pathlib import Path

from app_build import BuildVariant, add_variant_argument

FFMPEGKIT_VERSION = '8.1.2'
FFMPEGKIT_PACKAGE = 'min-gpl'
FFMPEGKIT_ARCH = 'x86_64'
FFMPEGKIT_WANT = f'{FFMPEGKIT_VERSION}-{FFMPEGKIT_PACKAGE} layout=3'
FFMPEGKIT_URL = ('https://github.com/sk3llo/ffmpeg_kit_flutter/releases/download/'
                 f'{FFMPEGKIT_VERSION}-{FFMPEGKIT_PACKAGE}/'
                 f'ffmpeg-kit-windows-{FFMPEGKIT_ARCH}-{FFMPEGKIT_PACKAGE}-{FFMPEGKIT_VERSION}.zip')

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
add_variant_argument(parser)
options = parser.parse_args()
variant = BuildVariant(options.all_sources)
env = os.environ.copy()
env.setdefault('GOPROXY', 'https://goproxy.cn,direct')
env.setdefault('GOSUMDB', 'off')
flutter = shutil.which('flutter')
if not flutter:
    raise SystemExit('请先将 Flutter SDK 的 bin 目录加入 PATH。')


def download_with_retry(url, target):
    for attempt in range(5):
        result = subprocess.run(['curl', '-fL', '--connect-timeout', '30', '-o', str(target), url],
                                capture_output=True, text=True)
        if result.returncode == 0 and target.is_file() and target.stat().st_size > 0:
            return True
        print(f'第 {attempt + 1} 次下载失败（curl {result.returncode}），稍后重试…', flush=True)
        time.sleep(5 * (attempt + 1))
    return False


def preheat_ffmpegkit():
    # ponytail: GitHub runner 下载 release 资产常 504，先带重试下载解压到 CMake
    # 的 prebuilt 目录并写好 marker，CMake 检测 marker 匹配即跳过下载；上游改
    # 版本时同步更新常量。
    plugin = root / 'windows' / 'flutter' / 'ephemeral' / 'plugins' / 'ffmpeg_kit_flutter_new_min_gpl'
    if not plugin.is_dir():
        return
    prebuilt = plugin / 'ffmpeg-kit'
    marker = prebuilt / 'bin' / '.ffmpegkit_variant'
    if marker.is_file() and marker.read_text(encoding='utf-8', errors='replace').strip() == FFMPEGKIT_WANT:
        return
    with tempfile.TemporaryDirectory(prefix='ffmpegkit-') as work:
        archive = Path(work) / 'ffmpegkit.zip'
        if not download_with_retry(FFMPEGKIT_URL, archive):
            return
        try:
            with zipfile.ZipFile(archive) as bundle:
                bundle.extractall(prebuilt)
        except zipfile.BadZipFile:
            print('ffmpeg_kit 下载内容不是有效 zip，放弃预热。', flush=True)
            shutil.rmtree(prebuilt, ignore_errors=True)
            return
        if not list(prebuilt.glob('bin/*.dll')):
            print('ffmpeg_kit 包缺少 bin/*.dll，放弃预热。', flush=True)
            shutil.rmtree(prebuilt, ignore_errors=True)
            return
        marker.parent.mkdir(parents=True, exist_ok=True)
        marker.write_text(FFMPEGKIT_WANT + '\n', encoding='utf-8')
        print('ffmpeg_kit Windows 预构建已预热。', flush=True)


subprocess.run([sys.executable, str(root / 'scripts' / 'build_native.py'), '--platform', 'windows', *variant.arguments],
               cwd=root, env=env, check=True)
subprocess.run([flutter, 'pub', 'get', '--enforce-lockfile'], cwd=root, env=env, check=True)
preheat_ffmpegkit()
subprocess.run([flutter, 'build', 'windows', '--release', '--no-pub', *variant.flutter_arguments], cwd=root, env=env, check=True)
subprocess.run([sys.executable, str(root / 'scripts' / 'package_release.py'), '--platform', 'windows', *variant.arguments],
               cwd=root, env=env, check=True)
