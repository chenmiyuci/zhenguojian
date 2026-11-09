import argparse
import os
import platform
import shutil
import subprocess
import sys
from pathlib import Path

from app_build import BuildVariant, add_variant_argument

root = Path(__file__).resolve().parents[1]


def run(arguments, env, cwd=root):
    print('+ ' + ' '.join(str(item) for item in arguments), flush=True)
    subprocess.run([str(item) for item in arguments], cwd=cwd, env=env, check=True)


def developer_directory():
    configured = os.environ.get('DEVELOPER_DIR')
    if configured and Path(configured).is_dir():
        return Path(configured)
    selected = subprocess.run(['xcode-select', '-p'], capture_output=True,
                              text=True).stdout.strip()
    if selected.endswith('.app/Contents/Developer'):
        return Path(selected)
    for candidate in sorted(Path('/Applications').glob('Xcode*.app')):
        developer = candidate / 'Contents' / 'Developer'
        if developer.is_dir():
            return developer
    raise SystemExit('需要完整 Xcode：安装后执行 '
                     'sudo xcode-select -s /Applications/Xcode.app/Contents/Developer')


def toolchain_environment(developer):
    env = os.environ.copy()
    env['DEVELOPER_DIR'] = str(developer)
    env.setdefault('GOPROXY', 'https://goproxy.cn,direct')
    env.setdefault('GOSUMDB', 'off')
    shim = root / 'build' / 'macos-toolchain' / 'bin'
    shim.mkdir(parents=True, exist_ok=True)
    script = shim / 'xcrun'
    script.write_text(f'#!/bin/sh\nDEVELOPER_DIR="{developer}" exec /usr/bin/xcrun "$@"\n')
    script.chmod(0o755)
    env['PATH'] = str(shim) + os.pathsep + env.get('PATH', '')
    return env


def package_path(name):
    import json
    config = root / '.dart_tool' / 'package_config.json'
    if not config.is_file():
        return None
    for package in json.loads(config.read_text())['packages']:
        if package['name'] == name:
            path = Path(package['rootUri'].removeprefix('file://'))
            return path if path.is_absolute() else (config.parent / path).resolve()
    return None


def repair_media_kit(env):
    package = package_path('media_kit_libs_macos_video')
    if package is None:
        return
    directory = package / 'macos'
    script = directory / 'create_framework_symlinks.sh'
    linked = directory / 'Frameworks' / '.symlinks' / 'mpv' / 'macos'
    if not script.is_file() or linked.exists():
        return
    script.write_bytes(script.read_bytes().replace(b'\r\n', b'\n'))
    (directory / 'Frameworks' / '.symlinks' / 'mpv').mkdir(parents=True, exist_ok=True)
    run(['sh', 'create_framework_symlinks.sh', 'Frameworks/Mpv.xcframework',
         'Frameworks/.symlinks/mpv'], env, cwd=directory)


MPV_TARBALL_URL = ('https://github.com/media-kit/libmpv-darwin-build/releases/download/'
                   'v0.6.0/libmpv-xcframeworks_v0.6.0_macos-universal-video-default.tar.gz')
MPV_TARBALL_SHA256 = '84d2ad98e046e82c6dc34d8547d76c2afeaee89c0f53032773be8985c95536d6'
FFMPEG_KIT_URL = ('https://github.com/sk3llo/ffmpeg_kit_flutter/releases/download/'
                  '8.1.2-min-gpl/ffmpeg-kit-macos-min-gpl-8.1.2.zip')
FFMPEG_KIT_FRAMEWORKS = ['ffmpegkit', 'libavcodec', 'libavdevice', 'libavfilter',
                         'libavformat', 'libavutil', 'libswresample', 'libswscale']


