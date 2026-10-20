from pathlib import Path, PurePosixPath
import argparse
import hashlib
import json
import zipfile

parser=argparse.ArgumentParser()
parser.add_argument('--without',required=True,type=Path)
parser.add_argument('--with-ue4ss',required=True,type=Path)
parser.add_argument('--maintenance',required=True,type=Path)
parser.add_argument('--native-source',required=True,type=Path)
parser.add_argument('--output',required=True,type=Path)
args=parser.parse_args()
PREFIX='DS/Binaries/Win64/ue4ss/Mods/DSWorldRadar/'
files={}
checks=[]
def sha(b): return hashlib.sha256(b).hexdigest()
def add_text(name,body): files[name]=body.encode('utf-8')
def check(name,condition):
    checks.append({'name':name,'passed':bool(condition)})
    if not condition: raise AssertionError(name)
def read_zip(p):
    with zipfile.ZipFile(p) as z:
        check(p.name+' CRC',z.testzip() is None)
        names=z.namelist()
        check(p.name+' safe unique entries',len(names)==len(set(names)) and all(not PurePosixPath(n).is_absolute() and '..' not in PurePosixPath(n).parts for n in names))
        return {n:z.read(n) for n in names}

without=read_zip(args.without)
with_ue4ss=read_zip(args.with_ue4ss)
maintenance=read_zip(args.maintenance)
check('both public archives have identical mod payloads',{n:b for n,b in without.items() if n.startswith(PREFIX)}=={n:b for n,b in with_ue4ss.items() if n.startswith(PREFIX)})
meta=json.loads(without['PACKAGE_INFO.json'].decode('utf-8-sig'))
check('mod 1.1 and game 1.1.1',meta['mod_version']=='1.1' and meta['game_compatibility']['public_patch_version']=='1.1.1')
check('all shipped mod metadata hashes match',meta['mod_files']=={n.removeprefix(PREFIX):sha(b) for n,b in without.items() if n.startswith(PREFIX)})
check('UE4SS runtime matches the recorded baseline hash',sha(with_ue4ss['DS/Binaries/Win64/ue4ss/UE4SS.dll'])==meta['ue4ss_baseline_sha256'])
runtime_sources=[]
for name,data in maintenance.items():
    if name.startswith('source/'):
        relative=name.removeprefix('source/')
        check('source matches shipped bytes: '+relative,data==without[PREFIX+relative])
        files[name]=data
        runtime_sources.append({'source':name,'runtime_reference':'reference_mod/'+relative,'sha256':sha(data),'comparison':'byte-identical to current installer'})
    elif name.startswith('tests/') and name!='tests/README.md':
        files[name]=data
check('all eight current runtime source files included',len(runtime_sources)==8)
for name,data in without.items():
    if name.startswith(PREFIX): files['reference_mod/'+name.removeprefix(PREFIX)]=data
for name in ['wcxbridge.c','wcx_resolver.h','resolver_test_api.c']:
    files['source/native/'+name]=(args.native_source/name).read_bytes()
native_source_hashes={n:sha(b) for n,b in files.items() if n.startswith('source/native/')}
stored_wcx=(args.native_source/'wcxbridge.dll').read_bytes()
check('retained WCX build artifact matches shipped WCX',stored_wcx==without[PREFIX+'dlls/wcxbridge.dll'])
check('WCX source identifies the shipped 2802 interface',b'2802' in files['source/native/wcxbridge.c'])

native=[]
roles={
 'main.dll':('retained project native loader/entry component','Full source/project not located in available records.'),
 'main_original.dll':('MnM Radar-derived native core','Original author C++ source has been requested but not received; no full source-level rebuild is available.'),
 'wcbridge.dll':('retained native WorldComplete notification/count bridge','Full source/project not located in available records.'),
 'wcxbridge.dll':('project auxiliary WorldComplete bridge, interface 2802','C source and resolver header are included. Stored compiled artifact matches the shipped DLL; no new Windows build is claimed.'),
 'dqbridge.dll':('retained native DynamicQuest bridge','Full source/project not located in available records.'),
}
for name,(role,note) in roles.items():
    data=without[PREFIX+'dlls/'+name]
    native.append({'file':name,'path':'reference_mod/dlls/'+name,'bytes':len(data),'sha256':sha(data),'role':role,'source_available':name=='wcxbridge.dll','source_files':['source/native/wcxbridge.c','source/native/wcx_resolver.h'] if name=='wcxbridge.dll' else [],'note':note})
