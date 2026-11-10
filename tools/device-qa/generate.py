#!/usr/bin/env python3
"""Generate an isolated, unsigned QA app project under ignored build/. No business app or credentials."""
from pathlib import Path
import plistlib
import shutil

root = Path(__file__).resolve().parents[2]
out = root / 'build/device-qa'
project = out / 'MonitorQa.xcodeproj'
project.mkdir(parents=True, exist_ok=True)
shutil.copy2(Path(__file__).with_name('QaApp.swift'), out / 'QaApp.swift')
(out / 'Info.plist').write_bytes(plistlib.dumps({
    'CFBundleExecutable': 'MonitorQa', 'CFBundleIdentifier': 'com.mooeen.monitor.ios.deviceqa',
    'CFBundleName': 'MonitorQa', 'CFBundleDisplayName': 'Monitor QA', 'CFBundlePackageType': 'APPL',
    'CFBundleVersion': '1', 'CFBundleShortVersionString': '0.2.0',
    'UILaunchScreen': {}, 'LSRequiresIPhoneOS': True,
    'UIApplicationSceneManifest': {'UIApplicationSupportsMultipleScenes': False},
    'UISupportedInterfaceOrientations': ['UIInterfaceOrientationPortrait', 'UIInterfaceOrientationLandscapeLeft', 'UIInterfaceOrientationLandscapeRight', 'UIInterfaceOrientationPortraitUpsideDown'], 'NSLocalNetworkUsageDescription': 'Local monitor fixture only',
    'NSAppTransportSecurity': {'NSAllowsArbitraryLoads': True},
}))
(project / 'project.pbxproj').write_text('''// !$*UTF8*$!
{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {
A00000000000000000000001 = {isa = PBXProject; attributes = {LastUpgradeCheck = 1500;}; buildConfigurationList = A00000000000000000000002; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; mainGroup = A00000000000000000000003; packageReferences = (A00000000000000000000010,); projectDirPath = ""; targets = (A00000000000000000000004,);};
A00000000000000000000002 = {isa = XCConfigurationList; buildConfigurations = (A00000000000000000000005,); defaultConfigurationName = Debug;};
A00000000000000000000003 = {isa = PBXGroup; children = (A00000000000000000000006, A00000000000000000000007,); sourceTree = "<group>";};
A00000000000000000000004 = {isa = PBXNativeTarget; buildConfigurationList = A00000000000000000000008; buildPhases = (A00000000000000000000009, A0000000000000000000000A,); buildRules = (); dependencies = (); name = MonitorQa; packageProductDependencies = (A00000000000000000000011,); productName = MonitorQa; productReference = A00000000000000000000007; productType = "com.apple.product-type.application";};
A00000000000000000000005 = {isa = XCBuildConfiguration; buildSettings = {ALWAYS_SEARCH_USER_PATHS = NO; SWIFT_VERSION = 5.0; IPHONEOS_DEPLOYMENT_TARGET = 17.0; SDKROOT = iphoneos;}; name = Debug;};
A00000000000000000000006 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = QaApp.swift; sourceTree = "<group>";};
A00000000000000000000007 = {isa = PBXFileReference; explicitFileType = wrapper.application; path = MonitorQa.app; sourceTree = BUILT_PRODUCTS_DIR;};
A00000000000000000000008 = {isa = XCConfigurationList; buildConfigurations = (A0000000000000000000000B,); defaultConfigurationName = Debug;};
A00000000000000000000009 = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (A0000000000000000000000C,); runOnlyForDeploymentPostprocessing = 0;};
A0000000000000000000000A = {isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (A00000000000000000000012,); runOnlyForDeploymentPostprocessing = 0;};
A0000000000000000000000B = {isa = XCBuildConfiguration; buildSettings = {PRODUCT_BUNDLE_IDENTIFIER = com.mooeen.monitor.ios.deviceqa; INFOPLIST_FILE = Info.plist; PRODUCT_NAME = MonitorQa; TARGETED_DEVICE_FAMILY = "1,2"; SWIFT_VERSION = 5.0;}; name = Debug;};
A0000000000000000000000C = {isa = PBXBuildFile; fileRef = A00000000000000000000006;};
A00000000000000000000010 = {isa = XCLocalSwiftPackageReference; relativePath = "../..";};
A00000000000000000000011 = {isa = XCSwiftPackageProductDependency; package = A00000000000000000000010; productName = MooMonitor;};
A00000000000000000000012 = {isa = PBXBuildFile; productRef = A00000000000000000000011;};
}; rootObject = A00000000000000000000001; }
''')
print(project)