def download_with_retry(url, target):
    for attempt in range(5):
        result = subprocess.run(['curl', '-fL', '--connect-timeout', '30', '-o', str(target), url],
                                capture_output=True, text=True)
        if result.returncode == 0 and target.is_file() and target.stat().st_size > 0:
            return True
        print(f'第 {attempt + 1} 次下载失败（curl {result.returncode}），稍后重试…', flush=True)
        import time
        time.sleep(5 * (attempt + 1))
    return False


def preheat_frameworks():
    # ponytail: GitHub runner 下载 release 资产常 504，先带重试把两个框架包放进
    # 插件的缓存位置，pod 的下载脚本检测到缓存存在即跳过；上游改版本时同步更新常量。
    import hashlib
    import zipfile
    libs = package_path('media_kit_libs_macos_video')
    if libs is not None:
        cache = libs / 'macos' / '.cache' / 'xcframeworks'
        tarball = cache / 'libmpv-xcframeworks-v0.6.0-macos-universal.tar.gz'
        if not tarball.is_file():
            cache.mkdir(parents=True, exist_ok=True)
            if download_with_retry(MPV_TARBALL_URL, tarball):
                digest = hashlib.sha256(tarball.read_bytes()).hexdigest()
                if digest != MPV_TARBALL_SHA256:
                    print(f'libmpv 校验和不符（{digest}），删除重下。', flush=True)
                    tarball.unlink()
                else:
                    print('libmpv 框架包已预热。', flush=True)
            else:
                tarball.unlink(missing_ok=True)
    kit = package_path('ffmpeg_kit_flutter_new_min_gpl')
    if kit is not None:
        frameworks = kit / 'macos' / 'Frameworks'
        if not (frameworks / 'ffmpegkit.framework').is_dir():
            import tempfile
            with tempfile.TemporaryDirectory(prefix='ffmpegkit-') as work:
                archive = Path(work) / 'frameworks.zip'
                if download_with_retry(FFMPEG_KIT_URL, archive):
                    try:
                        with zipfile.ZipFile(archive) as bundle:
                            bundle.extractall(work)
                        missing = [item for item in FFMPEG_KIT_FRAMEWORKS
                                   if not (Path(work) / f'{item}.framework').is_dir()]
                        if missing:
                            print(f'ffmpeg_kit 包缺少框架：{missing}', flush=True)
                            return
                        frameworks.mkdir(parents=True, exist_ok=True)
                        for item in FFMPEG_KIT_FRAMEWORKS:
                            shutil.move(str(Path(work) / f'{item}.framework'),
                                        str(frameworks / f'{item}.framework'))
                        print('ffmpeg_kit 框架已预热。', flush=True)
                    except zipfile.BadZipFile:
                        print('ffmpeg_kit 下载内容不是有效 zip，放弃预热。', flush=True)


def main():
    parser = argparse.ArgumentParser(description='构建红果鉴 / 全站源版 macOS 应用与 dmg')
    add_variant_argument(parser)
    options = parser.parse_args()
    variant = BuildVariant(options.all_sources)
    if platform.system() != 'Darwin':
        raise SystemExit('macOS 构建需要 macOS 与完整 Xcode。')
    env = toolchain_environment(developer_directory())
    flutter = shutil.which('flutter')
    pod = shutil.which('pod')
    if not flutter:
        raise SystemExit('请先将 Flutter SDK 的 bin 目录加入 PATH。')
    if not pod:
        raise SystemExit('请先安装 CocoaPods（brew install cocoapods）。')
    run([sys.executable, root / 'scripts' / 'build_native.py', '--platform', 'darwin',
         *variant.arguments], env)
    run([flutter, 'pub', 'get', '--enforce-lockfile'], env)
    preheat_frameworks()
    run([pod, 'install'], env, cwd=root / 'macos')
    repair_media_kit(env)
    run([flutter, 'build', 'macos', '--release', '--no-pub',
         *variant.flutter_arguments], env)
    run([sys.executable, root / 'scripts' / 'package_release.py', '--platform', 'macos',
         *variant.arguments], env)


if __name__ == '__main__':
    main()