check('four native source gaps explicitly recorded',sum(not n['source_available'] for n in native)==4)

release_records=[]
for variant,path,data in [('Without_UE4SS',args.without,without),('With_UE4SS',args.with_ue4ss,with_ue4ss)]:
    files['release_metadata/'+variant+'_PACKAGE_INFO.json']=data['PACKAGE_INFO.json']
    release_records.append({'file_name':path.name,'bytes':path.stat().st_size,'sha256':sha(path.read_bytes()),'mod_version':'1.1','target_game_version':'1.1.1'})
files['release_metadata/THIRD_PARTY_NOTICES.txt']=without['THIRD_PARTY_NOTICES.txt']
files['release_metadata/GAME_VERSION_ZH_EN.txt']=without['GAME_VERSION_ZH_EN.txt']
files['release_metadata/UE4SS_LICENSE']=with_ue4ss['DS/Binaries/Win64/ue4ss/LICENSE']
add_text('release_metadata/RELEASES.json',json.dumps(release_records,indent=2)+'\n')
mapping={'runtime_sources':runtime_sources,'native_components':native,'native_source_sha256':native_source_hashes,'full_native_project_rebuild_possible':False,'ue4ss_bundled_in_review_archive':False,'ue4ss_baseline_commit':meta['ue4ss_baseline_commit'],'ue4ss_baseline_dll_sha256':meta['ue4ss_baseline_sha256']}
add_text('SOURCE_BINARY_MAP.json',json.dumps(mapping,ensure_ascii=False,indent=2)+'\n')

add_text('README_REVIEW_ZH_EN.md','''# DSWorldRadar 1.1 — 版主代码审核资料

对应游戏：《龙之剑：觉醒》1.1.1，Steam / Windows x64。
本包供代码和二进制审核使用，不是玩家安装包。

## 审核入口

- source/：与当前发布包逐字节一致的 PowerShell、C#、Lua 源码，以及可取得的 WCX 2802 原生 C/H 源码。
- reference_mod/：从当前不含 UE4SS 安装包原样提取的完整 MOD 文件，含五个现行 DLL、数据和语言文件，供对照分析。
- SOURCE_BINARY_MAP.json：源码对应关系、原生组件来源说明和源码缺口。
- build/：仅编译、不启动游戏或同步器的构建脚本。
- docs/：依赖、敏感行为和授权状态说明。
- tests/：现有离线测试脚本；本次未把此前测试算作新执行。
- release_metadata/：两个正式安装包的名称、SHA-256 和包信息。
- tools/verify_review_bundle.py：用 Python 标准库核对文件校验和及源码对应关系。

## 源码完整性说明

现行的 8 个运行源码文件已包含，WCX 2802 C/H 源码也已包含。
main.dll、main_original.dll、wcbridge.dll、dqbridge.dll 的完整原生源码目前不可得。
其中 main_original.dll 是 MnM Radar 派生核心，原作者的 C++ 源码仍未收到。
其余三个组件的源码/工程在目前可取得的项目记录中未找到；不将它们冒称为有完整源码的第三方或自编译组件。

因此，本包不能宣称为全部原生 DLL 均可重建的完整 C++ 工程。
没有用推测或重写代码冒充缺失源码。对应 DLL 原文件和哈希均保留供独立分析。

未包含游戏 EXE、PAK、玩家存档、解密缓存、个人运行日志或私人邮件全文。
UE4SS 本体未重复打入此包；所用版本、提交和哈希已记录。

---

# DSWorldRadar 1.1 — Source and binary review bundle

Target game: DragonSword: Awakening 1.1.1, Steam / Windows x64.
This is material for moderator review, not an installer.

## Starting points

- source/: byte-identical shipped PowerShell, C# and Lua sources, plus available WCX 2802 native C/H source.
- reference_mod/: the complete mod directory extracted unchanged from the current Without UE4SS installer, including five shipped DLLs, data and translations.
- SOURCE_BINARY_MAP.json: source correspondence, component descriptions and source gaps.
- build/: compilation-only scripts that do not launch the game or save-sync helper.
- docs/: dependencies, sensitive behavior and permission status.
- tests/: existing offline test harnesses. Earlier test results are not represented as new executions.
- release_metadata/: filenames, SHA-256 hashes and metadata of both public installation archives.
- tools/verify_review_bundle.py: standard-library Python verification of checksums and source correspondence.

## Source coverage and limitations

All eight current runtime source files and the WCX 2802 C/H source are included.
Full native source is currently unavailable for main.dll, main_original.dll, wcbridge.dll and dqbridge.dll.
main_original.dll is the MnM Radar-derived core; the original author's C++ source has been requested but not received.
Source/projects for the other three retained native components were not located in the available project records; no unsupported authorship or source-completeness claim is made.

This is therefore not a complete C++ project capable of rebuilding every native DLL.
Missing source has not been replaced with speculative code. Exact shipped binaries and hashes are retained for independent analysis.

No game executable, PAK, player save, decrypted cache, personal runtime log or complete private email is included.
The UE4SS runtime itself is not duplicated; its recorded version, commit and hash are included.
''')

