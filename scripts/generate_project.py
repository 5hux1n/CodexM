#!/usr/bin/env python3
"""Deterministic, dependency-free Xcode project generation."""
from pathlib import Path
import hashlib
root=Path(__file__).resolve().parents[1]
objects={}
def ident(name): return hashlib.sha256(name.encode()).hexdigest()[:24].upper()
def obj(name, body):
    key=ident(name); objects[key]=body; return key
def q(value): return '"'+str(value).replace('\\','\\\\').replace('"','\\"')+'"'
def arr(values): return '('+','.join(values)+')'
def settings(values): return '{'+''.join(k+' = '+v+';' for k,v in values.items())+'}'
sources=sorted((root/'CodexM').rglob('*.swift'))
resources=[root/'CodexM/Resources/Localizable.xcstrings', root/'CodexM/Resources/Assets.xcassets', root/'CodexM/Resources/GitHub-Octicons-LICENSE.txt']
file_ids=[]; source_build=[]; resource_build=[]
for path in sources+resources:
    relative=str(path.relative_to(root)); ext=path.suffix
    ref=obj('ref:'+relative, '{isa = PBXFileReference; lastKnownFileType = '+('sourcecode.swift' if ext=='.swift' else 'folder.assetcatalog' if ext=='.xcassets' else 'text' if ext=='.txt' else 'text.json.xcstrings')+'; path = '+q(relative)+'; sourceTree = "<group>";}')
    build=obj('build:'+relative,'{isa = PBXBuildFile; fileRef = '+ref+';}')
    file_ids.append(ref)
    (source_build if path in sources else resource_build).append(build)
app=obj('product','{isa = PBXFileReference; explicitFileType = wrapper.application; path = CodexM.app; sourceTree = BUILT_PRODUCTS_DIR;}')
products=obj('products','{isa = PBXGroup; children = '+arr([app])+'; name = Products; sourceTree = "<group>";}')
group=obj('mainGroup','{isa = PBXGroup; children = '+arr(file_ids+[products])+'; sourceTree = "<group>";}')
def phase(name, kind, files): return obj(name,'{isa = '+kind+'; buildActionMask = 2147483647; files = '+arr(files)+'; runOnlyForDeploymentPostprocessing = 0;}')
src=phase('sources','PBXSourcesBuildPhase',source_build); res=phase('resources','PBXResourcesBuildPhase',resource_build); frameworks=phase('frameworks','PBXFrameworksBuildPhase',[])
def configurations(name, common):
    ids=[]
    for mode in ['Debug','Release']:
        values=dict(common)
        # Keep test/preview builds separate from the user's running release app.
        if name == 'app' and mode == 'Debug': values['PRODUCT_BUNDLE_IDENTIFIER'] = 'dev.codexm.app.debug'
        if name=='project': values.update({'SWIFT_OPTIMIZATION_LEVEL': q('-Onone' if mode=='Debug' else '-O'), 'DEBUG_INFORMATION_FORMAT': q('dwarf' if mode=='Debug' else 'dwarf-with-dsym'), 'SWIFT_ACTIVE_COMPILATION_CONDITIONS': q('DEBUG' if mode=='Debug' else '')})
        ids.append(obj(name+mode,'{isa = XCBuildConfiguration; name = '+mode+'; buildSettings = '+settings(values)+';}'))
    return obj(name+'config','{isa = XCConfigurationList; buildConfigurations = '+arr(ids)+'; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;}')
pc=configurations('project',{'SDKROOT':'macosx','MACOSX_DEPLOYMENT_TARGET':'14.0','SWIFT_VERSION':'6.0','CLANG_ENABLE_MODULES':'YES','CLANG_ENABLE_OBJC_ARC':'YES','SWIFT_STRICT_CONCURRENCY':'complete','ENABLE_TESTABILITY':'YES'})
ac=configurations('app',{'PRODUCT_NAME':'CodexM','PRODUCT_BUNDLE_IDENTIFIER':'dev.codexm.app','INFOPLIST_FILE':q('CodexM/Resources/Info.plist'),'CODE_SIGN_STYLE':'Automatic','CODE_SIGN_IDENTITY':q('-'),'ENABLE_APP_SANDBOX':'NO','ENABLE_HARDENED_RUNTIME':'YES','SWIFT_EMIT_LOC_STRINGS':'NO','LD_RUNPATH_SEARCH_PATHS':q('$(inherited) @executable_path/../Frameworks'),'COMBINE_HIDPI_IMAGES':'YES','ASSETCATALOG_COMPILER_APPICON_NAME':'AppIcon'})
appTarget=obj('target','{isa = PBXNativeTarget; buildConfigurationList = '+ac+'; buildPhases = '+arr([src,frameworks,res])+'; buildRules = (); dependencies = (); name = CodexM; productName = CodexM; productReference = '+app+'; productType = "com.apple.product-type.application";}')
project=obj('project','{isa = PBXProject; attributes = {LastUpgradeCheck = 2600;}; buildConfigurationList = '+pc+'; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, "zh-Hans", Base); mainGroup = '+group+'; productRefGroup = '+products+'; projectDirPath = ""; projectRoot = ""; targets = '+arr([appTarget])+';}')
proj=root/'CodexM.xcodeproj'; proj.mkdir(exist_ok=True)
(proj/'project.pbxproj').write_text('// !$*UTF8*$!\n{archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+'\n'.join(k+' = '+v+';' for k,v in objects.items())+'\n}; rootObject = '+project+';}\n')
scheme=proj/'xcshareddata/xcschemes';scheme.mkdir(parents=True,exist_ok=True)
def ref(target,name): return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="{name}" BlueprintName="{name.split(".")[0]}" ReferencedContainer="container:CodexM.xcodeproj"/>'
(scheme/'CodexM.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref(appTarget,'CodexM.app')}</BuildActionEntry></BuildActionEntries></BuildAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref(appTarget,'CodexM.app')}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref(appTarget,'CodexM.app')}</BuildableProductRunnable></ProfileAction><AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
print(f'Generated Xcode project: {len(sources)} Swift sources')
