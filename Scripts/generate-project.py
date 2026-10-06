#!/usr/bin/env python3
"""Generate the Xcode project. Run after adding Swift source files. Needs Scripts/fetch-webrtc.sh first."""
from pathlib import Path
import hashlib
import plistlib

root = Path(__file__).resolve().parent.parent
project = root / 'DiscordTVBridge.xcodeproj'
project.mkdir(exist_ok=True)

def ident(value):
    return hashlib.sha256(value.encode()).hexdigest()[:24].upper()

def quoted(value):
    return '"' + value.replace('\\', '\\\\').replace('"', '\\"') + '"'

objects = []
def obj(key, body):
    objects.append(f'{ident(key)} = {{ {body} }};')

def refs(keys):
    return '(' + ', '.join(ident(k) for k in keys) + ',)'

apps = [('MacSender', 'Discord TV Sender', 'macosx', 'macOS', '14.0'),
        ('TVReceiver', 'Discord TV Receiver', 'appletvos', 'tvOS', '17.0')]
allfiles = sorted(root.glob('Sources/**/*.swift'))
for path in allfiles:
    rel = path.relative_to(root).as_posix()
    obj(rel, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {quoted(rel)}; sourceTree = "<group>";')
webrtc = 'Vendor/LiveKitWebRTC.xcframework'
obj(webrtc, f'isa = PBXFileReference; lastKnownFileType = wrapper.xcframework; path = {quoted(webrtc)}; sourceTree = "<group>";')

for name, product, sdk, platform, version in apps:
    product_key = name + '-product'
    obj(product_key, f'isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = {quoted(product + ".app")}; sourceTree = BUILT_PRODUCTS_DIR;')
    files = [p.relative_to(root).as_posix() for p in allfiles if p.parent.name in (name, 'Shared')]
    for file in files:
        obj(name + file, f'isa = PBXBuildFile; fileRef = {ident(file)};')
    obj(name + '-sources', f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = {refs([name + f for f in files])}; runOnlyForDeploymentPostprocessing = 0;')
    obj(name + '-link-webrtc', f'isa = PBXBuildFile; fileRef = {ident(webrtc)};')
    obj(name + '-embed-webrtc', f'isa = PBXBuildFile; fileRef = {ident(webrtc)}; settings = {{ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy, ); }};')
    obj(name + '-frameworks', f'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = {refs([name + "-link-webrtc"])}; runOnlyForDeploymentPostprocessing = 0;')
    obj(name + '-embed', f'isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = ""; dstSubfolderSpec = 10; files = {refs([name + "-embed-webrtc"])}; name = "Embed Frameworks"; runOnlyForDeploymentPostprocessing = 0;')
    obj(name + '-resources', 'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
    for config in ['Debug', 'Release']:
        settings = {
            'PRODUCT_NAME': product, 'PRODUCT_BUNDLE_IDENTIFIER': 'dev.designxdevelop.discordtvbridge.' + name.lower(),
            'SDKROOT': sdk, 'SWIFT_VERSION': '6.0', 'SWIFT_STRICT_CONCURRENCY': 'complete',
            'CODE_SIGN_STYLE': 'Automatic', 'INFOPLIST_FILE': f'Config/{name}-Info.plist',
            'ENABLE_USER_SCRIPT_SANDBOXING': 'YES', 'SWIFT_OPTIMIZATION_LEVEL': '-Onone' if config == 'Debug' else '-O',
            'CURRENT_PROJECT_VERSION': '1', 'ONLY_ACTIVE_ARCH': 'YES' if config == 'Debug' else 'NO', 'MARKETING_VERSION': '0.1.0',
            'SUPPORTED_PLATFORMS': 'macosx' if name == 'MacSender' else 'appletvos appletvsimulator',
        }
        if name == 'MacSender':
            settings.update({'MACOSX_DEPLOYMENT_TARGET': version, 'ENABLE_APP_SANDBOX': 'NO', 'COMBINE_HIDPI_IMAGES': 'YES',
                             'LD_RUNPATH_SEARCH_PATHS': '$(inherited) @executable_path/../Frameworks'})
        else:
            # The vendored tvOS simulator slice is arm64-only.
            settings.update({'TVOS_DEPLOYMENT_TARGET': version, 'TARGETED_DEVICE_FAMILY': '3',
                             'EXCLUDED_ARCHS[sdk=appletvsimulator*]': 'x86_64',
                             'LD_RUNPATH_SEARCH_PATHS': '$(inherited) @executable_path/Frameworks'})
        body = ' '.join((k if k.replace('_', '').isalnum() else quoted(k)) + ' = ' + quoted(v) + ';' for k, v in settings.items())
        obj(name + config, f'isa = XCBuildConfiguration; buildSettings = {{ {body} }}; name = {config};')
    obj(name + '-config', f'isa = XCConfigurationList; buildConfigurations = {refs([name + "Debug", name + "Release"])}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
    obj(name, f'isa = PBXNativeTarget; buildConfigurationList = {ident(name + "-config")}; buildPhases = {refs([name + "-sources", name + "-frameworks", name + "-embed", name + "-resources"])}; buildRules = (); dependencies = (); name = {name}; productName = {quoted(product)}; productReference = {ident(product_key)}; productType = "com.apple.product-type.application";')
    info = {
        'CFBundleExecutable': '$(EXECUTABLE_NAME)', 'CFBundleIdentifier': '$(PRODUCT_BUNDLE_IDENTIFIER)',
        'CFBundleName': '$(PRODUCT_NAME)', 'CFBundleDisplayName': product,
        'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': '$(MARKETING_VERSION)',
        'CFBundleVersion': '$(CURRENT_PROJECT_VERSION)',
        'NSLocalNetworkUsageDescription': 'Connect your Mac and Apple TV to share a selected call window over your local network.',
        'NSAppTransportSecurity': {'NSAllowsLocalNetworking': True},
        'NSBonjourServices': ['_dtvbridge._tcp'],
    }
    if name == 'MacSender':
        info.update({'LSMinimumSystemVersion': version, 'NSHighResolutionCapable': True,
                     'NSScreenCaptureUsageDescription': 'Share the window you select and its application audio with your Apple TV.'})
    else:
        # WHEP signaling goes to a literal private IPv4 over plain HTTP; media itself is DTLS-SRTP.
        info['NSAppTransportSecurity']['NSAllowsArbitraryLoads'] = True
        info.update({'LSRequiresIPhoneOS': True, 'UILaunchScreen': {}})
    (root / 'Config' / f'{name}-Info.plist').write_bytes(plistlib.dumps(info))
    schemes = project / 'xcshareddata' / 'xcschemes'
    schemes.mkdir(parents=True, exist_ok=True)
    (schemes / f'{name}.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident(name)}" BuildableName="{product}.app" BlueprintName="{name}" ReferencedContainer="container:DiscordTVBridge.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident(name)}" BuildableName="{product}.app" BlueprintName="{name}" ReferencedContainer="container:DiscordTVBridge.xcodeproj"/></BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"/>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')

obj('products', f'isa = PBXGroup; children = {refs([name + "-product" for name, *_ in apps])}; name = Products; sourceTree = "<group>";')
obj('main', f'isa = PBXGroup; children = {refs([p.relative_to(root).as_posix() for p in allfiles] + [webrtc, "products"])}; sourceTree = "<group>";')
for config in ['Debug', 'Release']:
    obj('project' + config, f'isa = XCBuildConfiguration; buildSettings = {{ CLANG_ENABLE_MODULES = YES; }}; name = {config};')
obj('project-config', f'isa = XCConfigurationList; buildConfigurations = {refs(["projectDebug", "projectRelease"])}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
obj('project', f'isa = PBXProject; attributes = {{ LastUpgradeCheck = 1600; }}; buildConfigurationList = {ident("project-config")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base); mainGroup = {ident("main")}; productRefGroup = {ident("products")}; projectDirPath = ""; projectRoot = ""; targets = {refs([name for name, *_ in apps])};')
(project / 'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n' + '\n'.join(objects) + f'\n}}; rootObject = {ident("project")}; }}\n')
print('Generated DiscordTVBridge.xcodeproj')