add_text('docs/BUILD_AND_DEPENDENCIES_ZH_EN.md','''# 构建与依赖

## C# 存档同步器

运行 source/dlls/sync/bootstrap.ps1 时，游戏环境会调用 Windows 自带的 .NET Framework csc.exe 编译 MnMChestSaveSync.cs。
审核时可使用 build/Build_SaveSync.ps1 单独编译；此脚本不会执行生成的 EXE，也不会启动游戏。
编译参数与现行 bootstrap.ps1 对应：/nologo /optimize+ /target:exe /platform:x64 /reference:System.Core.dll /reference:System.Xml.dll。
运行时使用 Windows winsqlite3.dll，并读取本地存档格式。没有额外 NuGet 包。

## WCX 2802 辅助桥

source/native/wcxbridge.c 与 wcx_resolver.h 为可取得的现行源码，resolver_test_api.c 为主机定位器测试入口。
历史构建记录使用 Python ziglang 提供的 Zig 0.17.0，目标 x86_64-windows-gnu。
build/Build_WCX.ps1 保留对应命令：

python -m ziglang cc -target x86_64-windows-gnu -O2 -shared -Wall -Wextra -Werror -Wl,--strip-all wcxbridge.c -o wcxbridge.dll

编译器/SDK 差异可能改变输出字节；本次仅确认留存构建产物与发布 DLL 完全相同，没有宣称本轮重新执行 Windows 构建或保证可复现完全相同的 DLL。
其余四个 DLL 缺少完整源码，不能从本包重建。

## 脚本与 UE4SS

PowerShell 目标环境为 Windows PowerShell 5.1；离线测试脚本原使用 PowerShell 7.4.6。
Lua 文件由配套 UE4SS 加载，无单独编译步骤；PS 文件内的 Add-Type C# 实现已保留在原脚本中。
配套加载器为 UE4SS v3.0.1 Beta #0，提交 1c1a1497f942c707f47ba668db75b25e86f6c08a。
上游项目：https://github.com/UE4SS-RE/RE-UE4SS 。本包不提供或声称重建 UE4SS 源码。

---

# Build and dependencies

## C# save-sync helper

The shipped bootstrap.ps1 invokes the Windows .NET Framework csc.exe to compile MnMChestSaveSync.cs locally.
For review, build/Build_SaveSync.ps1 compiles it in isolation without executing the resulting EXE or launching the game.
Compiler flags match the shipped bootstrap: /nologo /optimize+ /target:exe /platform:x64 /reference:System.Core.dll /reference:System.Xml.dll.
Runtime SQLite access uses the Windows winsqlite3.dll. There are no additional NuGet dependencies.

## WCX 2802 auxiliary bridge

The available current sources are source/native/wcxbridge.c and wcx_resolver.h; resolver_test_api.c exposes the resolver to host tests.
The retained build record used Zig 0.17.0 through the Python ziglang package, targeting x86_64-windows-gnu.
build/Build_WCX.ps1 retains the command shown above.
Different toolchains or SDKs may change output bytes. This review preparation confirms the retained build artifact matches the shipped DLL; it does not claim a fresh Windows build or guarantee bit-for-bit reproducibility.
The other four native DLLs cannot be rebuilt from this bundle because full source is unavailable.

## Scripts and UE4SS

The runtime PowerShell target is Windows PowerShell 5.1; prior offline harnesses used PowerShell 7.4.6.
Lua is loaded by the matching UE4SS runtime without a separate compile step. Inline C# Add-Type code remains inside its original PS files.
The bundled runtime baseline is UE4SS v3.0.1 Beta #0, commit 1c1a1497f942c707f47ba668db75b25e86f6c08a.
Upstream: https://github.com/UE4SS-RE/RE-UE4SS . This bundle does not include or claim to rebuild UE4SS source.
''')

