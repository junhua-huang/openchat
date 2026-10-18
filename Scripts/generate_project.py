#!/usr/bin/env python3
"""Generate a dependency-free Xcode project on Windows, Linux, or macOS."""
import hashlib
from pathlib import Path
import plistlib
import json

ROOT = Path(__file__).resolve().parents[1]
objects = {}


def ref(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()


def add(object_label, isa, **fields):
    key = ref(object_label)
    assert key not in objects
    objects[key] = dict(isa=isa, **fields)
    return key


def encode(value, level=0):
    if isinstance(value, dict):
        pad = "\t" * level
        inner = "\n".join("\t" * (level + 1) + json.dumps(k) + " = " + encode(v, level + 1) + ";" for k, v in value.items())
        return "{\n" + inner + "\n" + pad + "}"
    if isinstance(value, list):
        return "(" + ", ".join(encode(x, level) for x in value) + ("," if value else "") + ")"
    return str(value) if isinstance(value, int) else json.dumps(str(value))


def file(path, kind):
    return add("file:" + path, "PBXFileReference", lastKnownFileType=kind, path=path, sourceTree="<group>")


def phase(name, isa, refs):
    builds = [add(name + ":" + x, "PBXBuildFile", fileRef=x) for x in refs]
    return add(name, isa, buildActionMask=2147483647, files=builds, runOnlyForDeploymentPostprocessing=0)


def configs(name, base):
    refs = []
    for mode in ["Debug", "Release"]:
        settings = dict(base)
        settings.update({"SWIFT_OPTIMIZATION_LEVEL": "-Onone" if mode == "Debug" else "-O",
                         "DEBUG_INFORMATION_FORMAT": "dwarf" if mode == "Debug" else "dwarf-with-dsym"})
        if mode == "Debug":
            settings.update({"ENABLE_TESTABILITY": "YES", "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG $(inherited)", "ONLY_ACTIVE_ARCH": "YES"})
        refs.append(add(name + ":" + mode, "XCBuildConfiguration", buildSettings=settings, name=mode))
    return add(name + ":list", "XCConfigurationList", buildConfigurations=refs, defaultConfigurationIsVisible=0, defaultConfigurationName="Release")


app_sources = [file(p.relative_to(ROOT).as_posix(), "sourcecode.swift") for folder in ["App", "Core", "Views"] for p in sorted((ROOT / folder).glob("*.swift"))]
test_sources = [file(p.relative_to(ROOT).as_posix(), "sourcecode.swift") for p in sorted((ROOT / "Tests").glob("*.swift"))]
ui_sources = [file(p.relative_to(ROOT).as_posix(), "sourcecode.swift") for p in sorted((ROOT / "UITests").glob("*.swift"))]
asset = file("App/Assets.xcassets", "folder.assetcatalog")
privacy = file("App/PrivacyInfo.xcprivacy", "text.xml")
info = file("App/Info.plist", "text.plist.xml")
fixtures = file("Tests/Fixtures.json", "text.json")
app_product = add("app-product", "PBXFileReference", explicitFileType="wrapper.application", includeInIndex=0, path="LiaoChat.app", sourceTree="BUILT_PRODUCTS_DIR")
test_product = add("test-product", "PBXFileReference", explicitFileType="wrapper.cfbundle", includeInIndex=0, path="LiaoChatTests.xctest", sourceTree="BUILT_PRODUCTS_DIR")
ui_product = add("ui-product", "PBXFileReference", explicitFileType="wrapper.cfbundle", includeInIndex=0, path="LiaoChatUITests.xctest", sourceTree="BUILT_PRODUCTS_DIR")
ui_group = add("ui-group", "PBXGroup", children=ui_sources, name="UITests", sourceTree="<group>")
products = add("products", "PBXGroup", children=[app_product, test_product, ui_product], name="Products", sourceTree="<group>")
tests = add("tests-group", "PBXGroup", children=test_sources + [fixtures], name="Tests", sourceTree="<group>")
main = add("main-group", "PBXGroup", children=app_sources + [asset, privacy, info, tests, ui_group, products], sourceTree="<group>")
common = {"IPHONEOS_DEPLOYMENT_TARGET": "17.0", "SWIFT_VERSION": "5.0", "SDKROOT": "iphoneos", "CLANG_ENABLE_MODULES": "YES",
          "TARGETED_DEVICE_FAMILY": "1,2", "CODE_SIGN_STYLE": "Automatic", "DEVELOPMENT_TEAM": "",
          "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator", "SUPPORTS_MACCATALYST": "NO"}
app_settings = dict(common, PRODUCT_BUNDLE_IDENTIFIER="com.example.LiaoChat", PRODUCT_NAME="$(TARGET_NAME)",
                    INFOPLIST_FILE="App/Info.plist", GENERATE_INFOPLIST_FILE="NO", MARKETING_VERSION="2.2.0",
                    CURRENT_PROJECT_VERSION="1", OTHER_LDFLAGS="$(inherited) -lz", ASSETCATALOG_COMPILER_APPICON_NAME="AppIcon",
                    LD_RUNPATH_SEARCH_PATHS="$(inherited) @executable_path/Frameworks")
test_settings = dict(common, PRODUCT_BUNDLE_IDENTIFIER="com.example.LiaoChatTests", PRODUCT_NAME="$(TARGET_NAME)",
                     GENERATE_INFOPLIST_FILE="YES", TEST_HOST="$(BUILT_PRODUCTS_DIR)/LiaoChat.app/LiaoChat", BUNDLE_LOADER="$(TEST_HOST)",
                     LD_RUNPATH_SEARCH_PATHS="$(inherited) @executable_path/Frameworks @loader_path/Frameworks")
app = add("app-target", "PBXNativeTarget", buildConfigurationList=configs("app", app_settings),
          buildPhases=[phase("app-sources", "PBXSourcesBuildPhase", app_sources), phase("app-frameworks", "PBXFrameworksBuildPhase", []), phase("app-resources", "PBXResourcesBuildPhase", [asset, privacy])],
          buildRules=[], dependencies=[], name="LiaoChat", productName="LiaoChat", productReference=app_product, productType="com.apple.product-type.application")
proxy = add("app-proxy", "PBXContainerItemProxy", containerPortal=ref("project"), proxyType=1, remoteGlobalIDString=app, remoteInfo="LiaoChat")
dependency = add("test-dependency", "PBXTargetDependency", target=app, targetProxy=proxy)
test = add("test-target", "PBXNativeTarget", buildConfigurationList=configs("test", test_settings),
           buildPhases=[phase("test-sources", "PBXSourcesBuildPhase", test_sources), phase("test-frameworks", "PBXFrameworksBuildPhase", []), phase("test-resources", "PBXResourcesBuildPhase", [fixtures])],
           buildRules=[], dependencies=[dependency], name="LiaoChatTests", productName="LiaoChatTests", productReference=test_product, productType="com.apple.product-type.bundle.unit-test")
ui_settings = dict(common, PRODUCT_BUNDLE_IDENTIFIER="com.example.LiaoChatUITests", PRODUCT_NAME="$(TARGET_NAME)",
                   GENERATE_INFOPLIST_FILE="YES", TEST_TARGET_NAME="LiaoChat",
                   LD_RUNPATH_SEARCH_PATHS="$(inherited) @executable_path/Frameworks @loader_path/Frameworks")
ui_test = add("ui-target", "PBXNativeTarget", buildConfigurationList=configs("ui", ui_settings),
              buildPhases=[phase("ui-sources", "PBXSourcesBuildPhase", ui_sources), phase("ui-frameworks", "PBXFrameworksBuildPhase", []), phase("ui-resources", "PBXResourcesBuildPhase", [])],
              buildRules=[], dependencies=[dependency], name="LiaoChatUITests", productName="LiaoChatUITests", productReference=ui_product, productType="com.apple.product-type.bundle.ui-testing")
project = add("project", "PBXProject", attributes={"LastUpgradeCheck": "1600", "TargetAttributes": {app: {"CreatedOnToolsVersion": "16.0"}, test: {"CreatedOnToolsVersion": "16.0", "TestTargetID": app}, ui_test: {"CreatedOnToolsVersion": "16.0", "TestTargetID": app}}},
              buildConfigurationList=configs("project", {}), compatibilityVersion="Xcode 14.0", developmentRegion="zh-Hans",
              hasScannedForEncodings=0, knownRegions=["zh-Hans", "en", "Base"], mainGroup=main, productRefGroup=products, projectDirPath="", projectRoot="", targets=[app, test, ui_test])
path = ROOT / "LiaoChat.xcodeproj"
path.mkdir(exist_ok=True)
(path / "project.pbxproj").write_text("// !$*UTF8*$!\n" + encode(dict(archiveVersion=1, classes={}, objectVersion=56, objects=objects, rootObject=project)) + "\n")
scheme_dir = path / "xcshareddata/xcschemes"
scheme_dir.mkdir(parents=True, exist_ok=True)
scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
    <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
      <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app}" BuildableName="LiaoChat.app" BlueprintName="LiaoChat" ReferencedContainer="container:LiaoChat.xcodeproj"/>
    </BuildActionEntry>
  </BuildActionEntries></BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables>
    <TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{test}" BuildableName="LiaoChatTests.xctest" BlueprintName="LiaoChatTests" ReferencedContainer="container:LiaoChat.xcodeproj"/></TestableReference>
    <TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ui_test}" BuildableName="LiaoChatUITests.xctest" BlueprintName="LiaoChatUITests" ReferencedContainer="container:LiaoChat.xcodeproj"/></TestableReference>
  </Testables></TestAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">
    <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app}" BuildableName="LiaoChat.app" BlueprintName="LiaoChat" ReferencedContainer="container:LiaoChat.xcodeproj"/>
  </BuildableProductRunnable></LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugServiceExtension="internal"/>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
'''
(scheme_dir / "LiaoChat.xcscheme").write_text(scheme)
print("Generated LiaoChat.xcodeproj")