add_text('docs/BEHAVIOR_AND_PERMISSION_ZH_EN.md','''# 行为与授权说明

## 需要审核的实际行为

- Lua/启动脚本会以隐藏窗口启动 PowerShell，并为子进程使用 -ExecutionPolicy Bypass；不是修改系统全局执行策略。
- bootstrap.ps1 在本机编译 C# 同步辅助程序，并启动或管理本 MOD 的同步进程。
- C# 辅助程序包含现有存档解密参数，派生密钥后读取 SQLCipher 格式存档，在 MOD 缓存中处理临时解密副本，并通过 winsqlite3.dll 查询进度。
- live_chest_watcher.ps1 包含 Add-Type C# 代码，使用 OpenProcess、ReadProcessMemory、WriteProcessMemory 访问游戏中的雷达和完成状态。
- 语言脚本会更新雷达语言文件；现有原生整合包含固定偏移访问和界面修改。
- WCX C 源码包含运行时函数定位、VirtualAlloc/VirtualProtect 及跳转补丁，用于取得游戏原生计数通知。

以上为审核对象说明，不是安全软件豁免请求。对于没有源码的 DLL，仅提供当前二进制及哈希，不作缺乏依据的完整源码行为声明。

## MnM Radar 关系

本 MOD 实际包含 MnM Radar 派生原生核心，并非仅引用算法。
原作者 paroxis 在维护者提供的邮件中同意以 DSWorldRadar 名义独立发布，要求保留 MnM Radar 基础署名，并允许使用点位和 ID 数据。
原作者也建议不要通过固定 RVA 修补其 DLL，而应重新实现所需功能；当前源码级替代尚未完成，固定偏移/界面整合仍存在。
原作者曾提出可尝试公开源码；目前尚未收到 C++ 源码。此许可不被表述为通用开源许可证。
THIRD_PARTY_NOTICES.txt 与发布包保持原样；没有把原 MOD 页面列为依赖链接。
完整私人邮件未附入本代码包，避免夹带不必要的个人通信内容。

---

# Behavior and permission notes

## Actual behavior requiring review

- Lua/bootstrap code launches hidden PowerShell child processes with -ExecutionPolicy Bypass; this is not a global execution-policy change.
- bootstrap.ps1 compiles the C# helper locally and starts/manages this mod's synchronization processes.
- The C# helper includes existing save-decryption parameters, derives a key, reads SQLCipher-format saves, processes temporary decrypted copies in the mod cache and queries progress through winsqlite3.dll.
- live_chest_watcher.ps1 includes inline Add-Type C# using OpenProcess, ReadProcessMemory and WriteProcessMemory to access in-game radar/completion state.
- Language code updates radar language files. Existing native integration includes fixed-offset access and UI modifications.
- The WCX C source contains runtime function resolution, VirtualAlloc/VirtualProtect and jump patches for native completion notifications.

These are review disclosures, not a request for antivirus exemption. Components without source are supplied as exact current binaries with hashes; no unsupported full source-level behavior claim is made for them.

## Relationship to MnM Radar

This mod includes a MnM Radar-derived native core; it is not merely an algorithm reference.
In correspondence supplied by the maintainer, paroxis approved a separate DSWorldRadar release with credit to MnM Radar and permitted reuse of the node/ID data.
The author also advised reimplementation instead of fixed-RVA patching of his DLL. That source-level replacement is not complete, and fixed-offset/UI integration remains.
The author offered to look into making source public, but the C++ source has not been received. The private permission is not represented as a blanket open-source license.
THIRD_PARTY_NOTICES.txt is retained unchanged. The original mod page is not presented as a required dependency.
Complete private correspondence is not included to avoid attaching unnecessary personal communication.
''')

add_text('build/Build_SaveSync.ps1',r'''param([string]$OutputDirectory = (Join-Path $PSScriptRoot '..\build-output'))
$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot '..\source\dlls\sync\MnMChestSaveSync.cs'
$candidates = @((Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'), (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'))
$csc = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $csc) { throw '.NET Framework csc.exe not found. Use Windows with .NET Framework.' }
[void](New-Item -ItemType Directory -Force -Path $OutputDirectory)
$output = Join-Path (Resolve-Path -LiteralPath $OutputDirectory).Path 'MnMChestSaveSync.exe'
& $csc '/nologo' '/optimize+' '/target:exe' '/platform:x64' '/reference:System.Core.dll' '/reference:System.Xml.dll' ("/out:" + $output) $source
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $output)) { throw 'Compilation failed.' }
Write-Output ('Compiled only; executable was not launched: ' + $output)
''')
add_text('build/Build_WCX.ps1',r'''param([string]$Python = 'python', [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\build-output'))
$ErrorActionPreference = 'Stop'
[void](New-Item -ItemType Directory -Force -Path $OutputDirectory)
$output = Join-Path (Resolve-Path -LiteralPath $OutputDirectory).Path 'wcxbridge.dll'
Push-Location (Join-Path $PSScriptRoot '..\source\native')
try {
    & $Python '-m' 'ziglang' 'cc' '-target' 'x86_64-windows-gnu' '-O2' '-shared' '-Wall' '-Wextra' '-Werror' '-Wl,--strip-all' 'wcxbridge.c' '-o' $output
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $output)) { throw 'Compilation failed; the recorded toolchain requires ziglang/Zig.' }
} finally { Pop-Location }
Write-Output ('Compiled only; DLL was not loaded: ' + $output)
''')
for name in ['build/Build_SaveSync.ps1','build/Build_WCX.ps1']:
    files[name]=b'\xef\xbb\xbf'+files[name].replace(b'\n',b'\r\n')

requirements=maintenance.get('history/v1.0.7/requirements_tests.txt')
if requirements: files['tests/requirements_tests.txt']=requirements
add_text('tests/README_REVIEW_ZH_EN.md','''# 离线测试资料

此目录为既有测试脚本，不包含个人存档或个人运行日志。准备审核包时未重新执行这些游戏行为测试。
原测试环境使用 PowerShell 7.4.6；Python 依赖见 requirements_tests.txt。
以下命令在解压后根目录执行，输出只写入 audit/：

pwsh -NoProfile -File tests/dispatch_lifecycle.ps1 -WatcherPath source/dlls/sync/live_chest_watcher.ps1 -OutputPath audit/dispatch_lifecycle.json
pwsh -NoProfile -File tests/common_io.ps1 -CommonPath source/dlls/sync/radar_common.ps1 -OutputPath audit/common_io.json
pwsh -NoProfile -File tests/watcher_execution.ps1 -WatcherPath source/dlls/sync/live_chest_watcher.ps1 -NodesPath reference_mod/dlls/mnm_nodes.csv -OutputPath audit/watcher_execution.json
pwsh -NoProfile -File tests/area_matching.ps1 -WatcherPath source/dlls/sync/live_chest_watcher.ps1 -IdsPath reference_mod/dlls/mnm_ids.csv -OutputPath audit/area_matching.json

其他脚本的参数见各文件开头。部分检查需要生成合成存档夹具或指定路径，不能把它们当作无需依赖的一键游戏测试。

---

# Offline harnesses

These are retained test harnesses, with no personal save or runtime trace. They were not re-executed as new game-behavior tests while preparing this review bundle.
The prior environment used PowerShell 7.4.6; Python dependencies are in requirements_tests.txt.
Run the commands above from the extracted root. Outputs go to audit/.
Other harness parameters are documented at the start of each file. Some need synthetic save fixtures or explicit paths and are not dependency-free game tests.
''')

add_text('tools/verify_review_bundle.py',r'''from pathlib import Path
import hashlib,json
root=Path(__file__).resolve().parents[1]
manifest={}
for line in (root/'SHA256SUMS.txt').read_text(encoding='utf-8').splitlines():
    digest,name=line.split('  ',1)
    manifest[name]=digest
actual={p.relative_to(root).as_posix() for p in root.rglob('*') if p.is_file() and p.name!='SHA256SUMS.txt'}
assert set(manifest)==actual, 'Manifest inventory mismatch; use a clean extraction.'
for name,digest in manifest.items():
    assert hashlib.sha256((root/name).read_bytes()).hexdigest()==digest,name
mapping=json.loads((root/'SOURCE_BINARY_MAP.json').read_text(encoding='utf-8'))
for row in mapping['runtime_sources']:
    a=(root/row['source']).read_bytes()
    assert a==(root/row['runtime_reference']).read_bytes(),row['source']
    assert hashlib.sha256(a).hexdigest()==row['sha256'],row['source']
for row in mapping['native_components']:
    assert hashlib.sha256((root/row['path']).read_bytes()).hexdigest()==row['sha256'],row['path']
assert sum(not row['source_available'] for row in mapping['native_components'])==4
print('Verified',len(manifest),'files; eight exact runtime source mappings; five native binary hashes; four explicit native source gaps.')
''')
files['tools/assemble_moderator_review.py']=Path(__file__).read_bytes()
check('no personal saves crash dumps or runtime logs included',not any(n.lower().endswith(('.log','.dmp','.db','.runtime-xml')) or '/cache/' in n.lower() for n in files))
add_text('REVIEW_VERIFICATION.json',json.dumps({'passed':all(c['passed'] for c in checks),'checks':checks,'new_gameplay_tests_performed':False,'new_windows_dll_rebuild_performed':False,'runtime_source_file_count':len(runtime_sources),'native_source_gap_count':4},indent=2)+'\n')
add_text('SHA256SUMS.txt',''.join(sha(b)+'  '+n+'\n' for n,b in sorted(files.items())))
args.output.parent.mkdir(parents=True,exist_ok=True)
with zipfile.ZipFile(args.output,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=9) as z:
    for name,data in sorted(files.items()):
        entry=zipfile.ZipInfo(name,(2026,10,18,0,0,0));entry.compress_type=zipfile.ZIP_DEFLATED;entry.external_attr=0o100644<<16
        z.writestr(entry,data,compresslevel=9)
with zipfile.ZipFile(args.output) as z:
    assert z.testzip() is None
    assert len(z.namelist())==len(files)
print(json.dumps({'file':str(args.output),'bytes':args.output.stat().st_size,'sha256':sha(args.output.read_bytes()),'files':len(files),'runtime_sources':len(runtime_sources),'native_dlls':len(native),'native_source_gaps':4},indent=2))
